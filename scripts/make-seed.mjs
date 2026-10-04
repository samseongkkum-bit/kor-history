// data/questions.json 을 그대로 SQL seed 로 바꾼다. 문구를 손으로 옮기지 않으므로 한 글자도 바뀌지 않는다.
import { readFileSync, writeFileSync } from "node:fs";

const QUIZ = JSON.parse(readFileSync(new URL("../data/questions.json", import.meta.url), "utf8"));
const lit = v => v === null || v === undefined ? "null" : `'${String(v).replace(/'/g, "''")}'`;

let sql = `-- data/questions.json 에서 자동으로 만든 파일입니다. 직접 고치지 말고
-- data/questions.json 을 고친 뒤 \`npm run seed\` 를 실행하세요.

delete from questions;
delete from levels;

insert into levels(key, name, kind, descr, sort) values\n`;

sql += Object.entries(QUIZ).map(([key, lv], i) =>
  `  (${lit(key)}, ${lit(lv.name)}, ${lit(lv.kind)}, ${lit(lv.desc)}, ${i})`).join(",\n") + ";\n\n";

sql += "insert into questions(level, idx, type, q, choices, answer, hint, explain) values\n";
const rows = [];
for (const [key, lv] of Object.entries(QUIZ)){
  lv.questions.forEach((q, idx) => {
    const choices = q.t === "mc" ? `${lit(JSON.stringify(q.c))}::jsonb` : "null";
    const answer = q.t === "mc" ? String(q.a) : q.a;
    rows.push(`  (${lit(key)}, ${idx}, ${lit(q.t)}, ${lit(q.q)}, ${choices}, ${lit(answer)}, ${lit(q.hint)}, ${lit(q.ex)})`);
  });
}
sql += rows.join(",\n") + ";\n";

writeFileSync(new URL("../supabase/migrations/0004_seed_questions.sql", import.meta.url), sql);
console.log(`문제 ${rows.length}개 → supabase/migrations/0004_seed_questions.sql`);
