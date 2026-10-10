-- 화면이 부르는 함수들. 모두 security definer 라서 표에 직접 손대지 않고 여기를 거친다.
-- 채점과 시간은 전부 이 안에서 DB 시계(now())로 정한다.

/* ================= 안에서만 쓰는 것 ================= */

-- 문제 하나를 화면에 보낼 모양으로. reveal 이 아니면 정답·해설·힌트는 빼고 보낸다.
create or replace function hq_question_json(p_round jsonb, p_index int, p_reveal boolean)
returns jsonb language sql stable as $$
  select case when p_index < 0 or p_round is null or p_index >= jsonb_array_length(p_round) then null
  else (
    with q as (select p_round -> p_index as x)
    select jsonb_strip_nulls(jsonb_build_object(
      'qIndex',  p_index,
      'total',   jsonb_array_length(p_round),
      'type',    x ->> 'type',
      'q',       x ->> 'q',
      'choices', x -> 'choices'
    ) || case when p_reveal then jsonb_build_object(
      'answer',      x ->> 'answer',
      'answerLabel', hq_answer_label(x ->> 'type', x ->> 'answer', x -> 'choices'),
      'explain',     x ->> 'explain'
    ) else '{}'::jsonb end)
    from q
  ) end
$$;

-- 순위: 점수 내림차순 → 빠르기 보너스 내림차순 → 이름 순
create or replace function hq_ranking(p_code text, p_limit int default null)
returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(r order by r.place), '[]'::jsonb) from (
    select row_number() over (order by p.score desc, p.bonus desc, p.name) as place,
           p.id, p.name, p.color, p.score,
           round(p.bonus, 2) as bonus,
           hq_title(p.score) as title,
           hq_title_say(p.score) as say
    from players p where p.room_code = p_code
    order by place
    limit p_limit
  ) r
$$;

create or replace function hq_touch(p_code text) returns void
language sql as $$
  update rooms set last_seen = now(), updated_at = now() where code = p_code
$$;

-- 아무도 없는 방은 15분 뒤 정리한다(방을 새로 만들 때마다 한 번씩 쓸어 낸다).
create or replace function hq_sweep() returns int
language sql as $$
  with gone as (delete from rooms where last_seen < now() - interval '15 minutes' returning 1)
  select count(*)::int from gone
$$;

/* ================= 진행자 ================= */

-- 방을 하나 연다(안에서만 쓴다). p_prev 를 주면 그 방에서 이어진 새 방이 된다.
create or replace function hq_create_room(p_prev text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_code text; v_token uuid; v_level text; i int;
begin
  perform hq_sweep();
  for i in 1..500 loop
    v_code := lpad((1000 + floor(random() * 9000))::int::text, 4, '0');
    exit when not exists (select 1 from rooms where code = v_code);
    v_code := null;
  end loop;
  if v_code is null then raise exception '방을 더 만들 수 없어요.'; end if;

  -- 이어진 방은 단계도 그대로 이어받는다
  select level into v_level from rooms where code = p_prev;
  insert into rooms(code, prev_code, level) values (v_code, p_prev, coalesce(v_level, 'elem'));
  insert into room_secrets(code) values (v_code) returning host_token into v_token;
  return jsonb_build_object('code', v_code, 'hostToken', v_token, 'snapshot', get_snapshot(v_code, null));
end $$;

create or replace function host_create_room()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  return hq_create_room(null);
end $$;

create or replace function hq_check_host(p_code text, p_token uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not exists (select 1 from room_secrets where code = p_code and host_token = p_token) then
    raise exception '이 방의 진행자가 아니에요.';
  end if;
end $$;

create or replace function host_resume(p_code text, p_token uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform hq_check_host(p_code, p_token);
  perform hq_touch(p_code);
  return jsonb_build_object('code', p_code, 'hostToken', p_token, 'snapshot', get_snapshot(p_code, null));
end $$;

create or replace function host_set_level(p_code text, p_token uuid, p_level text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform hq_check_host(p_code, p_token);
  if not exists (select 1 from levels where key = p_level) then raise exception '그런 단계가 없어요.'; end if;
  update rooms set level = p_level, updated_at = now(), last_seen = now()
   where code = p_code and phase in ('lobby','final');
  return get_snapshot(p_code, null);
end $$;

-- 다음 문제로 넘어간다(안에서만 쓴다). 10문제를 다 풀었으면 최종 결과로 간다.
create or replace function hq_next_question(p_code text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_round jsonb; v_next int; v_type text;
begin
  select rs.round into v_round from room_secrets rs where rs.code = p_code;
  select r.q_index + 1 into v_next from rooms r where r.code = p_code;

  if v_round is null or v_next >= jsonb_array_length(v_round) then
    perform hq_finish(p_code);
    return;
  end if;

  v_type := v_round -> v_next ->> 'type';
  update rooms set
    phase = 'question', q_index = v_next, q_total = jsonb_array_length(v_round),
    started_at = now(), ends_at = now() + make_interval(secs => hq_seconds(v_type)),
    updated_at = now(), last_seen = now()
  where code = p_code;

  -- 새 문제는 모두 출발선에서 다시 시작한다. 지난 문제 중간에 들어온 학생도 이제 함께 푼다.
  update players set
    pending = false, hint_used = false,
    locked_x = null, locked_y = null, locked_at = null,
    pos_x = 480, pos_y = 540, pos_at = now(), moving = false
  where room_code = p_code;
end $$;

create or replace function host_start(p_code text, p_token uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_level text; v_used jsonb; v_built jsonb;
begin
  perform hq_check_host(p_code, p_token);
  select r.level into v_level from rooms r where r.code = p_code;
  select rs.used into v_used from room_secrets rs where rs.code = p_code;

  v_built := hq_build_round(v_level, coalesce(v_used, '{}'::jsonb));
  update room_secrets set round = v_built -> 'round', used = v_built -> 'used' where code = p_code;

  delete from answers where room_code = p_code;
  update players set score = 0, bonus = 0, pending = false where room_code = p_code;
  update rooms set q_index = -1, graded_index = -1, q_total = jsonb_array_length(v_built -> 'round')
   where code = p_code;

  perform hq_next_question(p_code);
  return get_snapshot(p_code, null);
end $$;

create or replace function host_next(p_code text, p_token uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform hq_check_host(p_code, p_token);
  if (select phase from rooms where code = p_code) <> 'reveal' then
    return get_snapshot(p_code, null);          -- 채점 전에는 넘어가지 않는다
  end if;
  perform hq_next_question(p_code);
  return get_snapshot(p_code, null);
end $$;

create or replace function hq_finish(p_code text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n int; v_avg numeric; v_level text; v_name text; v_played int;
begin
  select r.level, r.q_index + 1 into v_level, v_played from rooms r where r.code = p_code;
  select count(*), coalesce(avg(score), 0) into v_n, v_avg from players where room_code = p_code;

  update rooms set phase = 'final', updated_at = now(), last_seen = now() where code = p_code;

  -- 부스 보고서용 기록. 이름은 남기지 않는다.
  if v_n > 0 and v_played > 0 then
    select name into v_name from levels where key = v_level;
    insert into participation(level, level_name, players, questions, avg_score)
    values (v_level, coalesce(v_name, v_level), v_n, v_played, round(v_avg, 1));
  end if;
end $$;

create or replace function host_end(p_code text, p_token uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform hq_check_host(p_code, p_token);
  if (select phase from rooms where code = p_code) in ('lobby','final') then
    return get_snapshot(p_code, null);
  end if;
  perform hq_finish(p_code);
  return get_snapshot(p_code, null);
end $$;

-- 강제 종료: 게임을 끝내고(최종 순위는 옛 방에 남는다) 새 방을 연다.
-- 두 번 눌러도 새 방은 하나만 생긴다(이미 이어진 방이 있으면 그 방을 돌려준다).
create or replace function host_new_room(p_code text, p_token uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_next jsonb; v_code text; v_token uuid; v_finished jsonb;
begin
  perform hq_check_host(p_code, p_token);
  perform 1 from rooms where code = p_code for update;
  if (select phase from rooms where code = p_code) in ('question','reveal') then
    perform hq_finish(p_code);
  end if;
  perform hq_touch(p_code);
  v_finished := get_snapshot(p_code, null);

  select r.code, rs.host_token into v_code, v_token
    from rooms r join room_secrets rs on rs.code = r.code
   where r.prev_code = p_code and r.phase = 'lobby'
   order by r.created_at desc limit 1;
  if v_code is not null then
    perform hq_touch(v_code);
    v_next := jsonb_build_object('code', v_code, 'hostToken', v_token, 'snapshot', get_snapshot(v_code, null));
  else
    v_next := hq_create_room(p_code);
  end if;
  return v_next || jsonb_build_object('finished', v_finished);
end $$;

-- 이전 방 학생을 새 방으로 다시 부른다. p_player 가 없으면 아직 안 온 학생 모두.
create or replace function host_invite(p_code text, p_token uuid, p_player uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_prev text;
begin
  perform hq_check_host(p_code, p_token);
  select prev_code into v_prev from rooms where code = p_code;
  if v_prev is null then raise exception '다시 부를 이전 방이 없어요. 이전 방이 정리됐을 수 있어요.'; end if;
  update players set invited_to = p_code
   where room_code = v_prev and not moved and (p_player is null or id = p_player);
  perform hq_touch(v_prev);                     -- 이전 방 학생 화면이 초대를 바로 알아채게
  perform hq_touch(p_code);
  return get_snapshot(p_code, null);
end $$;

create or replace function host_kick(p_code text, p_token uuid, p_player uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform hq_check_host(p_code, p_token);
  delete from players where id = p_player and room_code = p_code;
  perform hq_touch(p_code);
  return get_snapshot(p_code, null);
end $$;

create or replace function host_close(p_code text, p_token uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform hq_check_host(p_code, p_token);
  delete from rooms where code = p_code;
end $$;

/* ================= 채점 ================= */

-- 마감 시각이 지나야만 채점한다. 두 번 불러도 결과가 바뀌지 않는다.
-- 그래서 진행자 화면이 불러도 되고, 진행자 화면이 멈췄으면 학생 화면이 대신 불러도 된다.
create or replace function grade_question(p_code text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_room rooms%rowtype;
  v_round jsonb; v_q jsonb; v_type text; v_answer text;
  v_total_ms numeric;
  p record;
  v_x double precision; v_y double precision; v_at timestamptz;
  v_picked text; v_correct boolean; v_bonus numeric;
begin
  select * into v_room from rooms where code = p_code for update;
  if not found then raise exception '그런 방이 없어요.'; end if;
  if v_room.phase <> 'question' then return get_snapshot(p_code, null); end if;      -- 이미 채점됨
  if v_room.graded_index >= v_room.q_index then return get_snapshot(p_code, null); end if;
  if now() < v_room.ends_at then
    raise exception '아직 시간이 남았어요.' using errcode = 'P0001';
  end if;

  select rs.round into v_round from room_secrets rs where rs.code = p_code;
  v_q := v_round -> v_room.q_index;
  v_type := v_q ->> 'type';
  v_answer := v_q ->> 'answer';
  v_total_ms := greatest(1, extract(epoch from (v_room.ends_at - v_room.started_at)) * 1000);

  for p in select * from players where room_code = p_code and not pending loop
    -- "여기로 결정!"을 눌렀으면 그때의 자리와 시각, 아니면 마감 순간의 자리
    v_x  := coalesce(p.locked_x, p.pos_x);
    v_y  := coalesce(p.locked_y, p.pos_y);
    v_at := coalesce(p.locked_at, v_room.ends_at);

    v_picked  := hq_zone_at(v_type, v_x, v_y);
    v_correct := v_picked is not null and v_picked = v_answer;
    -- 빠르기 보너스: 점수에는 더하지 않고 순위 동점 처리에만 쓴다
    v_bonus := case when v_correct
      then greatest(0, least(1, extract(epoch from (v_room.ends_at - v_at)) * 1000 / v_total_ms))
      else 0 end;

    insert into answers(room_code, q_index, player_id, picked, correct, bonus)
    values (p_code, v_room.q_index, p.id, v_picked, v_correct, v_bonus)
    on conflict (room_code, q_index, player_id) do nothing;

    if v_correct then
      update players set score = score + 1, bonus = bonus + v_bonus where id = p.id;
    end if;
  end loop;

  update rooms set phase = 'reveal', graded_index = v_room.q_index, updated_at = now()
   where code = p_code;

  return get_snapshot(p_code, null);
end $$;

/* ================= 학생 ================= */

create or replace function play_join(p_code text, p_name text, p_color text, p_token uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_room rooms%rowtype;
  v_id uuid; v_new_token uuid; v_base text; v_name text; v_n int; v_count int;
begin
  select * into v_room from rooms where code = p_code for update;
  if not found then raise exception '그런 입장 코드가 없어요. 진행자 화면의 숫자를 다시 확인해 주세요.'; end if;

  -- 재접속: 같은 기기(열쇠)면 이름과 점수를 그대로 이어 간다
  if p_token is not null then
    select ps.player_id into v_id from player_secrets ps
      join players pl on pl.id = ps.player_id
     where ps.token = p_token and pl.room_code = p_code;
    if v_id is not null then
      update players set connected = true, last_seen = now(),
             color = coalesce(nullif(p_color, ''), color)
       where id = v_id;
      perform hq_touch(p_code);
      return jsonb_build_object('playerId', v_id, 'playerToken', p_token, 'rejoined', true,
                                'snapshot', get_snapshot(p_code, p_token));
    end if;
  end if;

  select count(*) into v_count from players where room_code = p_code;
  if v_count >= 30 then raise exception '이 방은 30명까지만 들어올 수 있어요.'; end if;

  -- 이름은 8자까지. 같은 이름이 있으면 뒤에 숫자를 붙인다.
  v_base := nullif(btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')), '');
  v_base := coalesce(left(v_base, 8), '친구');
  if v_base = '' then v_base := '친구'; end if;
  v_name := v_base; v_n := 1;
  while exists (select 1 from players where room_code = p_code and name = v_name) loop
    v_n := v_n + 1;
    v_name := v_base || v_n::text;
    if v_n > 99 then v_name := v_base || floor(random() * 1000)::int::text; exit; end if;
  end loop;

  insert into players(room_code, name, color, pending)
  values (p_code, v_name, coalesce(nullif(p_color, ''), 'red'), v_room.phase = 'question')
  returning id into v_id;
  insert into player_secrets(player_id) values (v_id) returning token into v_new_token;

  perform hq_touch(p_code);
  return jsonb_build_object('playerId', v_id, 'playerToken', v_new_token, 'rejoined', false,
                            'snapshot', get_snapshot(p_code, v_new_token));
end $$;

-- 초대받은 학생이 새 방으로 옮겨 간다. 이름과 색은 그대로, 점수는 새로 시작한다.
create or replace function play_accept_invite(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare p players%rowtype; v_res jsonb;
begin
  select pl.* into p from players pl join player_secrets ps on ps.player_id = pl.id where ps.token = p_token;
  if not found or p.invited_to is null then raise exception '받은 초대가 없어요.'; end if;
  if p.moved then raise exception '이미 새 방으로 옮겨 갔어요.'; end if;

  v_res := play_join(p.invited_to, p.name, p.color, null);
  update players set moved = true, connected = false where id = p.id;
  perform hq_touch(p.room_code);
  return v_res || jsonb_build_object('code', p.invited_to);
end $$;

-- 위치. 마당 밖으로 못 나가게 막고, 걷는 속도(260px/초)보다 빠른 이동은 그 속도까지만 인정한다.
create or replace function play_move(p_token uuid, p_x double precision, p_y double precision)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  p players%rowtype;
  v_x double precision; v_y double precision;
  v_dt double precision; v_limit double precision; v_d double precision;
begin
  select pl.* into p from players pl join player_secrets ps on ps.player_id = pl.id where ps.token = p_token;
  if not found then return null; end if;

  v_x := hq_clamp_x(p_x);
  v_y := hq_clamp_y(p_y);
  v_dt := least(3.0, greatest(0.05, extract(epoch from (now() - p.pos_at))));
  v_limit := 260 * 1.6 * v_dt + 12;
  v_d := sqrt((v_x - p.pos_x)^2 + (v_y - p.pos_y)^2);
  if v_d > v_limit then
    v_x := p.pos_x + (v_x - p.pos_x) / v_d * v_limit;
    v_y := p.pos_y + (v_y - p.pos_y) / v_d * v_limit;
  end if;

  update players set pos_x = v_x, pos_y = v_y, pos_at = now(), moving = (v_d > 1), last_seen = now()
   where id = p.id;
  return jsonb_build_object('x', v_x, 'y', v_y);
end $$;

-- "여기로 결정!" — 그 순간의 자리와 시각을 고정한다(빠르기 보너스의 근거).
create or replace function play_lock(p_token uuid, p_x double precision default null, p_y double precision default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare p players%rowtype; v_room rooms%rowtype; v_type text; v_zone text;
begin
  if p_x is not null then perform play_move(p_token, p_x, p_y); end if;
  select pl.* into p from players pl join player_secrets ps on ps.player_id = pl.id where ps.token = p_token;
  if not found then return jsonb_build_object('ok', false, 'reason', 'player'); end if;

  select * into v_room from rooms where code = p.room_code;
  if v_room.phase <> 'question' or now() > v_room.ends_at or p.pending or p.locked_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'phase');
  end if;

  select rs.round -> v_room.q_index ->> 'type' into v_type from room_secrets rs where rs.code = p.room_code;
  v_zone := hq_zone_at(v_type, p.pos_x, p.pos_y);
  if v_zone is null then return jsonb_build_object('ok', false, 'reason', 'zone'); end if;

  update players set locked_x = pos_x, locked_y = pos_y, locked_at = now() where id = p.id;
  return jsonb_build_object('ok', true, 'zone', v_zone);
end $$;

-- 힌트는 물어본 학생에게만 돌려준다.
create or replace function play_hint(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare p players%rowtype; v_room rooms%rowtype; v_hint text;
begin
  select pl.* into p from players pl join player_secrets ps on ps.player_id = pl.id where ps.token = p_token;
  if not found then return jsonb_build_object('hint', null); end if;
  select * into v_room from rooms where code = p.room_code;
  if v_room.phase <> 'question' then return jsonb_build_object('hint', null); end if;

  select rs.round -> v_room.q_index ->> 'hint' into v_hint from room_secrets rs where rs.code = p.room_code;
  update players set hint_used = true where id = p.id;
  return jsonb_build_object('hint', v_hint);
end $$;

-- 화면을 닫거나 새로고침할 때
create or replace function play_leave(p_token uuid)
returns void language sql security definer set search_path = public, pg_temp as $$
  update players set connected = false, moving = false
   where id = (select player_id from player_secrets where token = p_token)
$$;

/* ================= 지금 상황 ================= */

create or replace function get_today_total() returns int
language sql security definer set search_path = public, pg_temp as $$
  select coalesce(sum(players), 0)::int from participation where day = current_date
$$;

-- 화면이 새로고침돼도 그대로 이어받을 수 있게 지금 상황을 한 번에 돌려준다.
-- p_player_token 을 주면 그 학생 본인의 상황(자리를 정했는지, 이번 문제를 맞혔는지)도 담는다.
create or replace function get_snapshot(p_code text, p_player_token uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_room rooms%rowtype; v_round jsonb; v_reveal boolean;
  v_players jsonb; v_you jsonb; v_pid uuid; v_lvl levels%rowtype; v_prev jsonb;
begin
  select * into v_room from rooms where code = p_code;
  if not found then return null; end if;
  select rs.round into v_round from room_secrets rs where rs.code = p_code;
  select * into v_lvl from levels where key = v_room.level;
  v_reveal := v_room.phase in ('reveal', 'final');

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'name', p.name, 'color', p.color, 'score', p.score,
           'connected', p.connected, 'pending', p.pending, 'locked', p.locked_at is not null
         ) order by p.joined_at), '[]'::jsonb)
    into v_players from players p where p.room_code = p_code;

  if p_player_token is not null then
    select ps.player_id into v_pid from player_secrets ps
      join players pl on pl.id = ps.player_id
     where ps.token = p_player_token and pl.room_code = p_code;
    if v_pid is not null then
      select jsonb_build_object(
        'id', pl.id, 'name', pl.name, 'color', pl.color, 'score', pl.score,
        'pending', pl.pending, 'hintUsed', pl.hint_used, 'locked', pl.locked_at is not null,
        'answered', a.player_id is not null, 'correct', a.correct, 'picked', a.picked,
        'invite', case when not pl.moved then pl.invited_to end
      ) into v_you
      from players pl
      left join answers a on a.player_id = pl.id and a.room_code = p_code and a.q_index = v_room.q_index
      where pl.id = v_pid;
    end if;
  end if;

  -- 진행자에게만: 이전 방 학생 명단(다시 초대하려고)
  if p_player_token is null and v_room.prev_code is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', p.id, 'name', p.name, 'color', p.color,
             'invited', p.invited_to = v_room.code, 'moved', p.moved
           ) order by p.joined_at), '[]'::jsonb)
      into v_prev from players p where p.room_code = v_room.prev_code;
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'code', v_room.code,
    'phase', v_room.phase,
    'level', v_room.level,
    'levelInfo', jsonb_build_object('key', v_lvl.key, 'name', v_lvl.name, 'kind', v_lvl.kind, 'desc', v_lvl.descr),
    'qIndex', v_room.q_index,
    'total', v_room.q_total,
    'startAt', v_room.started_at,
    'endsAt', v_room.ends_at,
    'now', now(),
    'count', jsonb_array_length(v_players),
    'maxPlayers', 30,
    'players', v_players,
    'question', hq_question_json(v_round, v_room.q_index, v_reveal),
    'leaderboard', case when v_reveal then hq_ranking(p_code, 5) else null end,
    'ranking', case when v_room.phase = 'final' then hq_ranking(p_code, null) else null end,
    'questions', case when v_room.phase = 'final' then v_room.q_index + 1 else null end,
    'last', v_room.q_index >= v_room.q_total - 1,
    'todayTotal', get_today_total(),
    'you', v_you,
    'prevCode', v_room.prev_code,
    'prev', v_prev
  ));
end $$;

-- 단계 목록(시작 화면용)
create or replace function get_levels() returns jsonb
language sql security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'key', l.key, 'name', l.name, 'kind', l.kind, 'desc', l.descr,
    'total', (select count(*) from questions q where q.level = l.key)
  ) order by l.sort), '[]'::jsonb) from levels l
$$;

/* ================= 함수 권한 ================= */
-- Postgres 는 함수를 만들면 누구나(PUBLIC) 부를 수 있게 둔다.
-- 정답이 들어 있는 round 를 다루는 함수가 섞여 있으므로 먼저 전부 회수하고,
-- 화면이 실제로 부르는 함수만 손님(anon)에게 다시 열어 준다.
revoke execute on all functions in schema public from public;
alter default privileges in schema public revoke execute on functions from public;

do $$
declare fn text; roles text;
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    raise notice 'anon 역할이 없어 함수 권한을 열지 않았습니다(로컬 테스트라면 정상).';
    return;
  end if;
  roles := 'anon, authenticated';
  -- Supabase 는 PUBLIC 과 별도로 anon·authenticated 에게 직접 실행 권한을 준다. 그것도 회수한다.
  execute format('revoke execute on all functions in schema public from %s', roles);
  execute format('alter default privileges in schema public revoke execute on functions from %s', roles);
  -- 안에서만 쓰는 함수(hq_*)는 열지 않는다.
  foreach fn in array array[
    'host_create_room()', 'host_resume(text,uuid)', 'host_set_level(text,uuid,text)',
    'host_start(text,uuid)', 'host_next(text,uuid)', 'host_end(text,uuid)',
    'host_kick(text,uuid,uuid)', 'host_close(text,uuid)',
    'host_new_room(text,uuid)', 'host_invite(text,uuid,uuid)', 'play_accept_invite(uuid)',
    'grade_question(text)',
    'play_join(text,text,text,uuid)', 'play_move(uuid,double precision,double precision)',
    'play_lock(uuid,double precision,double precision)', 'play_hint(uuid)', 'play_leave(uuid)',
    'get_snapshot(text,uuid)', 'get_levels()', 'get_today_total()'
  ] loop
    execute format('grant execute on function %s to %s', fn, roles);
  end loop;
end $$;
