// 한옥 마당 캔버스. 진행자 화면(관전)과 학생 화면(내 캐릭터)이 같이 쓴다.
// 내 캐릭터는 내 기기에서 바로 움직이고, 다른 학생은 서버가 보내 준 위치를 보간해서 부드럽게 그린다.
import { W, H, START, SCROLL, clampYard, zoneAt } from "./map.js";
import { COLORS, SPEED } from "./consts.js";
import { drawYard, drawZones, drawTeacher, drawScroll, drawTarget, drawPlayer, setTextScale, cv } from "./draw.js";

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
    showOthers: true,             // false 면 다른 학생을 그리지 않는다(위치는 계속 받는다)
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
  // W A S D 는 글자가 아니라 키 자리(e.code)로 읽는다. 한글 입력 상태에서 W 가 'ㅈ' 으로 들어와도 걷게.
  const WASD = { KeyW: "w", KeyA: "a", KeyS: "s", KeyD: "d" };
  const keyName = e => WASD[e.code] || (e.key.length === 1 ? e.key.toLowerCase() : e.key);

  function onKeyDown(e){
    if (spectator || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.target && e.target.tagName === "INPUT") return;
    const k = keyName(e);
    if (MOVE_KEYS.includes(k) && !S.frozen){ keys.add(k); S.target = null; e.preventDefault(); }
  }
  function onKeyUp(e){ keys.delete(keyName(e)); }

  // 화면 조이스틱(폰·태블릿용). 민 방향과 세기(0~1)를 S.joy 에 담는다. 많이 밀수록 빨리 걷는다.
  function bindJoystick(joy){
    if (!joy) return;
    const knob = joy.firstElementChild, REACH = 46, DEAD = 8;
    const move = e => {
      const r = joy.getBoundingClientRect();
      let dx = e.clientX - (r.left + r.width / 2), dy = e.clientY - (r.top + r.height / 2);
      const d = Math.hypot(dx, dy);
      if (d > REACH){ dx *= REACH / d; dy *= REACH / d; }
      knob.style.transform = `translate(${dx}px,${dy}px)`;
      S.joy = d < DEAD ? null : { x: dx / REACH, y: dy / REACH };
      S.target = null;
    };
    const end = () => { S.joy = null; knob.style.transform = ""; joy.classList.remove("on"); };
    joyReset = end;
    joy.onpointerdown = e => { if (S.frozen) return; e.preventDefault(); joy.setPointerCapture(e.pointerId); joy.classList.add("on"); move(e); };
    joy.onpointermove = e => { if (joy.hasPointerCapture(e.pointerId) && !S.frozen) move(e); };
    joy.onpointerup = end; joy.onpointercancel = end; joy.onlostpointercapture = end;
  }
  let joyReset = () => { S.joy = null; };

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
      if (keys.has("ArrowLeft") || keys.has("a")) dx -= 1;
      if (keys.has("ArrowRight") || keys.has("d")) dx += 1;
      if (keys.has("ArrowUp") || keys.has("w")) dy -= 1;
      if (keys.has("ArrowDown") || keys.has("s")) dy += 1;
      const before = { ...S.me };
      if (dx || dy){
        S.target = null;
        const l = Math.hypot(dx, dy);
        S.me = { ...clampYard({ x: S.me.x + dx/l*SPEED*dt, y: S.me.y + dy/l*SPEED*dt }), moving: true };
      } else if (S.joy){
        S.target = null;
        S.me = { ...clampYard({ x: S.me.x + S.joy.x*SPEED*dt, y: S.me.y + S.joy.y*SPEED*dt }), moving: true };
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
    // 화면에서 작아진 만큼 글자를 키워 폰에서도 이름표가 보이게 한다
    setTextScale(canvas.clientWidth ? W / canvas.clientWidth : 1);
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
    for (const [id, o] of S.showOthers ? S.others : []){
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
    stop(){ cancelAnimationFrame(S.raf); S.raf = 0; keys.clear(); joyReset(); },
    bindJoystick,
    applyPositions,
    on(name, fn){ handlers[name] = fn; },
    setMe({ id, name, color }){ if (id) S.myId = id; if (name) S.myName = name; if (color) S.myColor = color; },
    setMeta(players){ S.meta = new Map(players.map(p => [p.id, { name: p.name, color: p.color }])); },
    setQuestion({ zones, type }){
      S.zones = zones || []; S.type = type || "ox";
      S.answered = false; S.answer = undefined; S.picked = undefined; S.counts = null;
      S.hintOpen = false; S.frozen = spectator; S.target = null; S.lastZoneKey = undefined;
      S.me = { ...START, moving: false };
      keys.clear(); joyReset();
    },
    setReveal({ answer, picked }){ S.answered = true; S.answer = answer; S.picked = picked; S.frozen = true; S.target = null; keys.clear(); joyReset(); },
    setCounts(counts){ S.counts = counts; },
    setShowOthers(v){ S.showOthers = !!v; },
    setHintOpen(v){ S.hintOpen = v; },
    freeze(v){ S.frozen = !!v; if (v){ keys.clear(); joyReset(); } },
    clearZones(){ S.zones = []; S.counts = null; S.answered = false; },
    me(){ return { ...S.me }; },
    zoneHere(){ return zoneAt(S.me, S.zones); }
  };
}
