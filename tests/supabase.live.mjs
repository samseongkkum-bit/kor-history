// 진짜 Supabase 프로젝트에 대고 한 판(10문제)을 끝까지 돌려 본다.
// 실행: npm run test:live   (.env.local 의 SUPABASE_URL / SUPABASE_ANON_KEY 를 쓴다)
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const env = { ...process.env };
const local = join(root, ".env.local");
if (existsSync(local)) for (const line of readFileSync(local, "utf8").split("\n")) {
  const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
  if (m && !env[m[1]]) env[m[1]] = m[2].replace(/^["']|["']$/g, "");
}
const URL_ = (env.SUPABASE_URL || "").trim().replace(/\/rest\/v1\/?$/, "").replace(/\/$/, "");
const KEY = (env.SUPABASE_ANON_KEY || "").trim();
if (!URL_ || !KEY) { console.error(".env.local 에 SUPABASE_URL / SUPABASE_ANON_KEY 가 필요해요."); process.exit(1); }

const QUIZ = JSON.parse(readFileSync(join(root, "data/questions.json"), "utf8"));
const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" };
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function rpc(fn, body = {}){
  const r = await fetch(`${URL_}/rest/v1/rpc/${fn}`, { method: "POST", headers: H, body: JSON.stringify(body) });
  const text = await r.text();
  if (!r.ok) throw new Error(`${fn}: ${r.status} ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : null;
}

let fails = 0;
const check = (ok, msg) => { console.log(`  ${ok ? "✓" : "✗"} ${msg}`); if (!ok) fails++; };
const zoneCenter = (type, key) => type === "ox"
  ? (key === "O" ? [260, 320] : [700, 320])
  : [[260,220],[700,220],[260,390],[700,390]][Number(key)];

// 마당을 가로질러 걸어간다. 서버가 걷는 속도보다 빠른 이동을 막으므로 나눠서 보낸다.
async function walk(token, [x, y]){
  for (let i = 1; i <= 8; i++){
    await rpc("play_move", { p_token: token, p_x: 480 + (x - 480) * i / 8, p_y: 540 + (y - 540) * i / 8 });
    await sleep(160);
  }
}

console.log(`\n실제 Supabase 한 판 돌리기: ${URL_}\n`);
const t0 = Date.now();

/* ---------- 방과 학생 ---------- */
const room = await rpc("host_create_room");
const code = room.code, host = room.hostToken;
console.log(`방 ${code}`);

const mk = async (name, color) => {
  const r = await rpc("play_join", { p_code: code, p_name: name, p_color: color });
  return { name, id: r.playerId, token: r.playerToken, results: [] };
};
const A = await mk("가", "red"), B = await mk("나", "cheong"), C = await mk("다", "hwang");

// 같은 이름이면 숫자가 붙는다
const dup = await rpc("play_join", { p_code: code, p_name: "가", p_color: "red" });
check(dup.snapshot.players.some(p => p.name === "가2"), "같은 이름이면 뒤에 숫자가 붙는다");
await rpc("host_kick", { p_code: code, p_token: host, p_player: dup.playerId });

let snap = await rpc("get_snapshot", { p_code: code });
check(snap.count === 3, `대기실 인원 3명 (${snap.count})`);
check(snap.phase === "lobby", "대기실 상태");

/* ---------- 시작 ---------- */
await rpc("host_set_level", { p_code: code, p_token: host, p_level: "elem" });
await rpc("host_start", { p_code: code, p_token: host });

for (let i = 0; i < 10; i++){
  snap = await rpc("get_snapshot", { p_code: code });
  if (snap.qIndex !== i) { check(false, `문제 번호가 ${i} 여야 하는데 ${snap.qIndex}`); break; }
  const q = snap.question;
  const src = QUIZ.elem.questions.find(x => x.q === q.q);
  if (!src){ check(false, `문제를 questions.json 에서 찾지 못함: ${q.q}`); break; }

  if (i === 0){
    check(!("answer" in q), "마감 전에는 정답이 내려오지 않는다");
    check(!("explain" in q), "마감 전에는 해설이 내려오지 않는다");
    check(!("hint" in q), "힌트는 문제에 담기지 않는다");
    check(JSON.stringify(snap).indexOf(src.hint) === -1, "방 상황 어디에도 힌트가 없다");
  }

  const right = src.a, wrong = right === "O" ? "X" : "O";
  await Promise.all([
    walk(A.token, zoneCenter("ox", right)),
    walk(B.token, zoneCenter("ox", wrong)),
    walk(C.token, zoneCenter("ox", i < 5 ? right : wrong))
  ]);

  // 가는 "여기로 결정!"을 누른다
  const lock = await rpc("play_lock", { p_token: A.token });
  if (i === 0) check(lock.ok === true, "정답 자리에서 결정할 수 있다");

  // 힌트는 물어본 학생에게만
  if (i === 1){
    const h = await rpc("play_hint", { p_token: A.token });
    check(h.hint === src.hint, "힌트를 본인만 받는다");
    const other = await rpc("get_snapshot", { p_code: code, p_player_token: B.token });
    check(JSON.stringify(other).indexOf(src.hint) === -1, "다른 학생 화면에는 힌트가 없다");
  }

  // 마감 전에 채점하려 하면 거절당한다
  if (i === 0){
    let refused = false;
    try { await rpc("grade_question", { p_code: code }); } catch (e) { refused = /시간이 남았/.test(e.message); }
    check(refused, "마감 전에는 채점할 수 없다");
  }

  // 서버가 정한 마감 시각까지 기다렸다가 채점
  const wait = new Date(snap.endsAt).getTime() - new Date(snap.now).getTime() + 400;
  await sleep(Math.max(0, wait));
  await rpc("grade_question", { p_code: code });
  await rpc("grade_question", { p_code: code });        // 두 번 불러도 같아야 한다

  snap = await rpc("get_snapshot", { p_code: code, p_player_token: A.token });
  if (i === 0){
    check(snap.phase === "reveal", "채점 뒤에는 정답 공개");
    check(snap.question.explain === src.ex, "해설이 원본과 같다");
    check(!!snap.question.answerLabel, "정답을 읽을 수 있는 말로 알려 준다");
  }
  check(snap.you.score === i + 1, `${i + 1}번째 문제까지 가의 점수 ${snap.you.score}`);
  await rpc("host_next", { p_code: code, p_token: host });
}

/* ---------- 최종 ---------- */
snap = await rpc("get_snapshot", { p_code: code });
check(snap.phase === "final", "10문제를 다 풀면 최종 결과");
const rank = snap.ranking || [];
check(rank.length === 3, `3명의 순위 (${rank.length})`);
const row = n => rank.find(p => p.name === n);
check(row("가")?.score === 10 && row("가")?.title === "왕",   `가 10점 왕 (${row("가")?.score}점 ${row("가")?.title})`);
check(row("다")?.score === 5  && row("다")?.title === "평민", `다 5점 평민 (${row("다")?.score}점 ${row("다")?.title})`);
check(row("나")?.score === 0  && row("나")?.title === "천민", `나 0점 천민 (${row("나")?.score}점 ${row("나")?.title})`);
check(row("가")?.place === 1 && row("다")?.place === 2 && row("나")?.place === 3, "순위 차례가 맞다");
check(Number(row("가")?.bonus) > 0, `결정을 누른 가에게 빠르기 보너스 (${row("가")?.bonus})`);
check(Number(row("다")?.bonus) === 0, "결정을 안 누르면 보너스 없음");

/* ---------- 재접속 ---------- */
const again = await rpc("play_join", { p_code: code, p_name: "아무이름", p_color: "red", p_token: C.token });
check(again.rejoined === true, "같은 기기면 재접속으로 이어진다");
check(again.snapshot.you.name === "다" && again.snapshot.you.score === 5, "이름과 점수가 그대로");

/* ---------- 참여 기록 ---------- */
check(snap.todayTotal >= 3, `오늘 참여 인원 합계에 더해졌다 (${snap.todayTotal}명)`);
const part = await fetch(`${URL_}/rest/v1/participation?select=*`, { headers: H });
const partRows = part.ok ? await part.json() : null;
check(!part.ok || (Array.isArray(partRows) && partRows.length === 0), "참여 기록은 손님이 읽을 수 없다");

/* ---------- 정리 ---------- */
await rpc("host_close", { p_code: code, p_token: host });
check((await rpc("get_snapshot", { p_code: code })) === null, "방을 닫으면 사라진다");

console.log(`\n${fails ? `${fails}가지 어긋남` : "모두 통과"} · ${Math.round((Date.now() - t0) / 1000)}초\n`);
process.exit(fails ? 1 : 0);
