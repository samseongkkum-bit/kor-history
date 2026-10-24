// 강제 종료하면 새 방이 생기고, 이전 방 학생을 다시 불러 새 방으로 옮겨 갈 수 있다.
import { test, expect } from "@playwright/test";
import { createRoom, joinAs } from "./helpers.js";

test("강제 종료 → 새 방 → 이전 학생 다시 부르기", async ({ browser }) => {
  test.setTimeout(180_000);
  const host = await (await browser.newContext({ viewport: { width: 1440, height: 900 } })).newPage();
  host.on("dialog", d => d.accept());
  const oldCode = await createRoom(host);

  const students = [];
  for (const name of ["가", "나"]){
    const page = await (await browser.newContext({ viewport: { width: 390, height: 844 } })).newPage();
    await joinAs(page, oldCode, name);
    students.push({ name, page });
  }
  await expect(host.locator("#pcount")).toHaveText("2");
  await host.locator('[data-level="elem"]').click();
  await host.getByRole("button", { name: "게임 시작" }).click();
  await expect(host.locator("#qcard")).toBeVisible();

  // 강제 종료: 옛 방 최종 순위 + 새 방 안내
  await host.locator("#endBtn").click();
  await expect(host.locator("#s-final")).toBeVisible();
  await expect(host.locator("#nextNote")).toBeVisible();
  const newCode = (await host.locator("#nextNote b").textContent()).trim();
  expect(newCode).toMatch(/^\d{4}$/);
  expect(newCode).not.toBe(oldCode);
  for (const s of students) await expect(s.page.locator("#s-final")).toBeVisible({ timeout: 20_000 });

  // 새 방 대기실로(아직 아무도 안 부름) → 이전 방 학생 명단이 보인다
  await host.getByRole("button", { name: "새 방 대기실로" }).click();
  await expect(host.locator("#code")).toHaveText(newCode);
  await expect(host.locator("#prevcard")).toBeVisible();
  await expect(host.locator("#prevPlayers li")).toHaveCount(2);

  // "가"만 부른다
  await host.locator("#prevPlayers li", { hasText: "가" }).getByRole("button", { name: "부르기" }).click();
  const [A, B] = students;
  await expect(A.page.locator("#inviteBox")).toBeVisible({ timeout: 20_000 });
  await expect(A.page.locator("#inviteCode")).toHaveText(newCode);
  await expect(B.page.locator("#inviteBox")).toBeHidden();

  await A.page.getByRole("button", { name: "새 방으로 들어가기" }).click();
  await expect(A.page.locator("#s-wait")).toBeVisible({ timeout: 20_000 });
  await expect(A.page.locator("#chip")).toContainText(newCode);
  await expect(host.locator("#players")).toContainText("가");
  await expect(host.locator("#prevPlayers li", { hasText: "가" })).toContainText("들어왔어요");

  // 나머지 모두 부르기
  await host.getByRole("button", { name: "모두 다시 부르기" }).click();
  await expect(B.page.locator("#inviteBox")).toBeVisible({ timeout: 20_000 });
  await B.page.getByRole("button", { name: "새 방으로 들어가기" }).click();
  await expect(B.page.locator("#s-wait")).toBeVisible({ timeout: 20_000 });
  await expect(host.locator("#pcount")).toHaveText("2");
});
