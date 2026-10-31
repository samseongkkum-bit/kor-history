-- 학생이 나가면 진행자 화면의 인원에서 저절로 빠지게 한다.
--
-- 학생이 "들어와 있다"(hq_live)는 것은 두 가지가 모두 맞을 때다.
--   · connected  : 화면을 닫거나 다른 앱으로 가면 play_leave 가 false 로 바꾼다
--   · last_seen  : 학생 화면이 10초마다 play_ping 으로 새로 적는다.
--                  폰이 꺼지거나 인터넷이 끊겨 play_leave 가 오지 못해도 40초가 지나면 나간 것으로 본다.
-- 학생 행은 지우지 않는다. 다시 들어오면(같은 기기) 이름·점수를 그대로 이어 간다.

create or replace function hq_live(p players) returns boolean
language sql stable set search_path = public, pg_temp as $$
  select p.connected and p.last_seen > now() - interval '40 seconds'
$$;

-- 학생 화면이 10초마다 "아직 여기 있어요"를 알린다.
-- 나간 것으로 보이던 학생이 돌아오면 방을 건드려 진행자 화면이 바로 다시 센다.
create or replace function play_ping(p_token uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare p players%rowtype; v_was boolean;
begin
  select pl.* into p from players pl join player_secrets ps on ps.player_id = pl.id where ps.token = p_token;
  if not found then return; end if;
  v_was := hq_live(p);
  update players set connected = true, last_seen = now() where id = p.id;
  if not v_was then perform hq_touch(p.room_code); end if;
end $$;

-- 화면을 닫거나 새로고침하거나 다른 앱으로 갈 때.
-- 방을 건드려 진행자 화면이 인원을 바로 다시 세게 한다.
create or replace function play_leave(p_token uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_room text;
begin
  update players set connected = false, moving = false
   where id = (select player_id from player_secrets where token = p_token)
   returning room_code into v_room;
  if v_room is not null then perform hq_touch(v_room); end if;
end $$;

-- 인원(count)과 연결 표시(connected)를 hq_live 로 센다. 나머지는 0003 과 같다.
create or replace function get_snapshot(p_code text, p_player_token uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_room rooms%rowtype; v_round jsonb; v_reveal boolean;
  v_players jsonb; v_live int; v_you jsonb; v_pid uuid; v_lvl levels%rowtype; v_prev jsonb;
begin
  select * into v_room from rooms where code = p_code;
  if not found then return null; end if;
  select rs.round into v_round from room_secrets rs where rs.code = p_code;
  select * into v_lvl from levels where key = v_room.level;
  v_reveal := v_room.phase in ('reveal', 'final');

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'name', p.name, 'color', p.color, 'score', p.score,
           'connected', hq_live(p), 'pending', p.pending, 'locked', p.locked_at is not null
         ) order by p.joined_at), '[]'::jsonb)
    into v_players from players p where p.room_code = p_code;
  select count(*) into v_live from players p where p.room_code = p_code and hq_live(p);

  if p_player_token is not null then
    select ps.player_id into v_pid from player_secrets ps
      join players pl on pl.id = ps.player_id
     where ps.token = p_player_token and pl.room_code = p_code;
    if v_pid is not null then
      select jsonb_build_object(
        'id', pl.id, 'name', pl.name, 'color', pl.color, 'score', pl.score,
        'pending', pl.pending, 'hintUsed', pl.hint_used, 'locked', pl.locked_at is not null,
        'answered', a.player_id is not null, 'correct', a.correct, 'picked', a.picked,
        'typed', pl.typed,
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
    'count', v_live,                       -- 지금 들어와 있는 학생만 센다
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

revoke execute on function hq_live(players) from public;
revoke execute on function play_ping(uuid) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function hq_live(players) from anon, authenticated;
    grant execute on function play_ping(uuid) to anon, authenticated;
    grant execute on function play_leave(uuid) to anon, authenticated;
    grant execute on function get_snapshot(text, uuid) to anon, authenticated;
  end if;
end $$;
