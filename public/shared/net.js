// Supabase 와 주고받는 부분. 화면(host.js / play.js)은 이 파일만 쓴다.
//
// 정해 둔 것
//  · 채점과 시간은 모두 Postgres 함수가 정한다. 화면은 받은 시각에 맞춰 그리기만 한다.
//  · 방의 단계가 바뀌는 것은 rooms 표의 변화(Realtime)로 알고, 그때 지금 상황을 다시 받아 온다.
//  · 위치는 표에 싣지 않고 Broadcast 로만 주고받는다(무료 한도를 아끼려고).

const CFG = (typeof window !== "undefined" && window.__HQ) || {};

export class NetError extends Error {}

export function configMissing(){
  return !CFG.supabaseUrl || !CFG.supabaseAnonKey;
}

let client = null;
export function supa(){
  if (client) return client;
  if (configMissing()) throw new NetError("Supabase 주소와 키가 없어요. README의 '처음 설정'을 보세요.");
  if (!window.supabase?.createClient) throw new NetError("Supabase 라이브러리를 불러오지 못했어요.");
  client = window.supabase.createClient(CFG.supabaseUrl, CFG.supabaseAnonKey, {
    auth: { persistSession: false },
    realtime: { params: { eventsPerSecond: 20 } }
  });
  return client;
}

// 서버가 올려 보내는 오류 문구를 그대로 보여 준다(한국어로 써 두었다).
async function rpc(fn, args = {}){
  const { data, error } = await supa().rpc(fn, args);
  if (error) throw new NetError(error.message || "서버와 이야기하지 못했어요.");
  return data;
}

export const api = {
  levels:      ()                       => rpc("get_levels"),
  snapshot:    (code, token)            => rpc("get_snapshot", { p_code: code, p_player_token: token || null }),
  grade:       (code)                   => rpc("grade_question", { p_code: code }),

  hostCreate:  ()                       => rpc("host_create_room"),
  hostResume:  (code, token)            => rpc("host_resume",    { p_code: code, p_token: token }),
  hostLevel:   (code, token, level)     => rpc("host_set_level", { p_code: code, p_token: token, p_level: level }),
  hostStart:   (code, token)            => rpc("host_start",     { p_code: code, p_token: token }),
  hostNext:    (code, token)            => rpc("host_next",      { p_code: code, p_token: token }),
  hostEnd:     (code, token)            => rpc("host_end",       { p_code: code, p_token: token }),
  hostKick:    (code, token, player)    => rpc("host_kick",      { p_code: code, p_token: token, p_player: player }),

  playJoin:    (code, name, color, tok) => rpc("play_join", { p_code: code, p_name: name, p_color: color, p_token: tok || null }),
  playMove:    (token, x, y)            => rpc("play_move", { p_token: token, p_x: x, p_y: y }),
  playLock:    (token, x, y)            => rpc("play_lock", { p_token: token, p_x: x ?? null, p_y: y ?? null }),
  playHint:    (token)                  => rpc("play_hint", { p_token: token }),
  playLeave:   (token)                  => rpc("play_leave", { p_token: token })
};

/* ---------------- 방 하나를 지켜보는 것 ---------------- */
//  · rooms 표가 바뀌면 지금 상황을 다시 받아 화면에 넘긴다.
//  · 마감 시각이 되면 채점 함수를 부른다. 두 번 불러도 결과가 같으므로
//    진행자 화면이 부르고, 멈춰 있으면 학생 화면이 조금 늦게 대신 부른다.
export function watchRoom({ code, playerToken, isHost, onSnapshot, onError }){
  const sb = supa();
  let snap = null, offset = 0, timer = 0, refreshing = false, again = false, dead = false;
  let channel = null;

  const serverNow = () => Date.now() + offset;

  async function refresh(){
    if (dead) return;
    if (refreshing){ again = true; return; }
    refreshing = true;
    try {
      const s = await api.snapshot(code, playerToken);
      if (dead) return;
      if (!s){ onSnapshot(null); return; }                     // 방이 사라졌다
      if (s.now) offset = new Date(s.now).getTime() - Date.now();
      snap = s;
      scheduleGrade(s);
      onSnapshot(s);
    } catch (e) {
      onError?.(e);
    } finally {
      refreshing = false;
      if (again){ again = false; refresh(); }
    }
  }

  function scheduleGrade(s){
    clearTimeout(timer);
    if (s.phase !== "question" || !s.endsAt) return;
    // 진행자가 먼저, 학생은 조금 늦게(진행자 화면이 멈췄을 때를 대비). 한꺼번에 몰리지 않게 조금씩 흩는다.
    const delay = Math.max(0, new Date(s.endsAt).getTime() - serverNow())
                + (isHost ? 400 : 2000 + Math.random() * 1500);
    timer = setTimeout(async () => {
      try { await api.grade(code); }
      catch (e) { if (!/시간이 남았/.test(e.message)) onError?.(e); setTimeout(refresh, 800); }
    }, delay);
  }

  // rooms 표의 변화를 구독한다(단계가 바뀌는 순간, 학생이 들어오는 순간).
  channel = sb.channel(`hq:${code}`, { config: { broadcast: { self: false } } })
    .on("postgres_changes", { event: "*", schema: "public", table: "rooms", filter: `code=eq.${code}` },
        () => setTimeout(refresh, 60 + Math.random() * 200))
    .subscribe(status => { if (status === "SUBSCRIBED") refresh(); });

  // 연결이 끊겼다 붙었을 때를 대비한 느린 확인
  const beat = setInterval(refresh, 15000);

  return {
    channel,
    refresh,
    serverNow,
    get snapshot(){ return snap; },
    stop(){
      dead = true;
      clearTimeout(timer); clearInterval(beat);
      try { sb.removeChannel(channel); } catch {}
    }
  };
}

/* ---------------- 위치 주고받기 ---------------- */
// 학생: 내 위치를 3Hz 로 보낸다(움직일 때만).
// 진행자: 모두의 위치를 모아 2Hz 로 한 번에 되뿌린다. 학생은 그것만 받는다.
// 이렇게 하면 주고받는 메시지 수가 사람 수의 제곱이 아니라 사람 수에 비례한다.
export function positionRelay(channel, { isHost, onAll }){
  const seen = new Map();          // id -> [x, y, moving, 마지막으로 들은 시각]
  let timer = 0;

  if (isHost){
    channel.on("broadcast", { event: "p" }, ({ payload }) => {
      if (payload && payload.i) seen.set(payload.i, [payload.x, payload.y, payload.m ? 1 : 0, Date.now()]);
    });
    timer = setInterval(() => {
      const now = Date.now();
      const p = [];
      for (const [id, v] of seen){
        if (now - v[3] > 8000){ seen.delete(id); continue; }   // 오래 조용하면 뺀다
        p.push([id, v[0], v[1], v[2]]);
      }
      onAll?.({ t: now, p });                                  // 진행자 화면도 같은 그림을 쓴다
      if (p.length) channel.send({ type: "broadcast", event: "all", payload: { t: now, p } });
    }, 500);
  } else {
    channel.on("broadcast", { event: "all" }, ({ payload }) => onAll?.(payload));
  }

  return {
    // 학생이 자기 위치를 알린다
    send(id, x, y, moving){
      channel.send({ type: "broadcast", event: "p", payload: { i: id, x: Math.round(x), y: Math.round(y), m: moving ? 1 : 0 } });
    },
    stop(){ clearInterval(timer); }
  };
}
