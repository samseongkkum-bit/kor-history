// hanguksa-quiz-single.html 안의 QUIZ 객체를 그대로 data/questions.json으로 옮긴다.
// 문구를 손으로 옮겨 적지 않고 그대로 평가해서 쓰기 때문에 한 글자도 바뀌지 않는다.
import { readFileSync, writeFileSync } from "node:fs";

const html = readFileSync(new URL("../hanguksa-quiz-single.html", import.meta.url), "utf8");
const start = html.indexOf("const QUIZ = {");
const end = html.indexOf("\n};", start);
if (start < 0 || end < 0) throw new Error("QUIZ 객체를 찾지 못했습니다.");
const src = html.slice(start + "const QUIZ = ".length, end + 2);
const QUIZ = new Function("return " + src)();

let total = 0;
for (const [k, lv] of Object.entries(QUIZ)) {
  const ox = lv.questions.filter(q => q.t === "ox").length;
  const mc = lv.questions.filter(q => q.t === "mc").length;
  total += lv.questions.length;
  console.log(`${k} (${lv.name}): 총 ${lv.questions.length} = O/X ${ox} + 객관식 ${mc}`);
}
console.log("합계", total);

writeFileSync(new URL("../data/questions.json", import.meta.url), JSON.stringify(QUIZ, null, 2) + "\n");
console.log("→ data/questions.json 저장");
