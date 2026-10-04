// 출제 로직. 단일 파일의 buildRound를 그대로 옮기고, 사용한 문제 목록만 방마다 따로 들고 있게 했다.
// 30문제를 한 바퀴 다 돌 때까지 같은 문제가 다시 나오지 않는다. 객관식은 보기 순서도 섞는다.
import { ROUND, shuffle } from "../public/shared/consts.js";

export const newUsed = () => ({ elem: [], mid: [] });

export function buildRound(QUIZ, level, used){
  const all = QUIZ[level].questions.map((_,k)=>k);
  const fresh = shuffle(all.filter(k => !used[level].includes(k)));
  let ids;
  if(fresh.length >= ROUND){ ids = fresh.slice(0, ROUND); used[level] = used[level].concat(ids); }
  else { const fill = shuffle(all.filter(k => !fresh.includes(k))).slice(0, ROUND - fresh.length); ids = shuffle(fresh.concat(fill)); used[level] = fill.slice(); }
  return ids.map(k => {
    const q = QUIZ[level].questions[k];
    if(q.t !== "mc") return {...q, src:k};
    const order = shuffle([0,1,2,3]);
    return {...q, src:k, c: order.map(o => q.c[o]), a: order.indexOf(q.a)};
  });
}
