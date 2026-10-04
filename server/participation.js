// 부스 성과 보고서용 참여 기록. 이름 같은 개인정보는 남기지 않고 인원 수와 점수만 남긴다.
import { appendFileSync, readFileSync, existsSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const dir = join(root, "data");
const file = join(dir, "participation.jsonl");

const todayStr = (d = new Date()) =>
  `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}-${String(d.getDate()).padStart(2,"0")}`;

// 테스트에서는 실제 기록을 남기지 않는다(npm test 가 HQ_PARTICIPATION=off 로 실행한다).
const OFF = process.env.HQ_PARTICIPATION === "off";

export function append({ level, levelName, players, avgScore, questions }){
  if (OFF) return;
  const now = new Date();
  const line = JSON.stringify({
    date: todayStr(now),
    time: `${String(now.getHours()).padStart(2,"0")}:${String(now.getMinutes()).padStart(2,"0")}`,
    level, levelName, players, questions,
    avgScore: Math.round(avgScore * 10) / 10
  });
  try {
    mkdirSync(dir, { recursive: true });
    appendFileSync(file, line + "\n", "utf8");
  } catch (e) {
    console.warn("참여 기록을 저장하지 못했습니다:", e.message);
  }
}

// 오늘 참여 인원 합계(게임 단위 합계). 파일이 없으면 0.
export function todayTotal(){
  if (OFF || !existsSync(file)) return 0;
  const today = todayStr();
  let sum = 0;
  try {
    for (const line of readFileSync(file, "utf8").split("\n")) {
      if (!line.trim()) continue;
      try { const r = JSON.parse(line); if (r.date === today) sum += r.players || 0; } catch {}
    }
  } catch (e) {
    console.warn("참여 기록을 읽지 못했습니다:", e.message);
  }
  return sum;
}
