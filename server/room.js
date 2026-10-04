// 방 하나의 상태기계. 타이머와 채점은 모두 여기(서버)에서 결정한다.
// 대기(lobby) → 문제(question) → 채점·해설·순위(reveal) → … → 최종 결과(final)
import { randomUUID } from "node:crypto";
import { QUIZ, levelInfo } from "./questions.js";
import { buildRound, newUsed } from "./round.js";
import { gradeOne, answerLabel, rank, rankOf } from "./scoring.js";
import * as participation from "./participation.js";
import { ROUND, TIME, NUMS, MAX_PLAYERS, SPEED, COLORS } from "../public/shared/consts.js";
import { START, zonesFor, zoneAt, clampYard } from "../public/shared/map.js";

const POS_HZ = 10;          // 방 안 모든 위치를 한꺼번에 뿌리는 주기
const ZONE_HZ = 2;          // 구역별 인원 수(진행자 화면용)
const REVEAL_GRACE = 250;   // 마감 직전 패킷이 도착할 시간을 조금 준다
const COLOR_IDS = COLORS.map(c => c.id);

export class Room {
  constructor(code, io, onEmpty){
    this.code = code;
    this.io = io;
    this.onEmpty = onEmpty;
    this.hostToken = randomUUID();
    this.hostSockets = new Set();
    this.level = "elem";
    this.phase = "lobby";
    this.players = new Map();     // playerId -> player
    this.byToken = new Map();     // playerToken -> playerId
    this.used = newUsed();
    this.round = [];
    this.qIndex = -1;
    this.startAt = 0;
    this.endAt = 0;
    this.deadline = null;
    this.lastSeen = Date.now();
    this.closed = false;
    this.posTimer = setInterval(() => this.sendPositions(), 1000 / POS_HZ);
    this.zoneTimer = setInterval(() => this.sendZoneCounts(), 1000 / ZONE_HZ);
  }

  get room(){ return `room:${this.code}`; }
  touch(){ this.lastSeen = Date.now(); }

  /* ---------------- 사람 ---------------- */

  // 같은 방에 같은 이름이 있으면 뒤에 숫자를 붙인다.
  uniqueName(base, exceptId){
    const taken = new Set([...this.players.values()].filter(p => p.id !== exceptId).map(p => p.name));
    if (!taken.has(base)) return base;
    for (let n = 2; n < 100; n++){ const t = `${base}${n}`; if (!taken.has(t)) return t; }
    return `${base}${Date.now() % 1000}`;
  }

  cleanName(raw){
    const s = String(raw ?? "").replace(/\s+/g, " ").trim().slice(0, 8);
    return s || "친구";
  }

  join({ name, color, playerToken, socketId }){
    this.touch();
    // 재접속: 같은 기기(토큰)라면 이름과 점수를 그대로 이어 간다.
    const known = playerToken && this.byToken.get(playerToken);
    if (known && this.players.has(known)){
      const p = this.players.get(known);
      p.connected = true;
      p.socketId = socketId;
      if (color && COLOR_IDS.includes(color)) p.color = color;
      return { player: p, rejoined: true };
    }
    const active = [...this.players.values()].length;
    if (active >= MAX_PLAYERS) return { error: "full" };

    const id = randomUUID().slice(0, 8);
    const p = {
      id,
      token: playerToken || randomUUID(),
      name: this.uniqueName(this.cleanName(name)),
      color: COLOR_IDS.includes(color) ? color : "red",
      score: 0, bonus: 0,
      answers: [],
      pos: { ...START, moving: false },
      lastPosAt: Date.now(),
      lockedPos: null, lockedAt: 0, hintUsed: false,
      // 문제가 나가는 중에 들어온 학생은 다음 문제부터 채점한다.
      pending: this.phase === "question",
      connected: true,
      socketId
    };
    this.players.set(id, p);
    this.byToken.set(p.token, id);
    return { player: p, rejoined: false };
  }

  kick(playerId){
    const p = this.players.get(playerId);
    if (!p) return false;
    this.players.delete(playerId);
    this.byToken.delete(p.token);
    if (p.socketId) this.io.to(p.socketId).emit("play:kicked");
    this.sendState();
    return true;
  }

  disconnect(socketId){
    for (const p of this.players.values()){
      if (p.socketId === socketId){ p.connected = false; p.pos.moving = false; }
    }
    this.hostSockets.delete(socketId);
    this.sendState();
  }

  /* ---------------- 이동 ---------------- */

  move(player, x, y){
    if (this.closed || !Number.isFinite(x) || !Number.isFinite(y)) return;
    const now = Date.now();
    const want = clampYard({ x, y });                       // 마당 밖으로는 못 나간다
    const dt = Math.min(1.5, Math.max(0.016, (now - player.lastPosAt) / 1000));
    const limit = SPEED * 1.6 * dt + 12;                    // 걷는 속도보다 빠른 이동은 인정하지 않는다
    const dx = want.x - player.pos.x, dy = want.y - player.pos.y;
    const d = Math.hypot(dx, dy);
    let next = want;
    if (d > limit) next = { x: player.pos.x + dx / d * limit, y: player.pos.y + dy / d * limit };
    player.pos = { x: next.x, y: next.y, moving: d > 1 };
    player.lastPosAt = now;
    this.touch();
  }

  /* ---------------- 진행 ---------------- */

  setLevel(level){
    if (this.phase !== "lobby" && this.phase !== "final") return;
    if (!QUIZ[level]) return;
    this.level = level;
    this.sendState();
  }

  startGame(){
    if (this.phase === "question") return;
    this.round = buildRound(QUIZ, this.level, this.used);
    this.qIndex = -1;
    for (const p of this.players.values()){
      p.score = 0; p.bonus = 0; p.answers = []; p.pending = false;
    }
    this.nextQuestion();
  }

  nextQuestion(){
    if (this.closed) return;
    clearTimeout(this.deadline);
    if (this.qIndex + 1 >= this.round.length) return this.finish();
    this.qIndex++;
    const q = this.round[this.qIndex];
    this.phase = "question";
    this.startAt = Date.now();
    this.endAt = this.startAt + TIME[q.t] * 1000;
    for (const p of this.players.values()){
      p.lockedPos = null; p.lockedAt = 0; p.hintUsed = false;
      p.pending = false;                  // 지난 문제 중간에 들어온 학생도 이제 참여
      p.pos = { ...START, moving: false }; // 새 문제는 다시 출발선에서
      p.lastPosAt = Date.now();
    }
    this.io.to(this.room).emit("room:question", this.questionPayload());
    this.sendState();
    this.deadline = setTimeout(() => this.grade(), TIME[q.t] * 1000 + REVEAL_GRACE);
  }

  // 정답·해설·힌트는 보내지 않는다.
  questionPayload(){
    const q = this.round[this.qIndex];
    return {
      qIndex: this.qIndex, total: this.round.length,
      type: q.t, q: q.q,
      choices: q.t === "mc" ? q.c : null,
      zones: zonesFor(q),
      startAt: this.startAt, endAt: this.endAt,
      now: Date.now(),                 // 클라이언트가 자기 시계와의 차이를 보정하는 데 쓴다
      seconds: TIME[q.t]
    };
  }

  lock(player){
    if (this.phase !== "question" || player.lockedPos || player.pending) return { ok: false, reason: "phase" };
    const z = zoneAt(player.pos, zonesFor(this.round[this.qIndex]));
    if (!z) return { ok: false, reason: "zone" };
    player.lockedPos = { ...player.pos };
    player.lockedAt = Date.now();
    return { ok: true, zone: String(z.key) };
  }

  hintFor(player){
    if (this.phase !== "question") return null;
    player.hintUsed = true;
    return this.round[this.qIndex].hint;
  }

  grade(){
    if (this.phase !== "question") return;
    clearTimeout(this.deadline);
    const q = this.round[this.qIndex];
    const zones = zonesFor(q);
    this.phase = "reveal";

    for (const p of this.players.values()){
      if (p.pending){ p.answers.push(null); continue; }   // 중간 입장: 이 문제는 채점하지 않음
      const pos = p.lockedPos || p.pos;
      const decidedAt = p.lockedAt || this.endAt;
      const { picked, correct, bonus } = gradeOne({ q, zones, pos, decidedAt, startAt: this.startAt, endAt: this.endAt });
      if (correct){ p.score++; p.bonus += bonus; }
      p.answers.push({ picked, correct });
      if (p.socketId) this.io.to(p.socketId).emit("play:result", {
        qIndex: this.qIndex,
        correct, picked,
        answer: q.a,
        answerLabel: answerLabel(q, NUMS),
        explain: q.ex,
        score: p.score,
        timeout: p.lockedPos === null && picked === null
      });
    }

    this.io.to(this.room).emit("room:reveal", {
      qIndex: this.qIndex, total: this.round.length,
      answer: q.a, answerLabel: answerLabel(q, NUMS), explain: q.ex,
      leaderboard: rank([...this.players.values()]).slice(0, 5),
      last: this.qIndex === this.round.length - 1
    });
    this.sendState();
  }

  finish(){
    clearTimeout(this.deadline);
    const played = this.qIndex + 1;
    this.phase = "final";
    const list = [...this.players.values()];
    const ranking = rank(list);

    if (list.length && played > 0){
      const avg = list.reduce((s,p) => s + p.score, 0) / list.length;
      participation.append({
        level: this.level, levelName: levelInfo(this.level).name,
        players: list.length, avgScore: avg, questions: played
      });
    }

    this.io.to(this.room).emit("room:final", {
      ranking, questions: played, todayTotal: participation.todayTotal(),
      ranks: ranking.map(r => ({ id: r.id, score: r.score, title: r.title, say: rankOf(r.score).say }))
    });
    this.sendState();
  }

  endGame(){
    if (this.phase === "lobby" || this.phase === "final") return;
    this.finish();
  }

  /* ---------------- 내보내기 ---------------- */

  playerList(){
    return [...this.players.values()].map(p => ({
      id: p.id, name: p.name, color: p.color, score: p.score,
      connected: p.connected, pending: p.pending,
      locked: !!p.lockedPos
    }));
  }

  state(){
    return {
      code: this.code, phase: this.phase, level: this.level,
      levelInfo: levelInfo(this.level),
      players: this.playerList(), count: this.players.size,
      qIndex: this.qIndex, total: this.round.length || ROUND,
      maxPlayers: MAX_PLAYERS,
      todayTotal: participation.todayTotal()
    };
  }

  // 새로고침한 화면이 지금 상황을 그대로 이어받도록, 현재 단계에 필요한 내용을 한 번에 담아 보낸다.
  snapshot(){
    const s = this.state();
    if (this.phase === "question") s.question = this.questionPayload();
    if (this.phase === "reveal" || this.phase === "final"){
      const q = this.round[this.qIndex];
      if (q) s.reveal = {
        qIndex: this.qIndex, total: this.round.length,
        answer: q.a, answerLabel: answerLabel(q, NUMS), explain: q.ex,
        leaderboard: rank([...this.players.values()]).slice(0, 5),
        last: this.qIndex === this.round.length - 1,
        question: { type: q.t, q: q.q, choices: q.t === "mc" ? q.c : null, zones: zonesFor(q) }
      };
    }
    if (this.phase === "final"){
      const ranking = rank([...this.players.values()]);
      s.final = { ranking, questions: this.qIndex + 1, todayTotal: participation.todayTotal(),
        ranks: ranking.map(r => ({ id: r.id, score: r.score, title: r.title, say: rankOf(r.score).say })) };
    }
    return s;
  }

  sendState(){ if (!this.closed) this.io.to(this.room).emit("room:state", this.state()); }

  sendPositions(){
    if (this.closed || !this.players.size) return;
    const p = [];
    for (const pl of this.players.values()){
      if (!pl.connected) continue;
      p.push([pl.id, Math.round(pl.pos.x), Math.round(pl.pos.y), pl.pos.moving ? 1 : 0]);
    }
    if (p.length) this.io.to(this.room).emit("room:positions", { t: Date.now(), p });
  }

  sendZoneCounts(){
    if (this.closed || this.phase !== "question") return;
    const zones = zonesFor(this.round[this.qIndex]);
    const counts = {};
    for (const z of zones) counts[String(z.key)] = 0;
    let none = 0;
    for (const pl of this.players.values()){
      if (pl.pending) continue;
      const z = zoneAt(pl.lockedPos || pl.pos, zones);
      if (z) counts[String(z.key)]++; else none++;
    }
    this.io.to(this.room).emit("room:zoneCounts", { counts, none });
  }

  close(reason = "진행자가 방을 닫았어요."){
    if (this.closed) return;
    this.closed = true;
    clearTimeout(this.deadline);
    clearInterval(this.posTimer);
    clearInterval(this.zoneTimer);
    this.io.to(this.room).emit("room:closed", { reason });
    this.onEmpty?.(this.code);
  }

  // 진행자도 학생도 아무도 붙어 있지 않은 상태가 오래 이어지면 방을 정리한다.
  idleMs(){
    const live = this.hostSockets.size + [...this.players.values()].filter(p => p.connected).length;
    return live > 0 ? 0 : Date.now() - this.lastSeen;
  }
}
