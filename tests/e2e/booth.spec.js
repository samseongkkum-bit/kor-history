// 부스 한 판을 끝까지 자동으로 진행한다: 진행자 1명 + 학생 3명, 10문제, 점수와 칭호 확인.
// 학생 한 명은 중간에 새로고침해서 재접속이 되는지도 확인한다.
import { test, expect } from "@playwright/test";
import { createRoom, joinAs, answer, findQuestion } from "./helpers.js";

test("진행자 1명과 학생 3명이 10문제를 끝까지 진행한다", async ({ browser }) => {
  test.setTimeout(400_000);          // O/X 12초 × 10문제 + 채점·해설 시간

  const ctxHost = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const host = await ctxHost.newPage();
  host.on("dialog", d => d.accept());
  const code = await createRoom(host);

  // 학생 3명: 가(늘 정답), 나(늘 오답), 다(앞 5문제만 정답 + 중간에 새로고침)
  const students = [];
  for (const [name, color] of [["가","red"],["나","cheong"],["다","hwang"]]){
    const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
    const page = await ctx.newPage();
    await joinAs(page, code, name, color);
    students.push({ name, page, ctx });
  }
  const [A, B, C] = students;

  // 대기실에 3명이 보인다
  await expect(host.locator("#pcount")).toHaveText("3");
  for (const s of students) await expect(host.locator("#players")).toContainText(s.name);

  // 초등부로 시작
  await host.locator('[data-level="elem"]').click();
  await expect(host.locator('[data-level="elem"]')).toHaveAttribute("aria-pressed", "true");
  await host.getByRole("button", { name: "게임 시작" }).click();

  for (let i = 1; i <= 10; i++){
    await expect(host.locator("#qcard")).toBeVisible({ timeout: 30_000 });
    await expect(host.locator("#qtext")).not.toBeEmpty({ timeout: 30_000 });
    await expect(host.locator("#qnum")).toHaveText(`${i} / 10`, { timeout: 30_000 });
    const text = await host.locator("#qtext").textContent();
    const q = findQuestion(text);
    expect(q, `문제를 questions.json 에서 찾았다: ${text}`).toBeTruthy();
    expect(q.t).toBe("ox");                      // 초등부는 전부 O/X
    const right = q.a, wrong = right === "O" ? "X" : "O";

    // 학생들이 각자 자리로 걸어가 결정한다
    await answer(A.page, "ox", right);
    await answer(B.page, "ox", wrong);
    await answer(C.page, "ox", i <= 5 ? right : wrong);

    // 4번 문제에서 '다'는 자리를 정한 뒤 새로고침한다(재접속 확인)
    if (i === 4){
      await C.page.reload();
      await expect(C.page.locator("#chip")).toContainText("다", { timeout: 15_000 });
      await expect(C.page.locator("#decide")).toHaveText("여기로 정했어요!");   // 정했던 자리를 기억한다
      await expect(C.page.locator("#decide")).toBeDisabled();
    }

    // 힌트는 나만 본다: '가'가 힌트를 열어도 '나'의 화면에는 힌트가 없다
    if (i === 2){
      await A.page.locator("#hintBtn").click();
      await expect(A.page.locator("#hintbox")).toContainText(q.hint);
      await expect(B.page.locator("#hintbox")).toBeHidden();
      await expect(host.locator("body")).not.toContainText(q.hint);
    }

    // 진행자 화면(관전) 모습을 남겨 둔다
    if (i === 1) await host.screenshot({ path: "screenshots/host-2-question.png" });

    // 서버가 마감 시각에 채점한다 → 정답 공개
    await expect(host.locator("#revealcard")).toBeVisible({ timeout: 30_000 });
    await expect(host.locator("#ranswer")).toContainText(right === "O" ? "○" : "×");
    await expect(host.locator("#rexplain")).toHaveText(q.ex);
    await expect(host.locator("#top5")).toContainText("가");

    // 학생 화면: 내 정답/오답 + 해설 + 내 점수
    await expect(A.page.locator("#vtitle")).toHaveText("정답이에요!");
    await expect(A.page.locator("#vsym")).toHaveText("○");
    await expect(A.page.locator("#myscore")).toHaveText(`지금까지 ${i}점이에요`);
    await expect(B.page.locator("#vtitle")).toHaveText("아쉬워요!");
    await expect(B.page.locator("#vsym")).toHaveText("×");
    await expect(B.page.locator("#explain")).toHaveText(q.ex);
    await expect(C.page.locator("#myscore")).toHaveText(`지금까지 ${Math.min(i,5)}점이에요`);

    if (i === 1) await host.screenshot({ path: "screenshots/host-3-reveal.png" });

    // 다음 문제 (마지막이면 최종 결과)
    await host.locator("#nextBtn").click();
  }

  /* ---- 최종 결과 ---- */
  await expect(host.locator("#s-final")).toBeVisible({ timeout: 30_000 });
  const rows = host.locator("#finalList li");
  await expect(rows).toHaveCount(3);
  for (const [i, name, title, score] of [[0,"가","왕","10점"],[1,"다","평민","5점"],[2,"나","천민","0점"]]){
    await expect(rows.nth(i).locator(".no")).toHaveText(String(i+1));
    await expect(rows.nth(i).locator(".nm")).toHaveText(name);
    await expect(rows.nth(i).locator(".ti")).toHaveText(title);
    await expect(rows.nth(i).locator(".sc")).toHaveText(score);
  }

  // 학생 화면의 점수와 칭호
  for (const [s, score, title] of [[A,10,"왕"],[C,5,"평민"],[B,0,"천민"]]){
    await expect(s.page.locator("#s-final")).toBeVisible({ timeout: 20_000 });
    await expect(s.page.locator("#finalScore")).toContainText(String(score));
    await expect(s.page.locator("#finalTitle")).toHaveText(title);
    await expect(s.page.locator("#ladder .on")).toHaveText(title);
  }
  await expect(C.page.locator("#finalPlace")).toHaveText("3명 중 2등이에요");

  await host.screenshot({ path: "screenshots/host-4-final.png" });

  // 오늘 참여 인원 합계가 늘어났다
  await expect(host.locator("#today")).toContainText("오늘 참여 인원 합계");
  const today = await host.locator("#today").textContent();
  expect(Number(today.match(/(\d+)명/)[1])).toBeGreaterThanOrEqual(3);

  for (const s of students) await s.ctx.close();
  await ctxHost.close();
});
