// 출제 로직: 30문제를 한 바퀴 다 돌 때까지 같은 문제가 나오지 않는지, 보기를 섞어도 정답이 유지되는지.
import test from "node:test";
import assert from "node:assert/strict";
import { buildRound, newUsed } from "../server/round.js";
import { QUIZ } from "../server/questions.js";
import { ROUND, TIME } from "../public/shared/consts.js";

test("문제 데이터가 그대로 옮겨졌다", () => {
  assert.equal(QUIZ.elem.questions.length, 30);
  assert.equal(QUIZ.mid.questions.length, 30);
  assert.equal(QUIZ.elem.questions.filter(q => q.t === "ox").length, 30, "초등부는 O/X 30문제");
  assert.equal(QUIZ.mid.questions.filter(q => q.t === "mc").length, 15, "중등부 객관식 15문제");
  assert.equal(QUIZ.mid.questions.filter(q => q.t === "ox").length, 15, "중등부 O/X 15문제");
  assert.equal(QUIZ.elem.name, "초등부");
  assert.equal(QUIZ.mid.name, "중등부");
  // 모든 문제에 힌트와 한 줄 해설이 있다
  for (const lv of Object.values(QUIZ)) for (const q of lv.questions){
    assert.ok(q.hint && q.hint.length, "힌트가 있다");
    assert.ok(q.ex && q.ex.length, "해설이 있다");
    if (q.t === "mc") assert.equal(q.c.length, 4);
  }
});

test("한 판은 10문제", () => {
  for (const level of ["elem","mid"]){
    const r = buildRound(QUIZ, level, newUsed());
    assert.equal(r.length, ROUND);
    assert.equal(new Set(r.map(q => q.src)).size, ROUND, "한 판 안에서 중복 없음");
  }
});

test("30문제를 한 바퀴 다 돌 때까지 같은 문제가 다시 나오지 않는다", () => {
  for (const level of ["elem","mid"]){
    const used = newUsed();
    const seen = [];
    for (let i = 0; i < 3; i++) seen.push(...buildRound(QUIZ, level, used).map(q => q.src));
    assert.equal(seen.length, 30);
    assert.equal(new Set(seen).size, 30, `${level}: 3판에 30문제가 모두 한 번씩`);
  }
});

test("한 바퀴를 다 돈 뒤에는 다시 처음부터 돈다", () => {
  const used = newUsed();
  for (let i = 0; i < 3; i++) buildRound(QUIZ, "elem", used);
  const fourth = buildRound(QUIZ, "elem", used);
  assert.equal(fourth.length, ROUND);
  assert.equal(new Set(fourth.map(q => q.src)).size, ROUND);
  // 네 번째 판 뒤에도 계속 10문제씩 나온다
  const fifth = buildRound(QUIZ, "elem", used);
  assert.equal(new Set(fifth.map(q => q.src)).size, ROUND);
});

test("객관식 보기 순서를 섞어도 정답은 그대로다", () => {
  let checked = 0;
  for (let i = 0; i < 40; i++){
    for (const q of buildRound(QUIZ, "mid", newUsed())){
      if (q.t !== "mc") continue;
      const origin = QUIZ.mid.questions[q.src];
      assert.equal(q.c[q.a], origin.c[origin.a], `정답 보기 내용이 같다: ${q.q}`);
      assert.equal(new Set(q.c).size, 4, "보기 4개가 그대로 있다");
      assert.deepEqual([...q.c].sort(), [...origin.c].sort(), "보기 목록이 같다");
      assert.equal(q.q, origin.q, "문제 문구는 바뀌지 않는다");
      checked++;
    }
  }
  assert.ok(checked > 50, `객관식 ${checked}개를 확인했다`);
});

test("O/X 문제는 보기를 섞지 않는다", () => {
  for (const q of buildRound(QUIZ, "elem", newUsed())){
    assert.equal(q.t, "ox");
    assert.ok(q.a === "O" || q.a === "X");
  }
});

test("제한 시간은 O/X 12초, 객관식 20초", () => {
  assert.equal(TIME.ox, 12);
  assert.equal(TIME.mc, 20);
});
