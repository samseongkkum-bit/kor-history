// 진행자 화면. 방을 만들고 단계를 고르고 문제를 넘긴다. 마당은 관전용으로 크게 보여 준다.
// 채점과 시간은 Supabase(Postgres 함수)가 정하고, 이 화면은 마감 시각에 채점 함수를 불러 줄 뿐이다.
import { esc } from "/shared/consts.js";
import { drawPerson, cv, jacket } from "/shared/draw.js";
import { createYard } from "/shared/yard.js";
import { zonesFor, zoneAt } from "/shared/map.js";
import { api, watchRoom, positionRelay, configMissing, NetError } from "/shared/net.js";

const $ = id => document.getElementById(id);
const LS = {
  get: k => { try { return localStorage.getItem("hqh." + k); } catch { return null; } },
  set: (k,v) => { try { localStorage.setItem("hqh." + k, v); } catch {} },
  del: k => { try { localStorage.removeItem("hqh." + k); } catch {} }
};

let room = { code: LS.get("code"), hostToken: LS.get("token") };
let yard = null, watch = null, relay = null, timerRaf = 0;
let shownQ = -2, shownPhase = "", lastPlayers = "", lastPrev = "", curZones = [];
let nextSnap = null;          // 강제 종료로 만들어 둔 새 방(최종 순위를 보여 주는 동안 기다린다)

const show = which => ["s-start","s-game","s-final","s-msg"].forEach(id => $(id).hidden = id !== which);
const message = (t, b) => { $("msgTitle").textContent = t; $("msgBody").textContent = b; show("s-msg"); };

/* ---------------- 단계 고르기 ---------------- */
let levels = [];
async function loadLevels(){
  try { levels = await api.levels(); } catch { levels = []; }
  $("levels").innerHTML = levels.map(l =>
    `<button class="lvbtn" type="button" data-level="${esc(l.key)}" aria-pressed="false"><b>${esc(l.name)}</b><span>${esc(l.kind)} · ${l.total}문제</span></button>`
  ).join("") + `<button class="lvbtn" type="button" disabled><b>고등부</b><span>준비 중</span></button>`;
  $("levels").querySelectorAll("[data-level]").forEach(b => b.onclick = async () => {
    try { render(await api.hostLevel(room.code, room.hostToken, b.dataset.level)); } catch (e) { console.warn(e.message); }
  });
}

/* ---------------- 방 ---------------- */
$("createBtn").onclick = async () => {
  $("createBtn").disabled = true;
  try {
    const res = await api.hostCreate();
    room = { code: res.code, hostToken: res.hostToken };
    LS.set("code", room.code); LS.set("token", room.hostToken);
    enterRoom(res.snapshot);
  } catch (e) {
    message("방을 만들지 못했어요", e instanceof NetError ? e.message : "잠시 뒤 다시 해 주세요.");
  } finally {
    $("createBtn").disabled = false;
  }
};

function joinUrl(){ return `${location.origin}/play?code=${room.code}`; }

function enterRoom(snap){
  $("code").textContent = room.code;
  $("joinurl").textContent = joinUrl();
  drawQr(joinUrl());
  ensureYard();
  startWatching();
  if (snap) render(snap);
}

// QR 은 npm 으로 받은 라이브러리로 이 화면에서 직접 그린다(외부 CDN 을 쓰지 않는다).
function drawQr(text){
  try {
    const qr = window.qrcode(0, "M");
    qr.addData(text);
    qr.make();
    $("qr").innerHTML = qr.createSvgTag({ cellSize: 6, margin: 0, scalable: true });
  } catch {
    $("qr").textContent = "QR을 만들지 못했어요";
  }
}

function startWatching(){
  watch?.stop(); relay?.stop();
  watch = watchRoom({
    code: room.code, isHost: true,
    onSnapshot: s => {
      if (!s){ LS.del("code"); LS.del("token"); return message("방이 닫혔어요", "시간이 지나 방이 정리됐어요."); }
      render(s);
    },
    onError: e => console.warn(e.message)
  });
  relay = positionRelay(watch.channel, { isHost: true, onAll: p => { yard?.applyPositions(p); countZones(p); } });
}

// 구역별 인원은 화면에 그리는 바로 그 위치로 센다(따로 세면 숫자와 그림이 어긋난다).
function countZones(payload){
  if (shownPhase !== "question" || !curZones.length) return;
  const counts = {}; let none = 0;
  for (const z of curZones) counts[String(z.key)] = 0;
  for (const [, x, y] of payload?.p || []){
    const z = zoneAt({ x, y }, curZones);
    if (z) counts[String(z.key)]++; else none++;
  }
  yard?.setCounts(counts);
  const parts = curZones.map(z => `${z.label} ${counts[String(z.key)] || 0}명`);
  if (none) parts.push(`자리 밖 ${none}명`);
  $("zoneline").textContent = parts.join("  ·  ");
}

function ensureYard(){
  if (yard) return;
  yard = createYard($("yard"), { spectator: true });
  yard.start();
}

/* ---------------- 조작 ---------------- */
const guard = fn => async () => { try { render(await fn()); } catch (e) { console.warn(e.message); } };
$("startBtn").onclick = guard(() => api.hostStart(room.code, room.hostToken));
$("nextBtn").onclick  = guard(() => api.hostNext(room.code, room.hostToken));
$("againBtn").onclick = guard(() => api.hostStart(room.code, room.hostToken));
$("endBtn").onclick = async () => {
  if (!confirm("게임을 지금 끝내고 최종 순위를 보여 줄까요?\n새 방도 바로 만들어 둘게요.")) return;
  await makeNewRoom();
};

/* ---------------- 새 방 ---------------- */
// 강제 종료하면 옛 방은 최종 순위로 끝내고 새 방을 연다. 진행자 화면은 옛 방의 최종 순위를 보여 주다가
// 버튼을 누르면 새 방 대기실로 간다. 이 화면을 새로고침해도 새 방으로 이어진다.
async function makeNewRoom(){
  let res;
  try { res = await api.hostNewRoom(room.code, room.hostToken); }
  catch (e) { return message("새 방을 만들지 못했어요", e instanceof NetError ? e.message : "잠시 뒤 다시 해 주세요."); }
  watch?.stop(); relay?.stop(); watch = null; relay = null;
  room = { code: res.code, hostToken: res.hostToken };
  LS.set("code", room.code); LS.set("token", room.hostToken);
  nextSnap = res.snapshot;
  render(res.finished);
}

async function enterNextRoom(inviteAll){
  let snap = nextSnap;
  nextSnap = null;
  if (inviteAll){
    try { snap = await api.hostInvite(room.code, room.hostToken); } catch (e) { console.warn(e.message); }
  }
  shownQ = -2; shownPhase = ""; lastPlayers = ""; lastPrev = "";
  $("codecard").dataset.open = "";
  enterRoom(snap);
}

$("newRoomBtn").onclick  = () => nextSnap ? enterNextRoom(false) : makeNewRoom();
$("inviteGoBtn").onclick = () => enterNextRoom(true);
$("inviteAllBtn").onclick = guard(() => api.hostInvite(room.code, room.hostToken));

$("lobbyBtn").onclick = () => { show("s-game"); $("qcard").hidden = true; $("revealcard").hidden = true; yard?.clearZones(); };
$("codecard").onclick = () => {
  const c = $("codecard");
  c.dataset.open = c.classList.contains("compact") ? "1" : "";
  c.classList.toggle("compact");
};

/* ---------------- 그리기 ---------------- */
function render(s){
  if (!s) return;
  show(s.phase === "final" ? "s-final" : "s-game");
  $("code").textContent = s.code;
  $("today").textContent = `오늘 참여 인원 합계 ${s.todayTotal ?? 0}명`;
  $("phase").textContent = {
    lobby: "대기실 · 학생을 기다려요", question: `문제 ${s.qIndex + 1} / ${s.total}`,
    reveal: "정답 공개", final: "최종 결과"
  }[s.phase] || s.phase;

  $("levels").querySelectorAll("[data-level]").forEach(b => {
    b.setAttribute("aria-pressed", String(b.dataset.level === s.level));
    b.disabled = s.phase === "question" || s.phase === "reveal";
  });
  $("startBtn").hidden = s.phase === "question" || s.phase === "reveal";
  $("startBtn").textContent = s.phase === "final" ? "새 문제로 한 판 더" : "게임 시작";
  $("startBtn").disabled = (s.count ?? 0) === 0;
  $("nextBtn").hidden = s.phase !== "reveal";
  $("endBtn").disabled = s.phase === "lobby";
  $("plabel").textContent = s.phase === "lobby" ? "들어온 학생" : "학생";
  $("pcount").textContent = s.count ?? 0;
  $("pmax").textContent = `(최대 ${s.maxPlayers ?? 30}명)`;
  $("lobbycard").hidden = s.phase !== "lobby";
  $("levelcard").hidden = s.phase === "question" || s.phase === "reveal";
  $("lobbyCount").textContent = `${s.count ?? 0}명`;
  $("codecard").classList.toggle("compact", s.phase !== "lobby" && !$("codecard").dataset.open);

  yard?.setMeta(s.players || []);
  renderPlayers(s.players || [], s.phase);
  renderPrev(s);

  if (s.phase === "lobby"){
    shownQ = -2; shownPhase = "lobby";
    $("qcard").hidden = true; $("revealcard").hidden = true; $("boardcard").hidden = true;
    $("zoneline").textContent = "";
    yard?.clearZones();
    stopTimer();
    return;
  }
  if (s.phase === "question") return renderQuestion(s);
  if (s.phase === "reveal")   return renderReveal(s);
  if (s.phase === "final")    return renderFinal(s);
}

function fillQuestion(s){
  const q = s.question;
  $("qnum").textContent = `${s.qIndex + 1} / ${s.total}`;
  $("qkind").textContent = q.type === "ox" ? "O/X" : "객관식";
  $("qtext").textContent = q.q;
  $("qcard").hidden = false;
  curZones = zonesFor({ t: q.type, c: q.choices });
  yard.setQuestion({ zones: curZones, type: q.type });
}

function renderQuestion(s){
  if (!s.question) return;
  if (s.qIndex !== shownQ || shownPhase !== "question"){
    shownQ = s.qIndex; shownPhase = "question";
    fillQuestion(s);
    $("revealcard").hidden = true;
    startTimer(s);
  }
}

function renderReveal(s){
  if (!s.question) return;
  if (s.qIndex !== shownQ) { shownQ = s.qIndex; fillQuestion(s); }
  if (shownPhase !== "reveal"){
    shownPhase = "reveal";
    stopTimer();
    $("tsec").textContent = "끝!";
    $("tfill").style.width = "0%";
    yard.setReveal({ answer: s.question.answer });
    yard.setCounts(null);
    $("zoneline").textContent = "";
  }
  $("ranswer").textContent = s.question.answerLabel || "";
  $("rexplain").textContent = s.question.explain || "";
  $("rsym").textContent = "○";
  $("revealcard").hidden = false;
  $("boardcard").hidden = false;
  $("top5").innerHTML = (s.leaderboard || []).map(p =>
    `<li><span class="no">${p.place}</span><span class="nm">${esc(p.name)}</span><span class="sc">${p.score}점</span></li>`
  ).join("") || `<li class="muted">아직 점수가 없어요</li>`;
  $("nextBtn").textContent = s.last ? "최종 결과 보기" : "다음 문제";
}

function renderFinal(s){
  stopTimer();
  shownPhase = "final"; shownQ = -2;
  // 새 방을 만들어 두었으면 그쪽으로 가는 버튼만 보여 준다
  $("nextNote").hidden = !nextSnap;
  if (nextSnap) $("nextNote").innerHTML = `새 방 <b>${esc(nextSnap.code)}</b> 을 만들어 두었어요. 학생들을 다시 불러 한 판 더 해요!`;
  $("inviteGoBtn").hidden = !nextSnap || !(s.count > 0);
  $("againBtn").hidden = !!nextSnap;
  $("lobbyBtn").hidden = !!nextSnap;
  $("newRoomBtn").textContent = nextSnap ? "새 방 대기실로" : "새 방 만들기";
  const list = s.ranking || [];
  $("finalHead").textContent = `${list.length}명 참여 · ${s.questions ?? 0}문제 · 오늘 참여 인원 합계 ${s.todayTotal ?? 0}명`;
  $("finalList").innerHTML = list.map(p =>
    `<li><span class="no">${p.place}</span><span class="nm">${esc(p.name)}</span><span class="ti">${esc(p.title)}</span><span class="sc">${p.score}점</span></li>`
  ).join("") || `<li class="muted">참여한 학생이 없어요</li>`;
}

function renderPlayers(players, phase){
  const key = JSON.stringify(players) + phase;
  if (key === lastPlayers) return;
  lastPlayers = key;
  const ul = $("players");
  ul.innerHTML = players.length ? "" : `<li class="muted" style="justify-content:center">아직 아무도 없어요</li>`;
  for (const p of players){
    const li = document.createElement("li");
    const cvs = document.createElement("canvas");
    cvs.width = 64; cvs.height = 80;
    const ctx = cvs.getContext("2d");
    ctx.setTransform(1.1,0,0,1.1,0,0);
    drawPerson(ctx, 29, 58, { upper: jacket(p.color), lower: cv("--meok-muted"), ribbon: cv("--red") });
    li.appendChild(cvs);
    const nm = document.createElement("span"); nm.className = "nm"; nm.textContent = p.name; li.appendChild(nm);
    const tag = (cls, t) => { const s = document.createElement("span"); s.className = cls; s.textContent = t; li.appendChild(s); };
    if (p.pending) tag("off", "다음 문제부터");
    if (!p.connected) tag("off", "연결 끊김");
    if (p.locked && phase === "question") tag("lock", "결정!");
    if (phase !== "lobby") tag("sc", `${p.score}점`);
    const k = document.createElement("button");
    k.className = "kick"; k.type = "button"; k.textContent = "내보내기";
    k.onclick = async () => {
      if (!confirm(`${p.name} 학생을 내보낼까요?`)) return;
      try { render(await api.hostKick(room.code, room.hostToken, p.id)); } catch (e) { console.warn(e.message); }
    };
    li.appendChild(k);
    ul.appendChild(li);
  }
}

// 이전 방 학생 명단. 대기실에서 한 명씩 또는 모두 다시 부를 수 있다.
function renderPrev(s){
  const list = s.prev || [];
  const visible = s.phase === "lobby" && !!s.prevCode && list.length > 0;
  $("prevcard").hidden = !visible;
  if (!visible) return;
  const key = JSON.stringify(list);
  if (key === lastPrev) return;
  lastPrev = key;
  $("prevCode").textContent = s.prevCode;
  $("prevCount").textContent = list.length;
  const waiting = list.filter(p => !p.moved);
  $("inviteAllBtn").disabled = !waiting.some(p => !p.invited);
  $("inviteAllBtn").textContent = waiting.length && waiting.every(p => p.invited) ? "모두 불렀어요" : "모두 다시 부르기";
  const ul = $("prevPlayers");
  ul.innerHTML = "";
  for (const p of list){
    const li = document.createElement("li");
    const nm = document.createElement("span"); nm.className = "nm"; nm.textContent = p.name; li.appendChild(nm);
    if (p.moved){
      const t = document.createElement("span"); t.className = "inv"; t.textContent = "들어왔어요"; li.appendChild(t);
    } else {
      const b = document.createElement("button");
      b.className = "kick call"; b.type = "button";
      b.textContent = p.invited ? "다시 부르기" : "부르기";
      b.onclick = guard(() => api.hostInvite(room.code, room.hostToken, p.id));
      if (p.invited){ const t = document.createElement("span"); t.className = "off"; t.textContent = "부르는 중"; li.appendChild(t); }
      li.appendChild(b);
    }
    ul.appendChild(li);
  }
}

/* ---------------- 남은 시간과 구역별 인원 ---------------- */
function startTimer(s){
  stopTimer();
  const start = new Date(s.startAt).getTime(), end = new Date(s.endsAt).getTime();
  const span = Math.max(1, end - start);
  const tick = () => {
    const left = Math.max(0, end - watch.serverNow());
    $("tfill").style.width = Math.max(0, left / span * 100) + "%";
    $("tfill").classList.toggle("low", left <= 3000);
    $("tsec").textContent = Math.ceil(left / 1000) + "초";
    if (left <= 0){ $("tsec").textContent = "끝!"; return; }
    timerRaf = requestAnimationFrame(tick);
  };
  tick();
}
const stopTimer = () => { cancelAnimationFrame(timerRaf); timerRaf = 0; };


/* ---------------- 시작 ---------------- */
(async function main(){
  if (configMissing()){
    return message("아직 준비가 안 됐어요",
      "Supabase 주소와 키가 설정되지 않았어요. README의 '처음 설정'을 보고 .env.local 또는 Vercel 환경 변수를 채운 뒤 다시 열어 주세요.");
  }
  await loadLevels();
  show("s-start");
  // 새로고침해도 방이 사라지지 않는다
  if (room.code && room.hostToken){
    try {
      const res = await api.hostResume(room.code, room.hostToken);
      enterRoom(res.snapshot);
    } catch {
      LS.del("code"); LS.del("token");
      room = { code: null, hostToken: null };
      show("s-start");
    }
  }
})();
