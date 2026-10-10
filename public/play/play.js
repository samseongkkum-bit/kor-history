// 학생 화면. 내 캐릭터만 내 기기가 움직이고, 채점과 시간은 Supabase(Postgres 함수)가 정한다.
import { COLORS, RANKS, NUMS, esc, rankOf } from "/shared/consts.js";
import { drawPerson, cv } from "/shared/draw.js";
import { createYard } from "/shared/yard.js";
import { zonesFor } from "/shared/map.js";
import { api, watchRoom, positionRelay, configMissing, NetError } from "/shared/net.js";

const $ = id => document.getElementById(id);
const LS = {
  get(k, d){ try { return localStorage.getItem("hq." + k) ?? d; } catch { return d; } },
  set(k, v){ try { localStorage.setItem("hq." + k, v); } catch {} },
  del(k){ try { localStorage.removeItem("hq." + k); } catch {} }
};

const me = {
  name: LS.get("name", ""),
  color: LS.get("color", "red"),
  token: LS.get("token", ""),
  code: (new URLSearchParams(location.search).get("code") || LS.get("code", "")).replace(/\D/g, "").slice(0, 4),
  id: null, score: 0
};

let yard = null, watch = null, relay = null, timerRaf = 0, beacon = 0;
let shownQ = -2, shownPhase = "", answers = [], total = 10, curType = "ox", hintOpen = false;

/* ---------------- 화면 바꾸기 ---------------- */
const SCREENS = ["s-join","s-wait","s-quiz","s-final","s-msg"];
function show(which){
  SCREENS.forEach(id => $(id).hidden = id !== which);
  $("foot").hidden = which !== "s-quiz";
}
function message(title, body, btn = "처음으로", onBtn){
  $("msgTitle").textContent = title; $("msgBody").textContent = body;
  $("msgBtn").textContent = btn;
  $("msgBtn").onclick = onBtn || (() => location.href = "/play");
  show("s-msg");
}
const showErr = m => { $("joinErr").textContent = m; $("joinErr").hidden = false; };

/* ---------------- 입장 화면 ---------------- */
function drawPreview(){
  const pv = $("pv"); if (!pv) return;
  const ctx = pv.getContext("2d");
  ctx.setTransform(4,0,0,4,0,0);
  ctx.fillStyle = cv("--ground"); ctx.fillRect(0,0,110,110);
  drawPerson(ctx, 55, 62, { upper: cv((COLORS.find(c=>c.id===me.color)||COLORS[0]).css), lower: cv("--meok-muted"), ribbon: cv("--red") });
}

function buildJoin(){
  $("colors").innerHTML = COLORS.map(c =>
    `<button class="swatch" type="button" data-color="${c.id}" aria-label="${c.label}" aria-pressed="${me.color===c.id}" style="background:var(${c.css})"></button>`
  ).join("");
  $("colors").querySelectorAll("[data-color]").forEach(b => b.onclick = () => {
    me.color = b.dataset.color; LS.set("color", me.color);
    $("colors").querySelectorAll("[data-color]").forEach(x => x.setAttribute("aria-pressed", String(x === b)));
    drawPreview();
  });
  $("code").value = me.code || "";
  $("pname").value = me.name || "";
  $("code").oninput = e => { e.target.value = e.target.value.replace(/\D/g, "").slice(0,4); };
  $("joinBtn").onclick = () => {
    const code = $("code").value.trim();
    const name = $("pname").value.trim().slice(0,8);
    if (code.length !== 4) return showErr("입장 코드 숫자 4자리를 써 주세요.");
    if (!name) return showErr("이름을 써 주세요. 별명도 괜찮아요!");
    me.code = code; me.name = name;
    LS.set("code", code); LS.set("name", name);
    $("joinErr").hidden = true;
    doJoin();
  };
  drawPreview();
}

/* ---------------- 입장 ---------------- */
async function doJoin(){
  $("joinBtn").disabled = true;
  $("chip").textContent = "들어가는 중…";
  try {
    const res = await api.playJoin(me.code, me.name, me.color, me.token || null);
    me.id = res.playerId; me.token = res.playerToken;
    LS.set("token", me.token);
    const you = res.snapshot?.you;
    if (you){ me.name = you.name; me.color = you.color; me.score = you.score; LS.set("name", me.name); }
    $("chip").textContent = `${me.code}번 방 · ${me.name}`;
    ensureYard();
    startWatching();
  } catch (e) {
    $("chip").textContent = "입장하기";
    showErr(e instanceof NetError ? e.message : "들어가지 못했어요. 잠시 뒤 다시 해 보세요.");
    show("s-join");
  } finally {
    $("joinBtn").disabled = false;
  }
}

function startWatching(){
  watch?.stop(); relay?.stop();
  watch = watchRoom({
    code: me.code, playerToken: me.token, isHost: false,
    onSnapshot: s => s ? render(s) : message("방이 닫혔어요", "진행자가 방을 닫았거나 시간이 지나 사라졌어요."),
    onError: e => console.warn(e.message)
  });
  relay = positionRelay(watch.channel, { isHost: false, onAll: p => yard?.applyPositions(p) });

  // 가만히 서 있어도 1초에 한 번은 "나 여기 있어요"를 알린다.
  // 이게 없으면 한 번도 안 움직인 학생이 진행자 화면과 친구들 화면에 보이지 않는다.
  clearInterval(beacon);
  beacon = setInterval(() => {
    if (!yard || !me.id) return;
    const p = yard.me();
    relay?.send(me.id, p.x, p.y, false);
  }, 1000);
}

/* ---------------- 마당 ---------------- */
function ensureYard(){
  if (yard) return;
  yard = createYard($("yard"), { name: me.name, color: me.color });
  yard.bindPad($("pad"));
  yard.setMe({ id: me.id, name: me.name, color: me.color });

  yard.on("move", p => {
    relay?.send(me.id, p.x, p.y, true);
    posToServer(p);                       // 서버에도 이따금 알려 둔다(마감 때 이 위치로 채점한다)
  });
  yard.on("zone", z => {
    const dec = $("decide");
    $("where").innerHTML = z
      ? (curType === "ox" ? `<b>${z.label}</b> 자리에 서 있어요.` : `<b>${z.label} ${esc(z.sub)}</b> 자리에 서 있어요.`)
      : "아직 자리를 고르지 않았어요.";
    dec.disabled = !z || dec.dataset.locked === "1";
  });
  yard.on("scroll", openHint);
  yard.start();

  $("decide").onclick = async () => {
    const p = yard.me();
    $("decide").disabled = true;
    try {
      const r = await api.playLock(me.token, p.x, p.y);
      if (r?.ok){
        $("decide").dataset.locked = "1";
        $("decide").textContent = "여기로 정했어요!";
        yard.freeze(true);
        $("where").textContent = "자리를 정했어요. 채점을 기다려요!";
      } else {
        $("decide").disabled = false;
      }
    } catch { $("decide").disabled = false; }
  };
  $("hintBtn").onclick = openHint;
}

// 위치를 서버에 알리는 간격. 자주 보내면 요청이 너무 많아지고,
// 너무 드물면 마감 순간의 자리가 어긋나므로 1초에 한 번 + 마감 직전에 한 번 보낸다.
let lastSent = 0, finalSendTimer = 0, pendingPos = null;
function posToServer(p){
  pendingPos = p;
  const now = performance.now();
  if (now - lastSent < 1000) return;
  lastSent = now;
  api.playMove(me.token, p.x, p.y).catch(() => {});
}
function scheduleFinalPos(endsAtMs){
  clearTimeout(finalSendTimer);
  const wait = endsAtMs - watch.serverNow() - 1200;
  if (wait < 0) return;
  finalSendTimer = setTimeout(() => {
    const p = pendingPos || yard?.me();
    if (p) api.playMove(me.token, p.x, p.y).catch(() => {});
  }, wait);
}

async function openHint(){
  if (hintOpen) return;
  hintOpen = true;
  yard?.setHintOpen(true);
  $("hintBtn").hidden = true;
  try {
    const r = await api.playHint(me.token);
    if (!r?.hint) throw new Error();
    $("hinttext").textContent = r.hint;
    $("hintbox").hidden = false;
  } catch {
    hintOpen = false; yard?.setHintOpen(false); $("hintBtn").hidden = false;
  }
}

/* ---------------- 지금 상황 그리기 ---------------- */
function render(s){
  total = s.total || total;
  if (s.you){ me.score = s.you.score; me.name = s.you.name || me.name; me.id = s.you.id || me.id; }
  yard?.setMe({ id: me.id, name: me.name, color: me.color });
  yard?.setMeta((s.players || []).filter(p => p.id !== me.id));

  if (s.phase === "lobby")    return renderWait(s);
  if (s.phase === "question") return renderQuestion(s);
  if (s.phase === "reveal")   return renderReveal(s);
  if (s.phase === "final")    return renderFinal(s);
}

function renderWait(s){
  shownQ = -2; shownPhase = "lobby";
  $("waitWho").innerHTML = `<b>${esc(me.name)}</b> 님, 반가워요!`;
  $("waitCount").textContent = `지금 마당에 ${s.count ?? 1}명 있어요`;
  show("s-wait");
}

function renderQuestion(s){
  const q = s.question; if (!q) return;
  const fresh = s.qIndex !== shownQ || shownPhase !== "question";
  curType = q.type;

  if (fresh){
    shownQ = s.qIndex; shownPhase = "question";
    hintOpen = false;
    $("qnum").textContent = `${s.qIndex + 1} / ${total}`;
    $("qkind").textContent = q.type === "ox" ? "O/X" : "객관식";
    $("qtext").textContent = q.q;
    $("choices").hidden = !(q.type === "mc" && q.choices);
    if (q.type === "mc" && q.choices)
      $("choices").innerHTML = q.choices.map((c, k) => `<li><b>${NUMS[k]}</b><span>${esc(c)}</span></li>`).join("");
    $("fb").hidden = true;
    document.querySelector("#s-quiz .controls").hidden = false;
    $("hintbox").hidden = true; $("hintBtn").hidden = false;
    $("decide").dataset.locked = "0"; $("decide").disabled = true; $("decide").textContent = "여기로 결정!";
    $("where").textContent = "아직 자리를 고르지 않았어요.";
    yard.setQuestion({ zones: zonesOf(q), type: q.type });
    yard.setMe({ id: me.id, name: me.name, color: me.color });
    drawDots();
    show("s-quiz");
    $("stage").focus({ preventScroll: true });
    startTimer(s);
    scheduleFinalPos(new Date(s.endsAt).getTime());
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  // 새로고침했어도 "이미 정했다 / 이번 문제는 쉰다 / 힌트를 봤다"를 그대로 이어받는다
  if (s.you?.pending){
    $("where").textContent = "다음 문제부터 함께해요! 마당을 걸어 다녀도 돼요.";
    $("decide").dataset.locked = "1"; $("decide").disabled = true;
    $("hintBtn").hidden = true;
  } else if (s.you?.locked && $("decide").dataset.locked !== "1"){
    $("decide").dataset.locked = "1"; $("decide").disabled = true;
    $("decide").textContent = "여기로 정했어요!";
    $("where").textContent = "자리를 정했어요. 채점을 기다려요!";
    yard.freeze(true);
  }
  if (s.you?.hintUsed && !hintOpen) openHint();
}

// 서버가 준 마감 시각에 맞춰 남은 시간을 그리기만 한다.
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

function drawDots(){
  $("dots").innerHTML = Array.from({ length: total }, (_, k) =>
    `<i class="${answers[k] === true ? "ok" : answers[k] === false ? "no" : (k === shownQ ? "now" : "")}"></i>`).join("");
}

function renderReveal(s){
  const q = s.question; if (!q) return;
  if (shownPhase !== "reveal" || shownQ !== s.qIndex){
    // 이 문제를 못 보고 들어왔다면 문제부터 그려 준다
    if (shownQ !== s.qIndex){
      shownQ = s.qIndex;
      $("qnum").textContent = `${s.qIndex + 1} / ${total}`;
      $("qkind").textContent = q.type === "ox" ? "O/X" : "객관식";
      $("qtext").textContent = q.q;
      $("choices").hidden = !(q.type === "mc" && q.choices);
      if (q.type === "mc" && q.choices)
        $("choices").innerHTML = q.choices.map((c, k) => `<li><b>${NUMS[k]}</b><span>${esc(c)}</span></li>`).join("");
      yard.setQuestion({ zones: zonesOf(q), type: q.type });
    }
    shownPhase = "reveal";
  }
  stopTimer();
  $("tsec").textContent = "끝!";
  clearTimeout(finalSendTimer);

  const you = s.you;
  const mine = you && you.answered;
  yard.setReveal({ answer: q.answer, picked: mine ? you.picked : undefined });

  if (mine){
    answers[s.qIndex] = !!you.correct;
    const timeout = you.picked === null || you.picked === undefined;
    $("verdict").className = "verdict " + (you.correct ? "ok" : "no");
    $("vsym").textContent = you.correct ? "○" : "×";
    $("vtitle").textContent = you.correct ? "정답이에요!" : (timeout ? "시간이 끝났어요!" : "아쉬워요!");
    $("vsub").hidden = !!you.correct;
    if (!you.correct)
      $("vsub").innerHTML = `${timeout ? "정답 자리에 서 있지 않았어요. " : ""}정답은 <b>${esc(q.answerLabel)}</b>예요.`;
  } else {
    // 중간에 들어와 이번 문제는 쉰 경우에도 해설은 보여 준다
    $("verdict").className = "verdict";
    $("vsym").textContent = "○";
    $("vtitle").textContent = "정답을 알려 줄게요";
    $("vsub").hidden = false;
    $("vsub").innerHTML = `정답은 <b>${esc(q.answerLabel)}</b>예요.`;
  }
  $("explain").textContent = q.explain || "";
  $("myscore").textContent = `지금까지 ${me.score}점이에요`;
  drawDots();
  document.querySelector("#s-quiz .controls").hidden = true;
  $("fb").hidden = false;
  show("s-quiz");
}

function renderFinal(s){
  stopTimer();
  shownPhase = "final";
  const mine = (s.ranking || []).find(p => p.id === me.id);
  const score = mine?.score ?? me.score;
  const r = rankOf(score);
  const qs = s.questions ?? total;
  $("finalWho").innerHTML = `${esc(me.name)} 님, ${qs}문제 중`;
  $("finalScore").innerHTML = `${score}<small> / ${qs}</small>`;
  $("finalTitle").textContent = r.title;
  $("finalSay").textContent = r.say;
  $("ladder").innerHTML = RANKS.map(x => `<span class="${x.title === r.title ? "on" : ""}">${x.title}</span>`).join("");
  $("finalPlace").textContent = mine ? `${s.ranking.length}명 중 ${mine.place}등이에요` : "";
  $("finalNote").hidden = qs >= 10;
  $("finalNote").textContent = qs < 10 ? `칭호는 10문제(10점 만점) 기준이에요. 이번에는 ${qs}문제만 풀었어요.` : "";
  $("againBtn").onclick = () => { LS.del("code"); location.href = "/play"; };
  // 진행자가 새 방으로 다시 불렀으면 버튼 하나로 옮겨 간다
  const invite = s.you?.invite;
  $("inviteBox").hidden = !invite;
  if (invite){
    $("inviteCode").textContent = invite;
    $("inviteBtn").onclick = acceptInvite;
  }
  show("s-final");
  window.scrollTo({ top: 0, behavior: "smooth" });
}

async function acceptInvite(){
  $("inviteBtn").disabled = true;
  try {
    const res = await api.playAccept(me.token);
    me.code = res.code; me.id = res.playerId; me.token = res.playerToken;
    LS.set("code", me.code); LS.set("token", me.token);
    const you = res.snapshot?.you;
    if (you){ me.name = you.name; me.color = you.color; me.score = you.score; LS.set("name", me.name); }
    // 새 방에서는 처음부터 다시 센다
    answers = []; shownQ = -2; shownPhase = ""; me.score = you?.score ?? 0;
    history.replaceState(null, "", `/play?code=${me.code}`);
    $("chip").textContent = `${me.code}번 방 · ${me.name}`;
    yard?.setMe({ id: me.id, name: me.name, color: me.color });
    startWatching();
  } catch (e) {
    message("새 방에 들어가지 못했어요", e instanceof NetError ? e.message : "잠시 뒤 다시 해 보세요.",
            "다시 해 보기", () => location.reload());
  } finally {
    $("inviteBtn").disabled = false;
  }
}

// 구역 좌표는 화면에서 계산한다(판정은 서버가 같은 규칙으로 따로 한다).
const zonesOf = q => zonesFor({ t: q.type, c: q.choices });

/* ---------------- 시작 ---------------- */
if (configMissing()){
  message("아직 준비가 안 됐어요", "Supabase 주소와 키가 설정되지 않았어요. 선생님께 알려 주세요. (README의 '처음 설정'을 보세요)", "다시 열기", () => location.reload());
} else {
  buildJoin();
  show("s-join");
  matchMedia("(prefers-color-scheme: dark)").addEventListener?.("change", drawPreview);
  (document.fonts ? document.fonts.ready : Promise.resolve()).then(drawPreview);
  // 새로고침했는데 들어가 있던 방이 있으면 바로 다시 들어간다(재접속)
  if (me.token && me.code && me.name) doJoin();
}

window.addEventListener("pagehide", () => { if (me.token) api.playLeave(me.token).catch(() => {}); });
