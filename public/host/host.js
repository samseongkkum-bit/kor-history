// 진행자 화면. 방을 만들고, 단계를 고르고, 문제를 넘긴다. 마당은 관전용으로 크게 보여 준다.
import { COLORS, esc } from "/shared/consts.js";
import { drawPerson, cv } from "/shared/draw.js";
import { createYard } from "/shared/yard.js";

const $ = id => document.getElementById(id);
const socket = io({ transports: ["websocket", "polling"] });

const LS = {
  get: k => { try { return localStorage.getItem("hqh." + k); } catch { return null; } },
  set: (k,v) => { try { localStorage.setItem("hqh." + k, v); } catch {} },
  del: k => { try { localStorage.removeItem("hqh." + k); } catch {} }
};

let room = { code: LS.get("code"), hostToken: LS.get("token"), joinBase: location.origin };
let yard = null, levels = [], offset = 0, timerRaf = 0, phase = "lobby", lastPlayers = "";

/* ---------------- 화면 ---------------- */
const show = which => ["s-start","s-game","s-final","s-msg"].forEach(id => $(id).hidden = id !== which);
const message = (t, b) => { $("msgTitle").textContent = t; $("msgBody").textContent = b; show("s-msg"); };

fetch("/api/info").then(r => r.json()).then(info => {
  levels = info.levels;
  room.joinBase = info.joinBase || location.origin;
  $("today").textContent = `오늘 참여 인원 합계 ${info.todayTotal}명`;
  $("pmax").textContent = `(최대 ${info.maxPlayers}명)`;
  $("startNote").textContent = `학생 기기가 들어올 주소: ${room.joinBase}/play`;
  buildLevels();
}).catch(() => {});

function buildLevels(){
  $("levels").innerHTML = levels.map(l =>
    `<button class="lvbtn" type="button" data-level="${l.key}" aria-pressed="false"><b>${esc(l.name)}</b><span>${esc(l.kind)} · ${l.total}문제</span></button>`
  ).join("") + `<button class="lvbtn" type="button" disabled><b>고등부</b><span>준비 중</span></button>`;
  $("levels").querySelectorAll("[data-level]").forEach(b => b.onclick = () => socket.emit("host:setLevel", { level: b.dataset.level }));
}

/* ---------------- 방 ---------------- */
$("createBtn").onclick = () => {
  $("createBtn").disabled = true;
  socket.emit("host:create", {}, res => {
    $("createBtn").disabled = false;
    if (!res || res.error) return message("방을 만들지 못했어요", res?.error || "잠시 뒤 다시 해 주세요.");
    enterRoom(res);
  });
};

function enterRoom(res){
  room = { code: res.code, hostToken: res.hostToken, joinBase: res.joinBase || room.joinBase };
  LS.set("code", room.code); LS.set("token", room.hostToken);
  $("code").textContent = room.code;
  const url = `${room.joinBase}/play?code=${room.code}`;
  $("joinurl").textContent = url;
  // QR은 서버가 qrcode 패키지로 만들어 주는 SVG를 그대로 넣는다(외부 CDN 없음).
  fetch(`/api/qr?text=${encodeURIComponent(url)}`).then(r => r.text()).then(svg => { $("qr").innerHTML = svg; }).catch(() => { $("qr").textContent = "QR 없음"; });
  ensureYard();
  applySnapshot(res.snapshot);
}

function ensureYard(){
  if (yard) return;
  yard = createYard($("yard"), { spectator: true });
  yard.start();
}

/* ---------------- 조작 ---------------- */
$("startBtn").onclick = () => socket.emit("host:start");
$("nextBtn").onclick = () => socket.emit("host:next");
$("endBtn").onclick = () => { if (confirm("게임을 지금 끝내고 최종 순위를 보여 줄까요?")) socket.emit("host:endGame"); };
$("againBtn").onclick = () => socket.emit("host:start");
$("lobbyBtn").onclick = () => { show("s-game"); $("qcard").hidden = true; $("revealcard").hidden = true; yard?.clearZones(); };

/* ---------------- 상태 ---------------- */
socket.on("room:state", s => render(s));

function applySnapshot(s){
  if (!s) return;
  render(s);
  if (s.phase === "question" && s.question) onQuestion(s.question);
  if (s.phase === "reveal" && s.reveal){
    yard.setQuestion({ zones: s.reveal.question.zones, type: s.reveal.question.type });
    fillQuestion({ qIndex: s.reveal.qIndex, total: s.reveal.total, type: s.reveal.question.type, q: s.reveal.question.q });
    onReveal(s.reveal);
  }
  if (s.phase === "final" && s.final) onFinal(s.final);
}

function render(s){
  phase = s.phase;
  show(s.phase === "final" ? "s-final" : "s-game");
  if (s.phase === "final") $("s-game").hidden = true;
  $("code").textContent = s.code;
  $("today").textContent = `오늘 참여 인원 합계 ${s.todayTotal}명`;
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
  $("startBtn").disabled = s.count === 0;
  $("nextBtn").hidden = s.phase !== "reveal";
  $("endBtn").disabled = s.phase === "lobby";
  $("plabel").textContent = s.phase === "lobby" ? "들어온 학생" : "학생";
  $("pcount").textContent = s.count;
  yard?.setMeta(s.players);
  renderPlayers(s.players, s.phase);
  if (s.phase === "lobby"){ $("qcard").hidden = true; $("revealcard").hidden = true; $("boardcard").hidden = true; $("zoneline").textContent = ""; }
}

function renderPlayers(players, ph){
  const key = JSON.stringify(players) + ph;
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
    drawPerson(ctx, 29, 58, { upper: cv((COLORS.find(c => c.id === p.color) || COLORS[0]).css), lower: cv("--meok-muted"), ribbon: cv("--red") });
    li.appendChild(cvs);
    const nm = document.createElement("span");
    nm.className = "nm";
    nm.textContent = p.name;
    li.appendChild(nm);
    if (p.pending){ const s = document.createElement("span"); s.className = "off"; s.textContent = "다음 문제부터"; li.appendChild(s); }
    if (!p.connected){ const s = document.createElement("span"); s.className = "off"; s.textContent = "연결 끊김"; li.appendChild(s); }
    if (p.locked && ph === "question"){ const s = document.createElement("span"); s.className = "lock"; s.textContent = "결정!"; li.appendChild(s); }
    if (ph !== "lobby"){ const s = document.createElement("span"); s.className = "sc"; s.textContent = `${p.score}점`; li.appendChild(s); }
    const k = document.createElement("button");
    k.className = "kick"; k.type = "button"; k.textContent = "내보내기";
    k.onclick = () => { if (confirm(`${p.name} 학생을 내보낼까요?`)) socket.emit("host:kick", { playerId: p.id }); };
    li.appendChild(k);
    ul.appendChild(li);
  }
}

socket.on("room:positions", msg => yard?.applyPositions(msg));
socket.on("room:zoneCounts", ({ counts, none }) => {
  yard?.setCounts(counts);
  const parts = Object.entries(counts).map(([k, n]) => `${label(k)} ${n}명`);
  if (none) parts.push(`자리 밖 ${none}명`);
  $("zoneline").textContent = parts.join("  ·  ");
});
let curZones = [];
const label = k => (curZones.find(z => String(z.key) === String(k))?.label) || k;

socket.on("room:question", q => onQuestion(q));

function fillQuestion(q){
  $("qnum").textContent = `${q.qIndex + 1} / ${q.total}`;
  $("qkind").textContent = q.type === "ox" ? "O/X" : "객관식";
  $("qtext").textContent = q.q;
  $("qcard").hidden = false;
  $("revealcard").hidden = true;
}

function onQuestion(q){
  ensureYard();
  curZones = q.zones || [];
  fillQuestion(q);
  yard.setQuestion({ zones: q.zones, type: q.type });
  offset = q.now ? q.now - Date.now() : 0;
  startTimer(q);
  show("s-game");
}

function startTimer(q){
  stopTimer();
  const totalMs = q.endAt - q.startAt;
  const tick = () => {
    const left = Math.max(0, q.endAt - (Date.now() + offset));
    $("tfill").style.width = (totalMs ? left / totalMs * 100 : 0) + "%";
    $("tfill").classList.toggle("low", left <= 3000);
    $("tsec").textContent = Math.ceil(left / 1000) + "초";
    if (left <= 0){ $("tsec").textContent = "끝!"; return; }
    timerRaf = requestAnimationFrame(tick);
  };
  tick();
}
const stopTimer = () => { cancelAnimationFrame(timerRaf); timerRaf = 0; };

socket.on("room:reveal", r => onReveal(r));

function onReveal(r){
  stopTimer();
  $("tsec").textContent = "끝!";
  yard?.setReveal({ answer: r.answer });
  yard?.setCounts(null);
  $("ranswer").textContent = r.answerLabel;
  $("rexplain").textContent = r.explain;
  $("rsym").textContent = "○";
  $("revealcard").hidden = false;
  $("boardcard").hidden = false;
  $("top5").innerHTML = r.leaderboard.map(p =>
    `<li><span class="no">${p.place}</span><span class="nm">${esc(p.name)}</span><span class="sc">${p.score}점</span></li>`
  ).join("") || `<li class="muted">아직 점수가 없어요</li>`;
  $("nextBtn").textContent = r.last ? "최종 결과 보기" : "다음 문제";
  $("zoneline").textContent = "";
}

socket.on("room:final", f => onFinal(f));

function onFinal(f){
  stopTimer();
  $("finalHead").textContent = `${f.ranking.length}명 참여 · ${f.questions}문제 · 오늘 참여 인원 합계 ${f.todayTotal}명`;
  $("today").textContent = `오늘 참여 인원 합계 ${f.todayTotal}명`;
  $("finalList").innerHTML = f.ranking.map(p =>
    `<li><span class="no">${p.place}</span><span class="nm">${esc(p.name)}</span><span class="ti">${esc(p.title)}</span><span class="sc">${p.score}점</span></li>`
  ).join("") || `<li class="muted">참여한 학생이 없어요</li>`;
  show("s-final");
}

socket.on("room:closed", ({ reason }) => { LS.del("code"); LS.del("token"); message("방이 닫혔어요", reason || ""); });

/* ---------------- 새로고침해도 방이 사라지지 않게 ---------------- */
socket.on("connect", () => {
  if (room.code && room.hostToken){
    socket.emit("host:resume", { code: room.code, hostToken: room.hostToken }, res => {
      if (!res || res.error){ LS.del("code"); LS.del("token"); room = { code: null, hostToken: null, joinBase: room.joinBase }; show("s-start"); return; }
      enterRoom(res);
    });
  } else show("s-start");
});
socket.on("disconnect", () => { $("phase").textContent = "연결이 끊겼어요… 다시 연결 중"; });

show("s-start");
