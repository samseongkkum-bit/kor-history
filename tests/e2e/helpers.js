import { expect } from "@playwright/test";
import { readFileSync, existsSync } from "node:fs";

export const QUIZ = JSON.parse(readFileSync(new URL("../../data/questions.json", import.meta.url), "utf8"));
export const ALL = Object.values(QUIZ).flatMap(l => l.questions);

// 문제 문구로 원본 문제를 찾아 정답을 알아낸다(테스트가 정답을 알아야 점수를 확인할 수 있다).
export const findQuestion = text => ALL.find(q => q.q === text.trim());

// 마당 좌표(960x600)를 실제 화면 좌표로 바꿔 눌러, 캐릭터를 그 자리로 걸어가게 한다.
export async function walkTo(page, x, y){
  await page.locator("#yard").scrollIntoViewIfNeeded();
  const box = await page.locator("#yard").boundingBox();
  await page.mouse.click(box.x + x / 960 * box.width, box.y + y / 600 * box.height);
}

// O/X와 객관식 구역의 가운데 좌표 (public/shared/map.js 의 zonesFor 와 같은 배치)
export function zoneCenter(type, key){
  if (type === "ox") return key === "O" ? { x: 260, y: 320 } : { x: 700, y: 320 };
  const pos = [[90,150],[530,150],[90,320],[530,320]][key];
  return { x: pos[0] + 170, y: pos[1] + 70 };
}

export async function createRoom(page){
  await page.goto("/host");
  await page.getByRole("button", { name: "방 만들기" }).click();
  await expect(page.locator("#code")).toHaveText(/^\d{4}$/);
  return (await page.locator("#code").textContent()).trim();
}

export async function joinAs(page, code, name){
  await page.goto(`/play?code=${code}`);
  await page.locator("#pname").fill(name);
  await page.getByRole("button", { name: /마당에 .*들어가기/ }).click();
  await expect(page.locator("#s-wait")).toBeVisible();
  return name;
}

// 학생 화면이 그 문제를 그릴 때까지 기다린다(진행자 화면보다 조금 늦게 온다).
export async function waitForQuestion(page, n, total = 10){
  await expect(page.locator("#s-quiz")).toBeVisible({ timeout: 30000 });
  await expect(page.locator("#qnum")).toHaveText(`${n} / ${total}`, { timeout: 30000 });
  await expect(page.locator("#fb")).toBeHidden({ timeout: 30000 });
  await expect(page.locator("#decide")).toHaveText("여기로 결정!", { timeout: 30000 });
}

// 이 문제에서 학생이 설 자리로 걸어가 "여기로 결정!"을 누른다.
export async function answer(page, type, key, { lock = true, qnum = null } = {}){
  if (qnum !== null) await waitForQuestion(page, qnum);
  const c = zoneCenter(type, key);
  await walkTo(page, c.x, c.y);
  if (!lock) return;
  const decide = page.locator("#decide");
  await expect(decide).toBeEnabled({ timeout: 8000 });
  await decide.click();
  await expect(decide).toHaveText("여기로 정했어요!");
}


/* ---------------- Supabase 를 직접 부르기 ----------------
   화면을 거치지 않고 방 상태를 만들 때 쓴다(예: 객관식 문제를 바로 띄우기). */
const env = (() => {
  const e = { ...process.env };
  const f = new URL("../../.env.local", import.meta.url);
  if (existsSync(f)) for (const line of readFileSync(f, "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && !e[m[1]]) e[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
  return e;
})();
const SB_URL = (env.SUPABASE_URL || "").trim().replace(/\/rest\/v1\/?$/, "").replace(/\/$/, "");
const SB_KEY = (env.SUPABASE_ANON_KEY || "").trim();

export async function rpc(fn, body = {}){
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(body)
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`${fn}: ${r.status} ${t.slice(0, 200)}`);
  return t ? JSON.parse(t) : null;
}

// 한 판을 다시 뽑는 것은 바로 끝나므로, 객관식이 1번 문제로 나올 때까지 다시 뽑는다.
export async function restartUntilChoice(code, hostToken, tries = 25){
  for (let i = 0; i < tries; i++){
    const s = await rpc("host_start", { p_code: code, p_token: hostToken });
    if (s?.question?.type === "mc") return s;
  }
  throw new Error("객관식 문제를 1번으로 뽑지 못했어요");
}
