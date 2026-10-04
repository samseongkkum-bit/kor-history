// 채점 로직: 서 있는 자리로 정답을 판정하는지, 칭호가 맞는지, 빠르기 보너스가 순위에만 쓰이는지.
import test from "node:test";
import assert from "node:assert/strict";
import { gradeOne, answerLabel, rank, rankOf } from "../server/scoring.js";
import { zonesFor, START, clampYard, YARD } from "../public/shared/map.js";
import { NUMS, RANKS } from "../public/shared/consts.js";

const oxQ = { t:"ox", q:"문제", a:"O", hint:"힌트", ex:"해설" };
const mcQ = { t:"mc", q:"문제", c:["가","나","다","라"], a:2, hint:"힌트", ex:"해설" };
const center = (zones, key) => { const z = zones.find(z => String(z.key) === String(key)); return { x: z.x + z.w/2, y: z.y + z.h/2 }; };
// decided: "여기로 결정!"을 누른 시각(초). 안 눌렀으면 null → 서버는 마감 시각으로 채점한다.
const at = (q, key, { decided = null, seconds = 12 } = {}) => {
  const startAt = 1_000_000, endAt = startAt + seconds*1000;
  return gradeOne({ q, zones: zonesFor(q), pos: key === null ? START : center(zonesFor(q), key),
    decidedAt: decided === null ? endAt : startAt + decided*1000, startAt, endAt });
};

test("정답 자리에 서 있으면 정답", () => {
  const r = at(oxQ, "O");
  assert.equal(r.picked, "O");
  assert.equal(r.correct, true);
});

test("틀린 자리에 서 있으면 오답", () => {
  const r = at(oxQ, "X");
  assert.equal(r.picked, "X");
  assert.equal(r.correct, false);
  assert.equal(r.bonus, 0, "오답에는 빠르기 보너스가 없다");
});

test("아무 자리에도 서 있지 않으면 시간 종료 오답", () => {
  const r = at(oxQ, null);                 // 출발 지점은 어느 돗자리에도 안 들어간다
  assert.equal(r.picked, null);
  assert.equal(r.correct, false);
});

test("객관식도 선 자리로 채점한다", () => {
  assert.equal(at(mcQ, 2).correct, true);
  for (const k of [0,1,3]) assert.equal(at(mcQ, k).correct, false, `${k}번 자리는 오답`);
});

test("빠르기 보너스: 일찍 정한 사람이 더 크다", () => {
  const fast = at(oxQ, "O", { decided: 2 });     // 12초 중 2초에 결정
  const slow = at(oxQ, "O", { decided: 10 });
  assert.ok(fast.bonus > slow.bonus, `${fast.bonus} > ${slow.bonus}`);
  assert.ok(fast.bonus <= 1 && fast.bonus >= 0, "보너스는 0~1 사이");
  assert.equal(Math.round(fast.bonus * 100) / 100, 0.83);
  // 끝까지 안 정하면 보너스 0
  assert.equal(at(oxQ, "O").bonus, 0);
});

test("점수는 정답 1점뿐이고, 보너스는 순위표에만 쓴다", () => {
  const players = [
    { id:"a", name:"가", color:"red",    score:7, bonus:1.2 },
    { id:"b", name:"나", color:"cheong", score:7, bonus:5.5 },
    { id:"c", name:"다", color:"hwang",  score:9, bonus:0.1 }
  ];
  const r = rank(players);
  assert.deepEqual(r.map(p => p.name), ["다","나","가"], "점수 먼저, 동점이면 빠르기 보너스");
  assert.deepEqual(r.map(p => p.score), [9,7,7], "보너스가 점수를 바꾸지 않는다");
  assert.deepEqual(r.map(p => p.place), [1,2,3]);
});

test("동점·동보너스면 이름 순", () => {
  const r = rank([
    { id:"b", name:"나", color:"red", score:5, bonus:1 },
    { id:"a", name:"가", color:"red", score:5, bonus:1 }
  ]);
  assert.deepEqual(r.map(p => p.name), ["가","나"]);
});

test("칭호(10점 만점)", () => {
  const want = ["천민","천민","천민","양민","양민","평민","평민","귀족","귀족","조선의 학자","왕"];
  for (let n = 0; n <= 10; n++) assert.equal(rankOf(n).title, want[n], `${n}점 → ${want[n]}`);
  assert.deepEqual(RANKS.map(r => r.title), ["천민","양민","평민","귀족","조선의 학자","왕"]);
});

test("정답 보기를 사람이 읽는 말로 바꾼다", () => {
  assert.equal(answerLabel({ t:"ox", a:"O" }, NUMS), "○ (맞아요)");
  assert.equal(answerLabel({ t:"ox", a:"X" }, NUMS), "× (아니에요)");
  assert.equal(answerLabel(mcQ, NUMS), "③ 다");
});

test("마당 밖으로는 나갈 수 없다", () => {
  for (const p of [{x:-9999,y:-9999},{x:9999,y:9999},{x:480,y:0}]){
    const c = clampYard(p);
    assert.ok(c.x >= YARD.x && c.x <= YARD.x + YARD.w, `x 범위 안: ${c.x}`);
    assert.ok(c.y >= YARD.y && c.y <= YARD.y + YARD.h, `y 범위 안: ${c.y}`);
  }
});

test("O/X와 객관식 구역이 겹치지 않는다", () => {
  for (const q of [oxQ, mcQ]){
    const zones = zonesFor(q);
    for (let i = 0; i < zones.length; i++) for (let j = i+1; j < zones.length; j++){
      const a = zones[i], b = zones[j];
      const overlap = a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
      assert.equal(overlap, false, `${a.key}와 ${b.key} 구역이 겹친다`);
    }
  }
});
