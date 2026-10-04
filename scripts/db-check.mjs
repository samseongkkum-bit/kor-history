// Supabase 프로젝트에 표와 함수가 제대로 올라갔는지 확인한다.
// 비밀번호 없이 anon 키만으로 확인한다.
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
const url = (env.SUPABASE_URL || "").trim().replace(/\/rest\/v1\/?$/, "").replace(/\/$/, "");
const key = (env.SUPABASE_ANON_KEY || "").trim();

if (!url || !key) {
  console.error("\n.env.local 에 SUPABASE_URL 과 SUPABASE_ANON_KEY 를 넣어 주세요.\n");
  process.exit(1);
}
const H = { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" };
const rpc = (fn, body = {}) => fetch(`${url}/rest/v1/rpc/${fn}`, { method: "POST", headers: H, body: JSON.stringify(body) });
const ok = s => `  ✓ ${s}`, no = s => `  ✗ ${s}`;

let bad = 0;
const say = (good, msg) => { console.log(good ? ok(msg) : no(msg)); if (!good) bad++; };

console.log(`\nSupabase 확인: ${url}\n`);

// 1) 단계와 문제
const levelsRes = await rpc("get_levels");
if (!levelsRes.ok) {
  const t = await levelsRes.text();
  console.log(no(`함수를 찾을 수 없어요 (${levelsRes.status})`));
  console.log(`    ${t.slice(0, 200)}`);
  console.log("\n  → supabase/all.sql 을 SQL Editor 에 붙여넣고 Run 하셨나요?\n");
  process.exit(1);
}
const levels = await levelsRes.json();
say(Array.isArray(levels) && levels.length >= 2, `단계 ${levels.length}개: ${levels.map(l => `${l.name}(${l.total}문제)`).join(", ")}`);
for (const l of levels) say(l.total === 30, `${l.name} 문제 30개`);

// 2) 손님이 읽으면 안 되는 표
for (const t of ["questions", "room_secrets", "player_secrets", "answers", "participation"]) {
  const r = await fetch(`${url}/rest/v1/${t}?select=*&limit=1`, { headers: H });
  const rows = r.ok ? await r.json() : null;
  say(!r.ok || (Array.isArray(rows) && rows.length === 0), `${t} 표는 손님이 읽을 수 없다`);
}

// 3) 방을 만들고 들어가 보기
const createRes = await rpc("host_create_room");
if (!createRes.ok) { console.log(no(`방 만들기 실패 (${createRes.status}) ${await createRes.text()}`)); process.exit(1); }
const room = await createRes.json();
say(/^\d{4}$/.test(room.code), `방 만들기: 코드 ${room.code}`);

const joinRes = await rpc("play_join", { p_code: room.code, p_name: "점검이", p_color: "red" });
const joined = joinRes.ok ? await joinRes.json() : null;
say(!!joined?.playerToken, "학생 입장");
say(joined?.snapshot?.count === 1, "대기실 인원 1명");
say(!JSON.stringify(joined?.snapshot || {}).includes('"answer"'), "대기실 상황에 정답이 섞이지 않는다");

// 4) 정리
await rpc("host_close", { p_code: room.code, p_token: room.hostToken });
const gone = await rpc("get_snapshot", { p_code: room.code });
say((await gone.json()) === null, "점검용 방 정리 완료");

console.log(bad ? `\n${bad}가지가 어긋났어요.\n` : "\n모두 정상이에요. 이제 화면을 열면 됩니다.\n");
process.exit(bad ? 1 : 0);
