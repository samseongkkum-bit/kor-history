// migrations 파일들을 하나로 합친다. Supabase 대시보드의 SQL Editor 에 붙여넣기 위한 것.
import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const dir = join(root, "supabase", "migrations");
const files = readdirSync(dir).filter(f => f.endsWith(".sql")).sort();

let out = `-- 한옥 마당 한국사 퀴즈 — Supabase 설치용 전체 SQL
-- Supabase 대시보드 → SQL Editor 에 이 파일 전체를 붙여넣고 Run 하세요.
-- 여러 번 실행해도 괜찮습니다(문제는 지우고 다시 넣습니다).
-- 이 파일은 scripts/build-sql.mjs 가 만듭니다. 직접 고치지 말고 supabase/migrations/ 를 고치세요.

`;
for (const f of files) out += `\n\n-- ======================================================\n-- ${f}\n-- ======================================================\n\n` + readFileSync(join(dir, f), "utf8");

writeFileSync(join(root, "supabase", "all.sql"), out);
console.log(`${files.length}개 파일 → supabase/all.sql (${Math.round(out.length / 1024)}KB)`);
