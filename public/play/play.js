// 학생 화면. 내 캐릭터만 내가 움직이고, 채점과 시간은 모두 서버가 결정한다.
import { COLORS, RANKS, NUMS, esc, rankOf } from "/shared/consts.js";
import { drawPerson, cv } from "/shared/draw.js";
import { createYard } from "/shared/yard.js";

const $ = id => document.getElementById(id);
const socket = io({ transports: ["websocket", "polling"] });

const LS = {
  get(k, d){ try { return localStorage.getItem("hq." + k) ?? d; } catch { return d; } },
  set(k, v){ try { localStorage.setItem("hq." + k, v); } catch {} },
  del(k){ try { localStorage.removeItem("hq." + k); } catch {} }
};

const me = {
  name: LS.get("name", ""),
  color: LS.get("color", "red"),
  token: LS.get("token", ""),
  code: new URLSearchParams(location.search).get("code") || LS.get("code", ""),
  id: null, score: 0
};

let yard = null, offset = 0, timerRaf = 0, answers = [], total = 10, curType = "ox", hintOpen = false;

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
  $("pname").oninput = e => { me.name = e.target.value.slice(0,8); };
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
  if (me.code && me.name) $("joinBtn").textContent = "마당에 다시 들어가기";
}
const showErr = m => { $("joinErr").textContent = m; $("joinErr").hidden = false; };

/* ---------------- 입장 ---------------- */
function doJoin(){
  $("joinBtn").disabled = true;
  socket.emit("play:join", { code: me.code, name: me.name, color: me.color, playerToken: me.token || undefined }, res => {
    $("joinBtn").disabled = false;
    if (!res || res.error){ showErr(res?.error || "들어가지 못했어요. 잠시 뒤 다시 해 보세요."); show("s-join"); return; }
    me.id = res.playerId; me.token = res.playerToken; me.name = res.name; me.color = res.color; me.score = res.score || 0;
    LS.set("token", me.token); LS.set("name", me.name); LS.set("color", me.color);
    $("chip").textContent = `${me.code}번 방 · ${me.name}`;
    ensureYard();
    yard.setMe({ id: me.id, name: me.name, color: me.color });
    applySnapshot(res.snapshot);
  });
}

function ensureYard(){
  if (yard) return;
  yard = createYard($("yard"), { name: me.name, color: me.color });
  yard.bindPad($("pad"));
  yard.on("move", p => socket.emit("play:move", p));
  yard.on("zone", z => {
    const where = $("where"), dec = $("decide");
    where.innerHTML = z
      ? (curType === "ox" ? `<b>${z.label}</b> 자리에 서 있어요.` : `<b>${z.label} ${esc(z.sub)}</b> 자리에 서 있어요.`)
      : "아직 자리를 고르지 않았어요.";
    dec.disabled = !z || dec.dataset.locked === "1";
  });
  yard.on("scroll", openHint);
  yard.start();

  $("decide").onclick = () => {
    socket.emit("play:lock", null, res => {
      if (res?.ok){
        $("decide").dataset.locked = "1";
        $("decide").disabled = true;
        $("decide").textContent = "여기로 정했어요!";
        yard.freeze(true);
        $("where").innerHTML = "자리를 정했어요. 채점을 기다려요!";
      }
    });
  };
  $("hintBtn").onclick = openHint;
}

function openHint(){
  if (hintOpen) return;
  hintOpen = true;
  yard?.setHintOpen(true);
  $("hintBtn").hidden = true;
  socket.emit("play:hint", null, res => {
    if (!res?.hint){ hintOpen = false; yard?.setHintOpen(false); $("hintBtn").hidden = false; return; }
    $("hinttext").textContent = res.hint;
    $("hintbox").hidden = false;
  });
}

/* ---------------- 서버에서 오는 것들 ---------------- */
function applySnapshot(s){
  if (!s) return show("s-wait");
  total = s.total || 10;
  if (s.you) me.score = s.you.score;
  if (s.phase === "lobby"){ waiting(s); return; }
  if (s.phase === "question" && s.question){
    onQuestion(s.question);
    if (s.you?.pending){
      $("where").textContent = "다음 문제부터 함께해요! 마당을 걸어 다녀도 돼요.";
      $("decide").disabled = true; $("decide").dataset.locked = "1";
    } else if (s.you?.locked){
      // 새로고침 전에 이미 자리를 정했다면 그 상태를 그대로 이어받는다
      $("decide").dataset.locked = "1"; $("decide").disabled = true;
      $("decide").textContent = "여기로 정했어요!";
      $("where").textContent = "자리를 정했어요. 채점을 기다려요!";
      yard.freeze(true);
    }
    if (s.you?.hintUsed) openHint();
    return;
  }
  if (s.phase === "reveal" && s.reveal){
    onQuestion({ ...s.reveal.question, qIndex: s.reveal.qIndex, total: s.reveal.total, startAt: 0, endAt: 0, now: Date.now(), seconds: 0 }, true);
    stopTimer(); $("tsec").textContent = "끝!";
    if (s.you?.answered){
      yard.setReveal({ answer: s.reveal.answer, picked: s.you.picked });
      showMyResult({
        qIndex: s.reveal.qIndex, correct: s.you.correct, picked: s.you.picked,
        answer: s.reveal.answer, answerLabel: s.reveal.answerLabel, explain: s.reveal.explain,
        score: s.you.score, timeout: s.you.picked === null
      });
    } else {
      yard.setReveal({ answer: s.reveal.answer, picked: undefined });
      showFeedbackFromReveal(s.reveal);
    }
    return;
  }
  if (s.phase === "final" && s.final){ onFinal(s.final); return; }
  waiting(s);
}

function waiting(s){
  $("waitWho").innerHTML = `<b>${esc(me.name)}</b> 님, 반가워요!`;
  $("waitCount").textContent = `지금 마당에 ${s?.count ?? 1}명 있어요`;
  show("s-wait");
}

socket.on("room:state", s => {
  total = s.total || total;
  yard?.setMeta(s.players.filter(p => p.id !== me.id));
  const mine = s.players.find(p => p.id === me.id);
  if (mine){ me.score = mine.score; me.name = mine.name; }
  if (s.phase === "lobby" && !$("s-wait").hidden) $("waitCount").textContent = `지금 마당에 ${s.count}명 있어요`;
  if (s.phase === "lobby" && $("s-quiz").hidden === false) waiting(s);
});

socket.on("room:positions", msg => yard?.applyPositions(msg));

socket.on("room:question", q => onQuestion(q));

function onQuestion(q, quiet){
  ensureYard();
  total = q.total || total;
  curType = q.type;
  hintOpen = false;
  offset = q.now ? q.now - Date.now() : 0;
  $("qnum").textContent = `${(q.qIndex ?? 0) + 1} / ${total}`;
  $("qkind").textContent = q.type === "ox" ? "O/X" : "객관식";
  $("qtext").textContent = q.q;
  if (q.type === "mc" && q.choices){
    $("choices").innerHTML = q.choices.map((c, k) => `<li><b>${NUMS[k]}</b><span>${esc(c)}</span></li>`).join("");
    $("choices").hidden = false;
  } else $("choices").hidden = true;
  $("dots").innerHTML = Array.from({ length: total }, (_, k) =>
    `<i class="${k < answers.length ? (answers[k] ? "ok" : "no") : (k === q.qIndex ? "now" : "")}"></i>`).join("");
  $("fb").hidden = true;
  document.querySelector("#s-quiz .controls").hidden = false;
  $("hintbox").hidden = true; $("hintBtn").hidden = false;
  $("decide").dataset.locked = "0"; $("decide").disabled = true; $("decide").textContent = "여기로 결정!";
  $("where").textContent = "아직 자리를 고르지 않았어요.";
  yard.setQuestion({ zones: q.zones, type: q.type });
  yard.setMe({ id: me.id, name: me.name, color: me.color });
  show("s-quiz");
  $("stage").focus({ preventScroll: true });
  if (!quiet) startTimer(q);
  window.scrollTo({ top: 0, behavior: "smooth" });
}

// 서버가 준 마감 시각에 맞춰 남은 시간을 그리기만 한다.
function startTimer(q){
  stopTimer();
  const totalMs = q.endAt - q.startAt;
  const tick = () => {
    const left = Math.max(0, q.endAt - (Date.now() + offset));
    $("tfill").style.width = (totalMs ? Math.max(0, left / totalMs * 100) : 0) + "%";
    $("tfill").classList.toggle("low", left <= 3000);
    $("tsec").textContent = Math.ceil(left / 1000) + "초";
    if (left <= 0){ $("tsec").textContent = "끝!"; return; }
    timerRaf = requestAnimationFrame(tick);
  };
  tick();
}
function stopTimer(){ cancelAnimationFrame(timerRaf); timerRaf = 0; }

socket.on("room:reveal", r => {
  stopTimer();
  $("tsec").textContent = "끝!";
  yard?.setReveal({ answer: r.answer, picked: window.__myPicked });
});

socket.on("play:result", r => showMyResult(r));

function showMyResult(r){
  window.__myPicked = r.picked;
  answers[r.qIndex] = r.correct;
  me.score = r.score;
  yard?.setReveal({ answer: r.answer, picked: r.picked });
  $("dots").innerHTML = Array.from({ length: total }, (_, k) =>
    `<i class="${k < answers.length && answers[k] !== undefined ? (answers[k] ? "ok" : "no") : ""}"></i>`).join("");
  $("verdict").className = "verdict " + (r.correct ? "ok" : "no");
  $("vsym").textContent = r.correct ? "○" : "×";
  $("vtitle").textContent = r.correct ? "정답이에요!" : (r.timeout ? "시간이 끝났어요!" : "아쉬워요!");
  if (r.correct){ $("vsub").hidden = true; }
  else {
    $("vsub").hidden = false;
    $("vsub").innerHTML = `${r.timeout ? "정답 자리에 서 있지 않았어요. " : ""}정답은 <b>${esc(r.answerLabel)}</b>예요.`;
  }
  $("explain").textContent = r.explain;
  $("myscore").textContent = `지금까지 ${me.score}점이에요`;
  document.querySelector("#s-quiz .controls").hidden = true;
  $("fb").hidden = false;
  show("s-quiz");
}

// 중간에 들어와서 이 문제는 채점하지 않은 경우에도 해설은 볼 수 있게 한다.
function showFeedbackFromReveal(r){
  $("verdict").className = "verdict";
  $("vsym").textContent = "○";
  $("vtitle").textContent = "정답을 알려 줄게요";
  $("vsub").hidden = false;
  $("vsub").innerHTML = `정답은 <b>${esc(r.answerLabel)}</b>예요.`;
  $("explain").textContent = r.explain;
  $("myscore").textContent = `지금까지 ${me.score}점이에요`;
  document.querySelector("#s-quiz .controls").hidden = true;
  $("fb").hidden = false;
  show("s-quiz");
}

socket.on("room:final", f => onFinal(f));

function onFinal(f){
  stopTimer();
  const mine = f.ranking.find(p => p.id === me.id);
  const score = mine?.score ?? me.score;
  const r = rankOf(score);
  $("finalWho").innerHTML = `${esc(me.name)} 님, ${f.questions}문제 중`;
  $("finalScore").innerHTML = `${score}<small> / ${f.questions}</small>`;
  $("finalTitle").textContent = r.title;
  $("finalSay").textContent = r.say;
  $("ladder").innerHTML = RANKS.map(x => `<span class="${x.title === r.title ? "on" : ""}">${x.title}</span>`).join("");
  $("finalPlace").textContent = mine ? `${f.ranking.length}명 중 ${mine.place}등이에요` : "";
  // 칭호는 10점 만점 기준이라, 10문제를 다 못 풀고 끝났으면 그 점을 알려 준다
  $("finalNote").hidden = f.questions >= 10;
  $("finalNote").textContent = f.questions < 10 ? `칭호는 10문제(10점 만점) 기준이에요. 이번에는 ${f.questions}문제만 풀었어요.` : "";
  $("againBtn").onclick = () => { LS.del("code"); location.href = "/play"; };
  show("s-final");
  window.scrollTo({ top: 0, behavior: "smooth" });
}

socket.on("room:closed", ({ reason }) => { LS.del("code"); message("방이 닫혔어요", reason || "진행자가 방을 닫았어요."); });
socket.on("play:kicked", () => { LS.del("code"); LS.del("token"); me.token = ""; message("마당에서 나왔어요", "진행자가 내보냈어요. 이름을 바꿔서 다시 들어와 주세요.", "다시 들어가기"); });

socket.on("disconnect", () => { $("chip").textContent = "연결이 끊겼어요… 다시 연결 중"; });
socket.on("connect", () => {
  if (me.id || (me.token && me.code && me.name)){
    $("chip").textContent = "다시 연결했어요";
    socket.emit("play:join", { code: me.code, name: me.name, color: me.color, playerToken: me.token }, res => {
      if (!res || res.error){ show("s-join"); $("chip").textContent = "입장하기"; if (res?.error) showErr(res.error); return; }
      me.id = res.playerId; me.name = res.name; me.score = res.score || 0;
      $("chip").textContent = `${me.code}번 방 · ${me.name}`;
      ensureYard(); yard.setMe({ id: me.id, name: me.name, color: me.color });
      applySnapshot(res.snapshot);
    });
  }
});

/* ---------------- 시작 ---------------- */
buildJoin();
show("s-join");
// 새로고침했는데 저장된 방이 있으면 바로 다시 들어간다(재접속).
if (me.token && me.code && me.name) $("chip").textContent = "다시 들어가는 중…";
matchMedia("(prefers-color-scheme: dark)").addEventListener?.("change", drawPreview);
(document.fonts ? document.fonts.ready : Promise.resolve()).then(drawPreview);
