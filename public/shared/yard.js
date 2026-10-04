// 한옥 마당 캔버스. 진행자 화면(관전)과 학생 화면(내 캐릭터)이 같이 쓴다.
// 내 캐릭터는 내 기기에서 바로 움직이고, 다른 학생은 서버가 보내 준 위치를 보간해서 부드럽게 그린다.
import { W, H, START, SCROLL, clampYard, zoneAt } from "./map.js";
import { COLORS, SPEED } from "./consts.js";
import { drawYard, drawZones, drawTeacher, drawScroll, drawTarget, drawPlayer, cv } from "./draw.js";

const SEND_HZ = 12;                 // 내 위치를 서버로 보내는 횟수(초당)
const LERP_MS = 110;                // 서버가 위치를 뿌리는 주기(100ms)보다 살짝 길게 잡아 끊기지 않게
const colorCss = id => (COLORS.find(c => c.id === id) || COLORS[0]).css;

export function createYard(canvas, opts = {}){
  const ctx = canvas.getContext("2d");
  const spectator = !!opts.spectator;

  const S = {
    zones: [], type: "ox",
    answered: false, answer: undefined, picked: undefined,
    counts: null,
    frozen: spectator,            // 입력을 받지 않는 상태
    hintOpen: false,
    me: { ...START, moving: false },
    target: null,
    others: new Map(),            // id -> {px,py,nx,ny,t0,moving}
    meta: new Map(),              // id -> {name,color}
    myId: null,
    myName: opts.name || "나",
    myColor: opts.color || "red",
    t: 0, last: performance.now(), raf: 0, lastSent: 0
  };

  const keys = new Set();
  const handlers = { move: () => {}, zone: () => {}, scroll: () => {} };

  /* ---------------- 입력 ---------------- */
  const toYard = e => {
    const r = canvas.getBoundingClientRect();
    return { x: (e.clientX - r.left) * W / r.width, y: (e.clientY - r.top) * H / r.height };
  };

  if (!spectator){
    canvas.addEventListener("pointerdown", e => {
      if (S.frozen) return;
      S.target = clampYard(toYard(e));
      canvas.parentElement?.focus?.({ preventScroll: true });
    });
  }

  const MOVE_KEYS = ["ArrowLeft","ArrowRight","ArrowUp","ArrowDown","a","d","w","s"];
  const keyName = e => (e.key.length === 1 ? e.key.toLowerCase() : e.key);

  function onKeyDown(e){
    if (spectator || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.target && e.target.tagName === "INPUT") return;
    const k = keyName(e);
    if (MOVE_KEYS.includes(k) && !S.frozen){ keys.add(k); S.target = null; e.preventDefault(); }
  }
  function onKeyUp(e){ keys.delete(keyName(e)); }

  // 화면 방향 버튼(태블릿용)
  function bindPad(container){
    container?.querySelectorAll("[data-dir]").forEach(b => {
      const on = e => { e.preventDefault(); if (S.frozen) return; keys.add("pad-" + b.dataset.dir); S.target = null; };
      const off = () => keys.delete("pad-" + b.dataset.dir);
      b.onpointerdown = on; b.onpointerup = off; b.onpointerleave = off; b.onpointercancel = off;
    });
  }

  /* ---------------- 서버에서 온 위치 ---------------- */
  function applyPositions({ p }){
    const now = performance.now();
    const seen = new Set();
    for (const [id, x, y, moving] of p){
      seen.add(id);
      if (id === S.myId) continue;                  // 내 캐릭터는 내 기기 계산을 믿는다
      const o = S.others.get(id);
      if (!o){ S.others.set(id, { px:x, py:y, nx:x, ny:y, t0:now, moving:!!moving }); continue; }
      const cur = lerpPos(o, now);
      o.px = cur.x; o.py = cur.y; o.nx = x; o.ny = y; o.t0 = now; o.moving = !!moving;
    }
    for (const id of [...S.others.keys()]) if (!seen.has(id)) S.others.delete(id);
  }

  function lerpPos(o, now){
    const k = Math.min(1, (now - o.t0) / LERP_MS);
    return { x: o.px + (o.nx - o.px) * k, y: o.py + (o.ny - o.py) * k };
  }

  /* ---------------- 한 프레임 ---------------- */
  function step(now){
    const dt = Math.min(.05, (now - S.last) / 1000); S.last = now; S.t += dt;

    if (!spectator && !S.frozen){
      let dx = 0, dy = 0;
      if (keys.has("ArrowLeft") || keys.has("a") || keys.has("pad-left")) dx -= 1;
      if (keys.has("ArrowRight") || keys.has("d") || keys.has("pad-right")) dx += 1;
      if (keys.has("ArrowUp") || keys.has("w") || keys.has("pad-up")) dy -= 1;
      if (keys.has("ArrowDown") || keys.has("s") || keys.has("pad-down")) dy += 1;
      const before = { ...S.me };
      if (dx || dy){
        S.target = null;
        const l = Math.hypot(dx, dy);
        S.me = { ...clampYard({ x: S.me.x + dx/l*SPEED*dt, y: S.me.y + dy/l*SPEED*dt }), moving: true };
      } else if (S.target){
        const vx = S.target.x - S.me.x, vy = S.target.y - S.me.y, d = Math.hypot(vx, vy);
        if (d < 4){ S.target = null; S.me.moving = false; }
        else { const m = Math.min(d, SPEED*dt); S.me = { x: S.me.x + vx/d*m, y: S.me.y + vy/d*m, moving: true }; }
      } else S.me.moving = false;

      // 힌트 두루마리에 가까이 가면 열린다
      if (Math.hypot(S.me.x - SCROLL.x, S.me.y - SCROLL.y) < 46) handlers.scroll();

      // 서 있는 자리가 바뀌면 알려 준다
      const z = zoneAt(S.me, S.zones);
      if (String(z?.key) !== S.lastZoneKey){ S.lastZoneKey = String(z?.key); handlers.zone(z); }

      // 움직였으면 초당 12번 정도 서버로 보낸다
      const moved = Math.hypot(S.me.x - before.x, S.me.y - before.y) > .5;
      if ((moved || S.needFinalSend) && now - S.lastSent > 1000 / SEND_HZ){
        S.lastSent = now; S.needFinalSend = moved;
        handlers.move({ x: Math.round(S.me.x * 10) / 10, y: Math.round(S.me.y * 10) / 10 });
      }
    }

    draw();
    S.raf = requestAnimationFrame(step);
  }

  function draw(){
    const dpr = canvas.width / W;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    drawYard(ctx);
    drawZones(ctx, {
      zones: S.zones, type: S.type,
      me: spectator ? null : S.me,
      answered: S.answered, answer: S.answer, picked: S.picked,
      counts: S.counts
    });
    drawTeacher(ctx);

    if (!spectator && !S.answered && S.zones.length){
      const near = Math.hypot(S.me.x - SCROLL.x, S.me.y - SCROLL.y) < 50;
      drawScroll(ctx, S.t, { near, open: S.hintOpen });
    }
    if (!spectator && S.target && !S.frozen) drawTarget(ctx, S.target);

    // 다른 학생 → 조금 흐리게, 작게. 아래쪽에 있는 사람을 나중에 그려 겹침이 자연스럽게.
    const now = performance.now();
    const list = [];
    for (const [id, o] of S.others){
      const m = S.meta.get(id); if (!m) continue;
      const p = lerpPos(o, now);
      list.push({ y: p.y, fn: () => drawPlayer(ctx, { ...p, moving: o.moving }, { mine: false, t: S.t, name: m.name, colorCss: colorCss(m.color) }) });
    }
    if (!spectator) list.push({ y: S.me.y + 1000, fn: () => drawPlayer(ctx, S.me, { mine: true, t: S.t, name: S.myName, colorCss: colorCss(S.myColor) }) });
    list.sort((a,b) => a.y - b.y).forEach(x => x.fn());
  }

  /* ---------------- 바깥에서 쓰는 것들 ---------------- */
  return {
    start(){
      cancelAnimationFrame(S.raf);
      S.last = performance.now();
      if (!spectator){ window.addEventListener("keydown", onKeyDown); window.addEventListener("keyup", onKeyUp); window.addEventListener("blur", () => keys.clear()); }
      S.raf = requestAnimationFrame(step);
    },
    stop(){ cancelAnimationFrame(S.raf); S.raf = 0; keys.clear(); },
    bindPad,
    applyPositions,
    on(name, fn){ handlers[name] = fn; },
    setMe({ id, name, color }){ if (id) S.myId = id; if (name) S.myName = name; if (color) S.myColor = color; },
    setMeta(players){ S.meta = new Map(players.map(p => [p.id, { name: p.name, color: p.color }])); },
    setQuestion({ zones, type }){
      S.zones = zones || []; S.type = type || "ox";
      S.answered = false; S.answer = undefined; S.picked = undefined; S.counts = null;
      S.hintOpen = false; S.frozen = spectator; S.target = null; S.lastZoneKey = undefined;
      S.me = { ...START, moving: false };
      keys.clear();
    },
    setReveal({ answer, picked }){ S.answered = true; S.answer = answer; S.picked = picked; S.frozen = true; S.target = null; keys.clear(); },
    setCounts(counts){ S.counts = counts; },
    setHintOpen(v){ S.hintOpen = v; },
    freeze(v){ S.frozen = !!v; if (v) keys.clear(); },
    clearZones(){ S.zones = []; S.counts = null; S.answered = false; },
    me(){ return { ...S.me }; },
    zoneHere(){ return zoneAt(S.me, S.zones); }
  };
}
