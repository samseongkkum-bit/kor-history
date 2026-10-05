// 화면이 읽을 설정 파일(public/config.js)을 만든다.
// anon 키는 원래 공개용 열쇠다(표 접근은 RLS 가 막는다). 서비스 키는 절대 쓰지 않는다.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

// 로컬에서는 .env.local, Vercel 에서는 환경 변수에서 읽는다.
const env = { ...process.env };
const local = join(root, ".env.local");
if (existsSync(local)) {
  for (const line of readFileSync(local, "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && !env[m[1]]) env[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
}

// 저장소에 들어 있는 기본값. 환경 변수가 있으면 그쪽이 이긴다.
// anon 키는 원래 브라우저에 담아 쓰라고 만든 공개 열쇠이고, 표 접근은 RLS 가 막는다.
// (service_role 키는 절대 여기에 넣지 않는다.)
let base = {};
const baseFile = join(root, "supabase", "public-config.json");
if (existsSync(baseFile)) { try { base = JSON.parse(readFileSync(baseFile, "utf8")); } catch {} }

const url = (env.SUPABASE_URL || env.NEXT_PUBLIC_SUPABASE_URL || base.supabaseUrl || "")
  .trim().replace(/\/rest\/v1\/?$/, "").replace(/\/$/, "");
const key = (env.SUPABASE_ANON_KEY || env.NEXT_PUBLIC_SUPABASE_ANON_KEY || base.supabaseAnonKey || "").trim();

if (!url || !key) {
  console.warn("\n경고: Supabase 주소와 키를 찾지 못했어요.");
  console.warn("      supabase/public-config.json 에 넣거나, 환경 변수로 주세요.");
  console.warn("      지금은 빈 설정으로 만들어 둡니다(화면에 안내가 나옵니다).\n");
}
if (/service_role/.test(key)) throw new Error("service_role 키는 화면에 넣으면 안 됩니다. anon public 키를 쓰세요.");

writeFileSync(join(root, "public", "config.js"),
`// 자동으로 만들어지는 파일입니다. scripts/make-config.mjs 를 보세요.
window.__HQ = ${JSON.stringify({ supabaseUrl: url, supabaseAnonKey: key }, null, 2)};
`);
console.log(`public/config.js 작성 (${url || "주소 없음"})`);
