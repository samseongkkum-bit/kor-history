// 폰(390px)과 태블릿에서 학생 화면의 글자가 잘리거나 버튼이 겹치지 않는지 확인하고 스크린샷을 남긴다.
import { test, expect } from "@playwright/test";
import { createRoom, joinAs, answer, findQuestion } from "./helpers.js";

const SIZES = [
  { tag: "phone-390",  width: 390,  height: 844 },
  { tag: "tablet-820", width: 820,  height: 1180 },
  { tag: "tablet-1024-yoko", width: 1024, height: 768 }
];

// 요소가 뷰포트 너비를 넘지 않고, 글자가 잘리지 않는지 본다.
async function checkNoOverflow(page, tag){
  const bad = await page.evaluate(() => {
    const out = [];
    const vw = document.documentElement.clientWidth;
    for (const el of document.querySelectorAll("button, input, h1, h2, p, span, li, .code, .score, .title")){
      if (!el.offsetParent && el.tagName !== "BODY") continue;
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) continue;
      if (r.right > vw + 1 || r.left < -1) out.push({ why: "화면 밖으로 넘침", sel: el.id || el.className || el.tagName, left: Math.round(r.left), right: Math.round(r.right), vw });
      // 글자가 담긴 칸보다 커서 잘리는 경우 (말줄임표를 쓰는 칸은 뺀다)
      const st = getComputedStyle(el);
      if (st.overflow === "hidden" && st.textOverflow !== "ellipsis" && el.scrollWidth > el.clientWidth + 2)
        out.push({ why: "글자 잘림", sel: el.id || el.className || el.tagName, scrollW: el.scrollWidth, clientW: el.clientWidth });
    }
    return out;
  });
  // 가로 스크롤이 생기지 않아야 한다
  const scrollX = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(scrollX, `${tag}: 가로 스크롤이 생기면 안 돼요`).toBeLessThanOrEqual(1);
  expect(bad, `${tag}: ${JSON.stringify(bad, null, 1)}`).toEqual([]);
}

// 버튼끼리 겹치지 않는지, 48px 이상인지
async function checkButtons(page, tag){
  const boxes = await page.evaluate(() => [...document.querySelectorAll("button")]
    .filter(b => b.offsetParent && b.getBoundingClientRect().height > 0)
    .map(b => { const r = b.getBoundingClientRect(); return { id: b.id || b.className, x: r.x, y: r.y, w: r.width, h: r.height }; }));
  for (const b of boxes){
    // 색 고르기 동그라미(48px)와 방향 버튼(56px)을 포함해 모두 48px 이상
    expect(Math.round(b.h), `${tag}: ${b.id} 버튼 높이가 48px 이상이어야 해요`).toBeGreaterThanOrEqual(48);
  }
  for (let i = 0; i < boxes.length; i++) for (let j = i+1; j < boxes.length; j++){
    const a = boxes[i], b = boxes[j];
    const overlap = a.x < b.x + b.w - 1 && b.x < a.x + a.w - 1 && a.y < b.y + b.h - 1 && b.y < a.y + a.h - 1;
    expect(overlap, `${tag}: ${a.id} 와 ${b.id} 버튼이 겹쳐요`).toBe(false);
  }
}

// 본문 글자가 18px 이상
async function checkFontSize(page, tag){
  const small = await page.evaluate(() => {
    const out = [];
    for (const el of document.querySelectorAll("p, li, button, input, .where, .explain, .question")){
      if (!el.offsetParent) continue;
      if (el.closest(".cap") || el.classList.contains("cap")) continue;   // 보조 설명은 15px 허용
      if (!el.textContent.trim()) continue;                               // 글자가 없는 칸(색 동그라미 등)은 뺀다
      const fs = parseFloat(getComputedStyle(el).fontSize);
      if (fs < 18) out.push({ sel: el.id || el.className || el.tagName, fs });
    }
    return out;
  });
  expect(small, `${tag}: 본문 글자는 18px 이상 (${JSON.stringify(small)})`).toEqual([]);
}

test("학생 화면이 폰과 태블릿에서 깨지지 않는다", async ({ browser }) => {
  test.setTimeout(300_000);
  const host = await (await browser.newContext()).newPage();
  host.on("dialog", d => d.accept());        // "강제 종료" 확인 창
  const code = await createRoom(host);
  await host.locator('[data-level="elem"]').click();

  for (const size of SIZES){
    const ctx = await browser.newContext({ viewport: { width: size.width, height: size.height } });
    const page = await ctx.newPage();

    // ① 입장 화면
    await page.goto(`/play?code=${code}`);
    await expect(page.locator("#s-join")).toBeVisible();
    await page.screenshot({ path: `screenshots/play-1-join-${size.tag}.png`, fullPage: true });
    await checkNoOverflow(page, `${size.tag} 입장`);
    await checkButtons(page, `${size.tag} 입장`);
    await checkFontSize(page, `${size.tag} 입장`);

    // ② 대기 화면
    await joinAs(page, code, `학생${size.width}`);
    await page.screenshot({ path: `screenshots/play-2-wait-${size.tag}.png`, fullPage: true });
    await checkNoOverflow(page, `${size.tag} 대기`);

    size.ctx = ctx; size.page = page;    // 아래 단계에서 계속 쓰려고 열어 둔다
  }

  // ③ 문제 화면 (세 기기가 같이 들어온 상태에서 시작)
  await host.getByRole("button", { name: "게임 시작" }).click();
  for (const size of SIZES){
    const page = size.page;
    await expect(page.locator("#qtext")).not.toBeEmpty({ timeout: 30_000 });
    await page.locator("#hintBtn").click();                    // 힌트까지 펼친 가장 빽빽한 상태
    await expect(page.locator("#hintbox")).toBeVisible();
    await page.screenshot({ path: `screenshots/play-3-quiz-${size.tag}.png`, fullPage: true });
    await checkNoOverflow(page, `${size.tag} 문제`);
    await checkButtons(page, `${size.tag} 문제`);
    await checkFontSize(page, `${size.tag} 문제`);
  }

  // ④ 채점 화면
  const text = await host.locator("#qtext").textContent();
  const q = findQuestion(text);
  for (const size of SIZES) await answer(size.page, "ox", q.a, { qnum: 1 });
  await expect(host.locator("#revealcard")).toBeVisible({ timeout: 30_000 });
  for (const size of SIZES){
    const page = size.page;
    await expect(page.locator("#fb")).toBeVisible({ timeout: 20_000 });
    await page.screenshot({ path: `screenshots/play-4-result-${size.tag}.png`, fullPage: true });
    await checkNoOverflow(page, `${size.tag} 채점`);
    await checkFontSize(page, `${size.tag} 채점`);
  }

  // ⑤ 최종 결과
  await host.locator("#endBtn").click();     // 강제 종료 → 최종 결과
  for (const size of SIZES){
    const page = size.page;
    await expect(page.locator("#s-final")).toBeVisible({ timeout: 20_000 });
    await page.screenshot({ path: `screenshots/play-5-final-${size.tag}.png`, fullPage: true });
    await checkNoOverflow(page, `${size.tag} 결과`);
    await checkButtons(page, `${size.tag} 결과`);
    await checkFontSize(page, `${size.tag} 결과`);
    await size.ctx.close();
  }
});

test("중등부 객관식도 폰에서 보기가 읽힌다", async ({ browser }) => {
  test.setTimeout(120_000);
  const host = await (await browser.newContext()).newPage();
  host.on("dialog", d => d.accept());
  const code = await createRoom(host);
  await host.locator('[data-level="mid"]').click();

  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await ctx.newPage();
  await joinAs(page, code, "중등이");
  await host.getByRole("button", { name: "게임 시작" }).click();

  // 객관식 문제가 나올 때까지 넘긴다
  for (let i = 0; i < 10; i++){
    await expect(page.locator("#qtext")).not.toBeEmpty({ timeout: 30_000 });
    if (await page.locator("#qkind").textContent() === "객관식") break;
    await expect(host.locator("#nextBtn")).toBeVisible({ timeout: 30_000 });
    await host.locator("#nextBtn").click();
    await page.waitForTimeout(300);
  }
  await expect(page.locator("#qkind")).toHaveText("객관식");
  const items = page.locator("#choices li");
  await expect(items).toHaveCount(4);                 // 보기 4개가 문제 밑에도 적혀 있다
  await page.screenshot({ path: "screenshots/play-3-quiz-mc-phone-390.png", fullPage: true });
  await checkNoOverflow(page, "phone-390 객관식");
  await checkFontSize(page, "phone-390 객관식");

  await answer(page, "mc", 0, { lock: false });        // 첫 번째 자리로 걸어가 본다
  await expect(page.locator("#decide")).toBeEnabled({ timeout: 10_000 });
  await ctx.close();
  await host.context().close();
});

test("진행자 화면도 노트북과 큰 모니터에서 깨지지 않는다", async ({ browser }) => {
  test.setTimeout(120_000);
  for (const [tag, width, height] of [["laptop-1440",1440,900],["monitor-1920",1920,1080],["small-1100",1100,800]]){
    const ctx = await browser.newContext({ viewport: { width, height } });
    const page = await ctx.newPage();
    const code = await createRoom(page);
    await expect(page.locator("#qr svg")).toBeVisible();
    await expect(page.locator("#code")).toHaveText(code);
    await page.screenshot({ path: `screenshots/host-lobby-${tag}.png` });
    const over = await page.evaluate(() => ({
      x: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      y: document.documentElement.scrollHeight - document.documentElement.clientHeight
    }));
    expect(over.x, `${tag}: 가로 스크롤이 생기면 안 돼요`).toBeLessThanOrEqual(1);
    // 2단으로 보이는 큰 화면에서는 한 화면 안에 다 들어와야 한다(좁은 화면은 1단이라 스크롤이 정상)
    if (width > 1100) expect(over.y, `${tag}: 진행자 화면이 한 화면에 들어와야 해요`).toBeLessThanOrEqual(1);
    await ctx.close();
  }
});
