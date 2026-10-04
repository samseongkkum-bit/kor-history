// data/questions.json 을 읽어 들인다. 선생님이 파일을 고치면 서버를 다시 켜면 반영된다.
// 파일이 잘못되어 있으면 무엇이 잘못됐는지 한국어로 알려 주고 멈춘다.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const path = join(root, "data", "questions.json");

function die(msg, hint){
  console.error(`\n문제 파일(data/questions.json)에 잘못된 곳이 있어요.\n  → ${msg}`);
  if (hint) console.error(`  ${hint}`);
  console.error("\n고친 뒤 다시 `npm start` 로 켜 주세요. 자세한 설명은 README의 '7. 문제 고치기'를 보세요.\n");
  process.exit(1);
}

let raw;
try {
  raw = readFileSync(path, "utf8");
} catch {
  die("파일을 찾을 수 없어요.", "data 폴더 안에 questions.json 이 있어야 해요.");
}

let parsed;
try {
  parsed = JSON.parse(raw);
} catch (e) {
  // JSON.parse 는 몇 번째 글자가 잘못됐는지 알려 준다 → 몇째 줄인지로 바꿔 준다
  const at = Number(String(e.message).match(/position (\d+)/)?.[1]);
  const line = Number.isFinite(at) ? raw.slice(0, at).split("\n").length : null;
  die(line ? `${line}번째 줄 근처를 읽을 수 없어요.` : "파일을 읽을 수 없어요.",
      "쉼표(,)나 큰따옴표(\")를 빠뜨리지 않았는지 보세요.");
}

// 선생님이 흔히 하는 실수를 미리 잡아 준다
for (const [key, lv] of Object.entries(parsed)){
  if (!lv || !Array.isArray(lv.questions)) die(`'${key}' 단계에 questions 목록이 없어요.`);
  if (!lv.name) die(`'${key}' 단계에 name(단계 이름)이 없어요.`);
  lv.questions.forEach((q, i) => {
    const where = `'${lv.name}' ${i + 1}번 문제`;
    if (!q.q) die(`${where}에 q(문제 문장)가 없어요.`);
    if (q.t !== "ox" && q.t !== "mc") die(`${where}의 t는 "ox" 또는 "mc" 여야 해요. (지금: ${JSON.stringify(q.t)})`);
    if (!q.hint) die(`${where}에 hint(힌트)가 없어요.`);
    if (!q.ex) die(`${where}에 ex(해설)가 없어요.`);
    if (q.t === "ox"){
      if (q.a !== "O" && q.a !== "X") die(`${where}의 정답 a는 "O" 또는 "X" 여야 해요. (지금: ${JSON.stringify(q.a)})`);
    } else {
      if (!Array.isArray(q.c) || q.c.length !== 4) die(`${where}의 보기 c는 4개여야 해요. (지금: ${Array.isArray(q.c) ? q.c.length + "개" : "없음"})`);
      if (!Number.isInteger(q.a) || q.a < 0 || q.a > 3) die(`${where}의 정답 a는 0~3 사이 숫자여야 해요. (0=첫 번째 보기, 지금: ${JSON.stringify(q.a)})`);
    }
  });
  if (lv.questions.length < 10) die(`'${lv.name}' 단계의 문제가 ${lv.questions.length}개뿐이에요.`, "한 판에 10문제를 뽑으므로 10개 이상 있어야 해요.");
}

export const QUIZ = parsed;
export const LEVELS = Object.keys(QUIZ);

export function levelInfo(level){
  const L = QUIZ[level];
  return { key: level, name: L.name, kind: L.kind, desc: L.desc, total: L.questions.length };
}
