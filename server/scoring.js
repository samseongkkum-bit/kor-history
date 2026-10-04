// 채점과 순위. 정답은 1점(10점 만점, 칭호 기준).
// 빠르기 보너스는 점수에 더하지 않고 순위표의 동점 처리에만 쓴다.
import { TIME, rankOf } from "../public/shared/consts.js";
import { zoneAt } from "../public/shared/map.js";

// 한 학생의 한 문제 채점.
// pos: 마감 순간(또는 "여기로 결정!"을 누른 순간) 서버가 알고 있던 위치
// decidedAt: 결정한 시각(안 눌렀으면 마감 시각)
export function gradeOne({ q, zones, pos, decidedAt, startAt, endAt }){
  const z = pos ? zoneAt(pos, zones) : undefined;
  const picked = z ? z.key : null;                       // null = 아무 자리에도 서 있지 않음
  const correct = picked !== null && picked === q.a;
  const total = (endAt - startAt) || TIME[q.t] * 1000;
  const left = Math.max(0, Math.min(total, endAt - decidedAt));
  return { picked, correct, bonus: correct ? left / total : 0 };
}

// 정답 보기를 사람이 읽을 수 있는 말로.
export function answerLabel(q, NUMS){
  return q.t === "ox" ? (q.a === "O" ? "○ (맞아요)" : "× (아니에요)") : `${NUMS[q.a]} ${q.c[q.a]}`;
}

// 점수 내림차순 → 빠르기 보너스 내림차순 → 이름 순
export function rank(players){
  return players.slice().sort((a,b) =>
    b.score - a.score || b.bonus - a.bonus || a.name.localeCompare(b.name, "ko")
  ).map((p,i) => ({
    place: i+1, id: p.id, name: p.name, color: p.color,
    score: p.score, bonus: Math.round(p.bonus * 100) / 100, title: rankOf(p.score).title
  }));
}

export { rankOf };
