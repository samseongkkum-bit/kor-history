// 한옥 마당 좌표계. 단일 파일의 맵 배치를 그대로 옮긴 것.
// 서버가 채점할 때도 이 함수들을 그대로 쓴다(클라이언트와 판정이 어긋나지 않게).
import { NUMS } from "./consts.js";

export const W = 960, H = 600;
export const YARD = {x:40, y:96, w:880, h:480};       // 걸을 수 있는 마당
export const START = {x:480, y:540};
export const SCROLL = {x:96, y:530, r:26};            // 힌트 두루마리

export function zonesFor(q){
  if(q.t === "ox") return [
    {key:"O", x:90,  y:170, w:340, h:300, label:"○", sub:"맞아요"},
    {key:"X", x:530, y:170, w:340, h:300, label:"×", sub:"아니에요"}
  ];
  const pos = [[90,150],[530,150],[90,320],[530,320]];
  return q.c.map((c,k)=>({key:k, x:pos[k][0], y:pos[k][1], w:340, h:140, label:NUMS[k], sub:c}));
}

export const inZone = (p,z) => p.x>=z.x && p.x<=z.x+z.w && p.y>=z.y && p.y<=z.y+z.h;

export const clampYard = p => ({
  x: Math.max(YARD.x+20, Math.min(YARD.x+YARD.w-20, p.x)),
  y: Math.max(YARD.y+40, Math.min(YARD.y+YARD.h-30, p.y))
});

export const zoneAt = (p, zones) => zones.find(z => inZone(p, z));
