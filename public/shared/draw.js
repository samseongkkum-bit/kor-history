// 캔버스 그리기. 단일 파일의 drawPerson / drawYard / drawZones 코드를 그대로 가져왔다.
// 바뀐 점: 여러 사람을 그릴 수 있게 인자를 조금 정리하고, 이름표와 흐리게 그리기를 더했다.
import { W, H, SCROLL, inZone } from "./map.js";
import { NUMS, colorInfo } from "./consts.js";

export const cv = name => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
// 저고리 색 id → 캔버스에 칠할 색(앞의 세 색은 테마 변수, 나머지는 고정 색)
export const jacket = id => { const c = colorInfo(id); return c.hex || cv(c.css); };

// 마당은 960px 기준으로 그린 뒤 화면 너비에 맞춰 줄어든다. 폰에서는 많이 줄어들어
// 이름표 같은 작은 글자가 안 보이므로, 화면에서의 크기가 비슷해지도록 글자만 키운다.
let textK = 1;
export const setTextScale = k => { textK = Math.max(1, Math.min(2.6, k || 1)); };
const fs = px => Math.round(px * textK);

export function roundRect(ctx,x,y,w,h,r){ctx.beginPath(); ctx.moveTo(x+r,y); ctx.arcTo(x+w,y,x+w,y+h,r); ctx.arcTo(x+w,y+h,x,y+h,r); ctx.arcTo(x,y+h,x,y,r); ctx.arcTo(x,y,x+w,y,r); ctx.closePath();}

export function drawPerson(ctx,x,y,opt){
  const t = opt.t||0, bob = opt.moving ? Math.sin(t*14)*2.5 : 0;
  ctx.save(); ctx.translate(x, y+bob);
  if(opt.scale) ctx.scale(opt.scale, opt.scale);
  ctx.fillStyle = "rgba(0,0,0,.18)"; ctx.beginPath(); ctx.ellipse(0, 22-bob, 18, 6, 0, 0, Math.PI*2); ctx.fill();
  // 치마/바지
  ctx.fillStyle = opt.lower; ctx.beginPath(); ctx.moveTo(-15,4); ctx.lineTo(15,4); ctx.lineTo(19,22); ctx.lineTo(-19,22); ctx.closePath(); ctx.fill();
  // 저고리
  ctx.fillStyle = opt.upper; roundRect(ctx,-14,-10,28,18,6); ctx.fill();
  // 고름
  ctx.strokeStyle = opt.ribbon; ctx.lineWidth = 3; ctx.beginPath(); ctx.moveTo(0,-6); ctx.lineTo(5,8); ctx.moveTo(0,-6); ctx.lineTo(-3,9); ctx.stroke();
  // 얼굴
  ctx.fillStyle = "#f3d6b6"; ctx.beginPath(); ctx.arc(0,-22,14,0,Math.PI*2); ctx.fill();
  // 머리
  ctx.fillStyle = "#2b2420"; ctx.beginPath(); ctx.arc(0,-24,14.5,Math.PI*1.05,Math.PI*1.95); ctx.fill();
  if(opt.hat){ // 갓
    ctx.fillStyle = "#1c1814"; ctx.beginPath(); ctx.ellipse(0,-33,22,5,0,0,Math.PI*2); ctx.fill();
    roundRect(ctx,-8,-48,16,15,4); ctx.fill();
  } else { // 댕기머리
    ctx.fillStyle = opt.ribbon; roundRect(ctx,10,-30,6,12,2); ctx.fill();
  }
  ctx.fillStyle = "#2b2420"; ctx.beginPath(); ctx.arc(-5,-21,1.8,0,Math.PI*2); ctx.arc(5,-21,1.8,0,Math.PI*2); ctx.fill();
  ctx.fillStyle = "rgba(214,110,90,.45)"; ctx.beginPath(); ctx.arc(-8,-16,2.6,0,Math.PI*2); ctx.arc(8,-16,2.6,0,Math.PI*2); ctx.fill();
  ctx.restore();
}

export function drawYard(ctx){
  const C = {ground:cv("--ground"), stone:cv("--stone"), line:cv("--hairline"), meok:cv("--meok"), muted:cv("--meok-muted"), red:cv("--red"), cheong:cv("--cheong"), hwang:cv("--hwang"), deep:cv("--hanji-deep"), hanji:cv("--hanji")};
  ctx.fillStyle = C.ground; ctx.fillRect(0,0,W,H);
  // 담장과 기와 지붕
  ctx.fillStyle = C.deep; ctx.fillRect(0,0,W,84);
  ctx.fillStyle = C.meok; ctx.globalAlpha=.85; ctx.fillRect(0,0,W,34); ctx.globalAlpha=1;
  for(let x=0;x<W;x+=24){ ctx.fillStyle = C.muted; ctx.beginPath(); ctx.arc(x+12,34,10,0,Math.PI); ctx.fill(); }
  const band=[C.red,C.cheong,C.hwang,C.cheong];
  for(let x=0,i=0;x<W;x+=40,i++){ ctx.fillStyle = band[i%4]; ctx.fillRect(x,46,34,8); }
  ctx.strokeStyle = C.line; ctx.lineWidth=2; for(let x=0;x<W;x+=48){ ctx.strokeRect(x+4,58,40,22); }
  // 디딤돌 길
  ctx.fillStyle = C.stone; for(let y=500;y>110;y-=56){ ctx.beginPath(); ctx.ellipse(480,y,26,14,0,0,Math.PI*2); ctx.fill(); }
  // 나무
  [[60,150],[900,150],[900,520]].forEach(([x,y])=>{
    ctx.fillStyle = C.muted; ctx.fillRect(x-4,y,8,22);
    ctx.fillStyle = C.cheong; ctx.globalAlpha=.75; ctx.beginPath(); ctx.arc(x,y-6,24,0,Math.PI*2); ctx.arc(x-14,y+6,16,0,Math.PI*2); ctx.arc(x+14,y+6,16,0,Math.PI*2); ctx.fill(); ctx.globalAlpha=1;
  });
}

export function wrapText(ctx, text, maxW){
  const words = text.split(" "); const lines=[]; let line="";
  for(const w of words){ const test = line ? line+" "+w : w; if(ctx.measureText(test).width > maxW && line){ lines.push(line); line=w; } else line=test; }
  lines.push(line); return lines;
}

// zones: 구역 목록, type: "ox"|"mc", me: 내 위치(없으면 강조 없음),
// answered: 정답이 공개됐는지, answer: 정답 key, picked: 내가 고른 key
export function drawZones(ctx, {zones, type, me, answered, answer, picked, counts}){
  const C = {hanji:cv("--hanji"), line:cv("--hairline"), meok:cv("--meok"), muted:cv("--meok-muted"), red:cv("--red"), cheong:cv("--cheong"), ok:cv("--correct"), no:cv("--wrong"), hwang:cv("--hwang")};
  for(const z of zones){
    const here = me ? inZone(me, z) : false;
    let border = here ? C.hwang : C.line, lw = here ? 5 : 3;
    if(answered){ if(z.key===answer){border=C.ok; lw=6} else if(picked!==undefined && picked!==null && z.key===picked){border=C.no; lw=6} }
    ctx.fillStyle = C.hanji; ctx.globalAlpha = .82; roundRect(ctx,z.x,z.y,z.w,z.h,18); ctx.fill(); ctx.globalAlpha = 1;
    // 돗자리 결
    ctx.save(); roundRect(ctx,z.x,z.y,z.w,z.h,18); ctx.clip();
    ctx.strokeStyle = C.line; ctx.globalAlpha=.35; ctx.lineWidth=1; for(let yy=z.y+10; yy<z.y+z.h; yy+=10){ ctx.beginPath(); ctx.moveTo(z.x,yy); ctx.lineTo(z.x+z.w,yy); ctx.stroke(); }
    ctx.restore(); ctx.globalAlpha=1;
    ctx.strokeStyle = border; ctx.lineWidth = lw; roundRect(ctx,z.x,z.y,z.w,z.h,18); ctx.stroke();
    ctx.textAlign="center"; ctx.textBaseline="middle";
    if(type==="ox"){
      ctx.fillStyle = z.key==="O" ? C.cheong : C.red;
      ctx.font = `700 150px ${cv("--serif")}`; ctx.fillText(z.label, z.x+z.w/2, z.y+z.h/2-14);
      ctx.fillStyle = C.muted; ctx.font = `${fs(22)}px ${cv("--sans")}`; ctx.fillText(z.sub, z.x+z.w/2, z.y+z.h-30);
    } else {
      ctx.fillStyle = C.cheong; ctx.font = `700 40px ${cv("--serif")}`; ctx.fillText(z.label, z.x+40, z.y+z.h/2);
      const mcSize = Math.round(26 * Math.min(textK, 1.45));
      ctx.fillStyle = C.meok; ctx.font = `${mcSize}px ${cv("--sans")}`; ctx.textAlign="left";
      const lines = wrapText(ctx, z.sub, z.w-100);
      const lh = mcSize + 6;
      lines.forEach((l,i)=> ctx.fillText(l, z.x+76, z.y+z.h/2 + (i-(lines.length-1)/2)*lh));
    }
    if(answered && (z.key===answer || (picked!==undefined && picked!==null && z.key===picked))){
      ctx.textAlign="right"; ctx.font = `700 34px ${cv("--serif")}`;
      ctx.fillStyle = z.key===answer ? C.ok : C.no; ctx.fillText(z.key===answer ? "○ 정답" : "×", z.x+z.w-18, z.y+30);
    }
    // 진행자 화면: 구역별 인원 수
    if(counts){
      const n = counts[String(z.key)] || 0;
      ctx.textAlign="left"; ctx.textBaseline="middle"; ctx.font = `700 ${fs(26)}px ${cv("--serif")}`;
      const label = `${n}명`, tw = ctx.measureText(label).width + 20;
      ctx.fillStyle = C.meok; ctx.globalAlpha = .85; roundRect(ctx, z.x+14, z.y+12, tw, 34, 10); ctx.fill(); ctx.globalAlpha = 1;
      ctx.fillStyle = cv("--hanji"); ctx.fillText(label, z.x+24, z.y+30);
    }
  }
}

// 훈장님
export function drawTeacher(ctx){
  drawPerson(ctx, 480, 118, {upper:cv("--hanji"), lower:cv("--hanji"), ribbon:cv("--meok-muted"), hat:true});
  ctx.fillStyle = cv("--meok"); ctx.font = `${fs(15)}px ${cv("--sans")}`; ctx.textAlign="center"; ctx.textBaseline="alphabetic"; ctx.fillText("훈장님", 480, 156);
}

// 힌트 두루마리
export function drawScroll(ctx, t, {near, open}){
  ctx.save(); ctx.translate(SCROLL.x, SCROLL.y + Math.sin(t*3)*3);
  ctx.fillStyle = cv("--hanji"); ctx.strokeStyle = near||open ? cv("--hwang") : cv("--hairline"); ctx.lineWidth=3;
  roundRect(ctx,-22,-16,44,32,6); ctx.fill(); ctx.stroke();
  ctx.fillStyle = cv("--hwang"); ctx.fillRect(-26,-18,6,36); ctx.fillRect(20,-18,6,36);
  ctx.fillStyle = cv("--meok"); ctx.font = `700 18px ${cv("--serif")}`; ctx.textAlign="center"; ctx.textBaseline="middle"; ctx.fillText("?",0,1);
  ctx.restore();
  ctx.fillStyle = cv("--meok-muted"); ctx.font = `${fs(14)}px ${cv("--sans")}`; ctx.textAlign="center"; ctx.textBaseline="alphabetic"; ctx.fillText("힌트", SCROLL.x, SCROLL.y+40);
}

// 걸어가는 목표 표시
export function drawTarget(ctx, target){
  ctx.strokeStyle = cv("--hwang"); ctx.lineWidth=3; ctx.beginPath(); ctx.ellipse(target.x,target.y+20,16,6,0,0,Math.PI*2); ctx.stroke();
}

// 이름표
export function drawNameTag(ctx, x, y, text, {small} = {}){
  const size = fs(small ? 13 : 16);
  ctx.font = `700 ${size}px ${cv("--sans")}`; ctx.textAlign="center"; ctx.textBaseline="alphabetic";
  const tw = ctx.measureText(text).width + size, h = Math.round(size * 1.5);
  ctx.fillStyle = cv("--meok"); ctx.globalAlpha=.85; roundRect(ctx, x-tw/2, y+28, tw, h, 8); ctx.fill(); ctx.globalAlpha=1;
  ctx.fillStyle = cv("--hanji"); ctx.fillText(text, x, y+28+h-Math.round(size*.42));
}

// 학생 한 명(나 또는 남). mine=false면 조금 흐리게.
export function drawPlayer(ctx, p, {mine, t, name, color}){
  ctx.save();
  if(!mine) ctx.globalAlpha = .55;
  drawPerson(ctx, p.x, p.y, {
    upper: jacket(color), lower: cv("--meok-muted"), ribbon: cv("--red"),
    t, moving: p.moving, scale: mine ? 1 : .86
  });
  drawNameTag(ctx, p.x, p.y, name, {small: !mine});
  ctx.restore();
}
