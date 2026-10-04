// 방 운영: 정원, 이름 중복, 재접속, 중간 입장, 위치 검증, 방 정리.
import test from "node:test";
import assert from "node:assert/strict";
import { Room } from "../server/room.js";
import { Rooms } from "../server/rooms.js";
import { MAX_PLAYERS, SPEED } from "../public/shared/consts.js";
import { YARD, START, zonesFor } from "../public/shared/map.js";

// socket.io 대신 쓰는 가짜. 어떤 이벤트가 나갔는지만 모아 둔다.
function fakeIo(){
  const sent = [];
  const io = { to: () => ({ emit: (ev, data) => sent.push({ ev, data }) }) };
  io.sent = sent;
  io.last = ev => [...sent].reverse().find(s => s.ev === ev)?.data;
  return io;
}
const newRoom = () => new Room("1234", fakeIo(), () => {});
const join = (room, name, token) => room.join({ name, color: "red", playerToken: token, socketId: "s-" + name });

test("같은 방에 같은 이름이 있으면 뒤에 숫자를 붙인다", () => {
  const room = newRoom();
  assert.equal(join(room, "민수").player.name, "민수");
  assert.equal(join(room, "민수").player.name, "민수2");
  assert.equal(join(room, "민수").player.name, "민수3");
  room.close();
});

test("이름은 8자까지, 비어 있으면 기본 이름", () => {
  const room = newRoom();
  assert.equal(join(room, "가나다라마바사아자차").player.name, "가나다라마바사아");
  assert.equal(join(room, "   ").player.name, "친구");
  room.close();
});

test(`한 방에 학생은 ${MAX_PLAYERS}명까지`, () => {
  const room = newRoom();
  for (let i = 0; i < MAX_PLAYERS; i++) assert.ok(join(room, `학생${i}`).player, `${i}번째는 들어온다`);
  assert.equal(join(room, "한명더").error, "full");
  assert.equal(room.players.size, MAX_PLAYERS);
  room.close();
});

test("재접속: 같은 기기(토큰)면 이름과 점수가 그대로 이어진다", () => {
  const room = newRoom();
  const { player } = join(room, "민수");
  player.score = 7; player.bonus = 2.5;
  room.disconnect(player.socketId);
  assert.equal(player.connected, false);

  const again = room.join({ name: "아무이름", color: "cheong", playerToken: player.token, socketId: "s2" });
  assert.equal(again.rejoined, true);
  assert.equal(again.player.id, player.id);
  assert.equal(again.player.name, "민수", "이름이 그대로");
  assert.equal(again.player.score, 7, "점수가 그대로");
  assert.equal(room.players.size, 1, "사람이 늘지 않는다");
  room.close();
});

test("토큰이 없으면 새 학생으로 들어온다", () => {
  const room = newRoom();
  join(room, "민수");
  const b = room.join({ name: "민수", color: "red", playerToken: "모르는토큰", socketId: "s9" });
  assert.equal(b.rejoined, false);
  assert.equal(b.player.name, "민수2");
  room.close();
});

test("게임 중에 들어온 학생은 다음 문제부터 참여한다", () => {
  const room = newRoom();
  const a = join(room, "먼저").player;
  room.startGame();
  assert.equal(room.phase, "question");
  assert.equal(a.pending, false);

  const b = join(room, "나중").player;
  assert.equal(b.pending, true, "이번 문제는 채점하지 않는다");

  room.grade();
  assert.equal(b.answers[0], null, "이번 문제는 기록도 남기지 않는다");
  assert.equal(b.score, 0);

  room.nextQuestion();
  assert.equal(b.pending, false, "다음 문제부터는 함께 푼다");
  room.close();
});

test("위치는 마당 밖으로 나가지 못한다", () => {
  const room = newRoom();
  const p = join(room, "민수").player;
  for (const [x, y] of [[-9999, -9999], [9999, 9999], [480, -50]]){
    p.lastPosAt = Date.now() - 5000;              // 충분한 시간이 지난 것으로 둔다
    room.move(p, x, y);
    assert.ok(p.pos.x >= YARD.x && p.pos.x <= YARD.x + YARD.w, `x 가 마당 안: ${p.pos.x}`);
    assert.ok(p.pos.y >= YARD.y && p.pos.y <= YARD.y + YARD.h, `y 가 마당 안: ${p.pos.y}`);
  }
  room.close();
});

test("걷는 속도보다 빠른 이동은 그 속도까지만 인정한다", () => {
  const room = newRoom();
  const p = join(room, "민수").player;
  p.pos = { ...START, moving: false };
  p.lastPosAt = Date.now();                        // 방금 움직였는데
  room.move(p, 100, 150);                          // 마당 반대편으로 순간이동 시도
  const moved = Math.hypot(p.pos.x - START.x, p.pos.y - START.y);
  assert.ok(moved < SPEED * 0.3, `한 번에 ${Math.round(moved)}px 밖에 못 간다`);

  // 느리게 여러 번 보내면 정상적으로 도착한다
  for (let i = 0; i < 30; i++){ p.lastPosAt = Date.now() - 120; room.move(p, 100, 150); }
  assert.ok(Math.hypot(p.pos.x - 100, p.pos.y - 150) < 5, "제대로 걸어가면 도착한다");
  room.close();
});

test("채점은 마감 순간의 위치로, 결정을 누르면 그 자리로 한다", () => {
  const room = newRoom();
  room.level = "elem";
  const a = join(room, "가").player, b = join(room, "나").player;
  room.startGame();
  const q = room.round[0], zones = zonesFor(q);
  const right = zones.find(z => z.key === q.a), wrong = zones.find(z => z.key !== q.a);

  // 가: 정답 자리에서 결정을 누르고, 그 뒤 오답 자리로 옮겨 간다 → 결정한 자리로 채점
  a.pos = { x: right.x + right.w/2, y: right.y + right.h/2, moving: false };
  assert.equal(room.lock(a).ok, true);
  a.pos = { x: wrong.x + wrong.w/2, y: wrong.y + wrong.h/2, moving: false };
  // 나: 아무것도 누르지 않고 마감 때 정답 자리에 서 있다
  b.pos = { x: right.x + right.w/2, y: right.y + right.h/2, moving: false };

  room.grade();
  assert.equal(a.score, 1, "결정한 자리로 채점한다");
  assert.equal(b.score, 1, "마감 순간 서 있는 자리로 채점한다");
  assert.ok(a.bonus > b.bonus, "일찍 결정한 쪽이 빠르기 보너스가 크다");
  room.close();
});

test("자리 밖에서는 결정을 누를 수 없다", () => {
  const room = newRoom();
  const p = join(room, "민수").player;
  room.startGame();
  p.pos = { ...START, moving: false };              // 출발 지점은 돗자리 밖
  assert.deepEqual(room.lock(p), { ok: false, reason: "zone" });
  room.close();
});

test("힌트는 물어본 학생에게만 돌려주고, 방에는 뿌리지 않는다", () => {
  const room = newRoom();
  const p = join(room, "민수").player;
  room.startGame();
  const hint = room.hintFor(p);
  assert.equal(hint, room.round[0].hint);
  const leaked = room.io.sent.some(s => JSON.stringify(s.data ?? "").includes(hint));
  assert.equal(leaked, false, "힌트가 방 전체로 나가지 않는다");
  room.close();
});

test("문제를 보낼 때 정답·해설·힌트는 함께 보내지 않는다", () => {
  const room = newRoom();
  join(room, "민수");
  room.startGame();
  const sent = JSON.stringify(room.io.last("room:question"));
  const q = room.round[0];
  assert.ok(!sent.includes(q.ex), "해설이 들어 있지 않다");
  assert.ok(!sent.includes(q.hint), "힌트가 들어 있지 않다");
  assert.ok(!/"a":/.test(sent), "정답이 들어 있지 않다");
  assert.ok(sent.includes(q.q), "문제 문장은 들어 있다");
  room.close();
});

test("한 판은 10문제이고, 끝나면 최종 결과로 간다", () => {
  const room = newRoom();
  join(room, "민수");
  room.startGame();
  for (let i = 0; i < 10; i++){ room.grade(); room.nextQuestion(); }
  assert.equal(room.phase, "final");
  assert.equal(room.io.last("room:final").questions, 10);
  room.close();
});

test("강제 종료하면 그때까지의 점수로 최종 결과가 나온다", () => {
  const room = newRoom();
  const p = join(room, "민수").player;
  room.startGame();
  p.score = 3;
  room.endGame();
  assert.equal(room.phase, "final");
  const f = room.io.last("room:final");
  assert.equal(f.ranking[0].score, 3);
  assert.equal(f.ranking[0].title, "양민");
  room.close();
});

test("내보낸 학생은 명단에서 사라진다", () => {
  const room = newRoom();
  const p = join(room, "장난이").player;
  join(room, "민수");
  assert.equal(room.kick(p.id), true);
  assert.equal(room.players.size, 1);
  assert.equal(room.kick(p.id), false, "없는 학생은 내보낼 수 없다");
  room.close();
});

test("방을 여러 개 동시에 열 수 있고, 코드는 서로 다르다", () => {
  const rooms = new Rooms(fakeIo());
  const codes = new Set();
  for (let i = 0; i < 50; i++){
    const r = rooms.create();
    assert.match(r.code, /^\d{4}$/);
    codes.add(r.code);
  }
  assert.equal(codes.size, 50, "코드가 겹치지 않는다");
  assert.equal(rooms.size, 50);
  for (const code of codes) assert.ok(rooms.get(code), "코드로 방을 찾을 수 있다");
  clearInterval(rooms.sweeper);
  for (const r of rooms.map.values()) r.close();
});

test("아무도 없는 방은 정리 대상이 된다", () => {
  const rooms = new Rooms(fakeIo());
  const room = rooms.create();
  assert.equal(room.idleMs(), 0, "방금 만든 방은 정리하지 않는다");

  const p = room.join({ name: "민수", color: "red", socketId: "s1" }).player;
  assert.equal(room.idleMs(), 0, "학생이 붙어 있으면 정리하지 않는다");

  room.disconnect(p.socketId);
  room.lastSeen = Date.now() - 20 * 60 * 1000;      // 20분 전
  assert.ok(room.idleMs() > 15 * 60 * 1000, "아무도 없이 오래되면 정리 대상");

  rooms.sweep();
  assert.equal(rooms.get(room.code), undefined, "정리됐다");
  clearInterval(rooms.sweeper);
});
