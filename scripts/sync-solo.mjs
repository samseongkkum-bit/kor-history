// data/questions.json 을 /solo 화면(인터넷 없이도 도는 1인용) 안의 QUIZ 객체로 옮긴다.
// 문구를 손으로 옮기지 않으므로 Supabase 와 /solo 의 문제가 늘 같다.
import { readFileSync, writeFileSync } from "node:fs";

const QUIZ = JSON.parse(readFileSync(new URL("../data/questions.json", import.meta.url), "utf8"));
const file = new URL("../public/solo/index.html", import.meta.url);
const html = readFileSync(file, "utf8");
const start = html.indexOf("const QUIZ = {");
const end = html.indexOf("\n};", start);
if (start < 0 || end < 0) throw new Error("public/solo/index.html 에서 QUIZ 객체를 찾지 못했습니다.");

const s = v => JSON.stringify(v);
const line = q => "      {" + Object.entries(q).map(([k, v]) => `${k}:${s(v)}`).join(", ") + "}";
const body = Object.entries(QUIZ).map(([key, lv]) =>
  `  ${key}: {\n    name: ${s(lv.name)}, kind: ${s(lv.kind)}, desc: ${s(lv.desc)},\n    questions: [\n` +
  lv.questions.map(line).join(",\n") + "\n    ]\n  }").join(",\n");

writeFileSync(file, html.slice(0, start) + "const QUIZ = {\n" + body + html.slice(end));
console.log(`문제 ${Object.values(QUIZ).reduce((n, l) => n + l.questions.length, 0)}개 → public/solo/index.html`);
