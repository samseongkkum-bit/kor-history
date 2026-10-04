// data/questions.json 을 읽어 들인다. 선생님이 파일을 고치면 서버를 다시 켜면 반영된다.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
export const QUIZ = JSON.parse(readFileSync(join(root, "data", "questions.json"), "utf8"));
export const LEVELS = Object.keys(QUIZ);

export function levelInfo(level){
  const L = QUIZ[level];
  return { key: level, name: L.name, kind: L.kind, desc: L.desc, total: L.questions.length };
}
