// 실제로 배포된 주소에서 한 판을 끝까지 돌려 본다.
// 실행: BASE=https://kor-history.vercel.app npx playwright test tests/e2e/live.spec.js
import { test, expect } from "@playwright/test";
import { createRoom, joinAs, answer, findQuestion } from "./helpers.js";

const BASE = process.env.BASE || "https://kor-history.vercel.app";

test("배포된 주소에서 진행자 1명 + 학생 3명이 한 판을 끝낸다", async ({ browser }) => {
  test.setTimeout(500_000);
  const ctxHost = await browser.newContext({ viewport: { width: 1440, height: 900 }, baseURL: BASE });
  const host = await ctxHost.newPage();
  host.on("pageerror", e => console.log("[진행자 오류]", e.message));
  const code = await createRoom(host);
  console.log(`  배포 주소: ${BASE} · 방 ${code}`);

  const students = [];
  for (const name of ["가","나","다"]){
    const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, baseURL: BASE });
    const page = await ctx.newPage();
    page.on("pageerror", e => console.log(`[${name} 오류]`, e.message));
    await joinAs(page, code, name);
    students.push({ name, page, ctx });
  }
  const [A, B, C] = students;
  await expect(host.locator("#pcount")).toHaveText("3");

  await host.locator('[data-level="elem"]').click();
  await host.getByRole("button", { name: "게임 시작" }).click();

  for (let i = 1; i <= 10; i++){
    await expect(host.locator("#qtext")).not.toBeEmpty({ timeout: 40_000 });
    await expect(host.locator("#qnum")).toHaveText(`${i} / 10`, { timeout: 40_000 });
    const q = findQuestion(await host.locator("#qtext").textContent());
    expect(q, "문제를 questions.json 에서 찾았다").toBeTruthy();
    const right = q.a, wrong = right === "O" ? "X" : "O";

    await answer(A.page, "ox", right,                  { qnum: i });
    await answer(B.page, "ox", wrong,                  { qnum: i });
    await answer(C.page, "ox", i <= 5 ? right : wrong, { qnum: i });

    if (i === 3){                                   // 중간에 새로고침해도 이어지는지
      await C.page.reload();
      await expect(C.page.locator("#chip")).toContainText("다", { timeout: 25_000 });
      await expect(C.page.locator("#decide")).toHaveText("여기로 정했어요!");
    }
    if (i === 2){                                   // 힌트는 나만
      await A.page.locator("#hintBtn").click();
      await expect(A.page.locator("#hintbox")).toContainText(q.hint);
      await expect(B.page.locator("#hintbox")).toBeHidden();
    }

    await expect(host.locator("#revealcard")).toBeVisible({ timeout: 40_000 });
    await expect(host.locator("#rexplain")).toHaveText(q.ex);
    await expect(A.page.locator("#myscore")).toHaveText(`지금까지 ${i * 10}점이에요`, { timeout: 25_000 });
    if (i === 1) await host.screenshot({ path: "screenshots/live-host-reveal.png" });
    await host.locator("#nextBtn").click();
  }

  await expect(host.locator("#s-final")).toBeVisible({ timeout: 40_000 });
  const rows = host.locator("#finalList li");
  await expect(rows).toHaveCount(3);
  for (const [i, name, title, score] of [[0,"가","왕","100점"],[1,"다","평민","50점"],[2,"나","천민","0점"]]){
    await expect(rows.nth(i).locator(".nm")).toHaveText(name);
    await expect(rows.nth(i).locator(".ti")).toHaveText(title);
    await expect(rows.nth(i).locator(".sc")).toHaveText(score);
  }
  for (const [s, score, title] of [[A,100,"왕"],[C,50,"평민"],[B,0,"천민"]]){
    await expect(s.page.locator("#finalScore")).toContainText(String(score), { timeout: 25_000 });
    await expect(s.page.locator("#finalTitle")).toHaveText(title);
  }
  await host.screenshot({ path: "screenshots/live-host-final.png" });
  await A.page.screenshot({ path: "screenshots/live-play-final.png", fullPage: true });
  console.log("  최종 순위·칭호 확인 완료");

  for (const s of students) await s.ctx.close();
  await ctxHost.close();
});
