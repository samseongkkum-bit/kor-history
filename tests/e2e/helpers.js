import { expect } from "@playwright/test";
import { readFileSync } from "node:fs";

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

export async function joinAs(page, code, name, color = "red"){
  await page.goto(`/play?code=${code}`);
  await page.locator("#pname").fill(name);
  if (color !== "red") await page.locator(`[data-color="${color}"]`).click();
  await page.getByRole("button", { name: /마당에 .*들어가기/ }).click();
  await expect(page.locator("#s-wait")).toBeVisible();
  return name;
}

// 이 문제에서 학생이 설 자리로 걸어가 "여기로 결정!"을 누른다.
export async function answer(page, type, key, { lock = true } = {}){
  const c = zoneCenter(type, key);
  await walkTo(page, c.x, c.y);
  if (!lock) return;
  const decide = page.locator("#decide");
  await expect(decide).toBeEnabled({ timeout: 8000 });
  await decide.click();
  await expect(decide).toHaveText("여기로 정했어요!");
}
