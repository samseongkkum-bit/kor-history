-- 한옥 마당 한국사 퀴즈 — Supabase 설치용 전체 SQL
-- Supabase 대시보드 → SQL Editor 에 이 파일 전체를 붙여넣고 Run 하세요.
-- 여러 번 실행해도 괜찮습니다(문제는 지우고 다시 넣습니다).
-- 이 파일은 scripts/build-sql.mjs 가 만듭니다. 직접 고치지 말고 supabase/migrations/ 를 고치세요.



-- ======================================================
-- 0001_schema.sql
-- ======================================================

-- 한옥 마당 한국사 퀴즈 — 표
--
-- 권한 규칙
--   · 모든 표에 RLS를 켜고, 손님(anon)에게는 "보여도 되는 것"만 읽기를 허용한다.
--   · 쓰기는 전부 막고 RPC 함수(security definer)로만 한다.
--   · 정답·해설·힌트·진행자 열쇠·학생 열쇠는 따로 떼어 둔 표에 두어 아예 읽히지 않게 한다.

create extension if not exists pgcrypto;

/* ---------------- 단계와 문제 ---------------- */

create table if not exists levels (
  key    text primary key,
  name   text not null,
  kind   text not null,
  descr  text not null,
  sort   int  not null default 0
);

-- 문제는 손님이 읽을 수 없다. 문제 문구는 RPC가 마감 전에는 정답을 빼고 돌려준다.
create table if not exists questions (
  level    text not null references levels(key) on delete cascade,
  idx      int  not null,                                   -- 단계 안에서의 번호(0부터)
  type     text not null check (type in ('ox','mc')),
  q        text not null,
  choices  jsonb,                                           -- 객관식일 때 보기 4개
  answer   text not null,                                   -- ox: 'O'/'X' · mc: '0'~'3'
  hint     text not null,
  explain  text not null,
  primary key (level, idx),
  constraint mc_has_four_choices check (
    type <> 'mc' or (jsonb_typeof(choices) = 'array' and jsonb_array_length(choices) = 4)
  ),
  constraint answer_shape check (
    (type = 'ox' and answer in ('O','X')) or (type = 'mc' and answer in ('0','1','2','3'))
  )
);

/* ---------------- 방 ---------------- */

-- 손님이 읽어도 되는 부분. 화면은 이 표의 변화를 Realtime 으로 구독한다.
create table if not exists rooms (
  code        text primary key,
  level       text not null default 'elem' references levels(key),
  phase       text not null default 'lobby' check (phase in ('lobby','question','reveal','final')),
  q_index     int  not null default -1,
  q_total     int  not null default 10,
  started_at  timestamptz,
  ends_at     timestamptz,
  graded_index int not null default -1,          -- 몇 번 문제까지 채점했는지(두 번 채점하지 않으려고)
  created_at  timestamptz not null default now(),
  last_seen   timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
-- 강제 종료하면 새 방을 연다. 새 방은 어느 방에서 이어졌는지 기억한다(이전 학생을 다시 초대하려고).
-- 옛 방이 정리되면 고리도 끊긴다(같은 번호가 다른 방에 다시 쓰여도 엉뚱한 학생을 부르지 않게).
alter table rooms add column if not exists prev_code text references rooms(code) on delete set null;

-- 손님이 읽으면 안 되는 부분(정답이 들어 있는 이번 판 문제 목록, 진행자 열쇠)
create table if not exists room_secrets (
  code        text primary key references rooms(code) on delete cascade,
  host_token  uuid not null default gen_random_uuid(),
  round       jsonb not null default '[]'::jsonb,
  used        jsonb not null default '{}'::jsonb
);

/* ---------------- 학생 ---------------- */

create table if not exists players (
  id         uuid primary key default gen_random_uuid(),
  room_code  text not null references rooms(code) on delete cascade,
  name       text not null,
  color      text not null default 'red',
  score      int  not null default 0,
  bonus      numeric not null default 0,         -- 빠르기 보너스(순위 동점 처리에만 씀)
  pos_x      double precision not null default 480,
  pos_y      double precision not null default 540,
  pos_at     timestamptz not null default now(),
  moving     boolean not null default false,
  pending    boolean not null default false,     -- 문제 도중에 들어와서 이번 문제는 쉬는 중
  hint_used  boolean not null default false,
  locked_x   double precision,
  locked_y   double precision,
  locked_at  timestamptz,
  connected  boolean not null default true,
  joined_at  timestamptz not null default now(),
  last_seen  timestamptz not null default now(),
  unique (room_code, name)
);
-- 진행자가 새 방으로 다시 부른 학생: invited_to = 새 방 코드, moved = 초대를 받아 옮겨 갔음
alter table players add column if not exists invited_to text references rooms(code) on delete set null;
alter table players add column if not exists moved boolean not null default false;
create index if not exists players_room_idx on players(room_code);

-- 학생 열쇠(이 기기가 그 학생이라는 증표). 손님이 읽으면 남의 캐릭터를 움직일 수 있으므로 떼어 둔다.
create table if not exists player_secrets (
  player_id uuid primary key references players(id) on delete cascade,
  token     uuid not null unique default gen_random_uuid()
);

/* ---------------- 답과 기록 ---------------- */

create table if not exists answers (
  room_code text not null references rooms(code) on delete cascade,
  q_index   int  not null,
  player_id uuid not null references players(id) on delete cascade,
  picked    text,                                 -- null = 어느 자리에도 서 있지 않았음
  correct   boolean not null,
  bonus     numeric not null default 0,
  primary key (room_code, q_index, player_id)
);

-- 부스 보고서용. 이름 같은 개인정보는 남기지 않는다.
create table if not exists participation (
  id         bigserial primary key,
  at         timestamptz not null default now(),
  day        date not null default current_date,
  level      text not null,
  level_name text not null,
  players    int  not null,
  questions  int  not null,
  avg_score  numeric not null
);
create index if not exists participation_day_idx on participation(day);

/* ---------------- 권한 ---------------- */

alter table levels         enable row level security;
alter table questions      enable row level security;
alter table rooms          enable row level security;
alter table room_secrets   enable row level security;
alter table players        enable row level security;
alter table player_secrets enable row level security;
alter table answers        enable row level security;
alter table participation  enable row level security;

-- 읽기를 허용하는 것: 단계 목록, 방의 겉 상태, 학생의 겉 정보.
-- (정책을 만들지 않은 표는 손님이 아무것도 할 수 없다 = questions / room_secrets / player_secrets / answers / participation)
drop policy if exists levels_read on levels;
create policy levels_read on levels for select using (true);

drop policy if exists rooms_read on rooms;
create policy rooms_read on rooms for select using (true);

drop policy if exists players_read on players;
create policy players_read on players for select using (true);

-- 쓰기 정책은 하나도 만들지 않는다. 모든 변경은 RPC 함수(security definer)를 거친다.

/* ---------------- Realtime ---------------- */
-- 화면은 rooms 표의 변화(단계가 바뀌는 순간)만 구독한다.
-- 위치는 Realtime Broadcast 로 주고받으므로 표에 싣지 않는다(무료 한도를 아끼려고).
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin
      alter publication supabase_realtime add table rooms;
    exception when duplicate_object then null;
    end;
  end if;
end $$;

alter table rooms replica identity full;


-- ======================================================
-- 0002_geometry.sql
-- ======================================================

-- 마당 좌표와 출제 로직. public/shared/map.js · consts.js 와 같은 값을 쓴다.
-- 채점이 화면과 어긋나지 않도록 구역 판정은 여기(서버)에서만 한다.

-- 마당: x 40~920, y 96~576 / 캐릭터가 설 수 있는 범위는 안쪽으로 조금 좁다
create or replace function hq_clamp_x(x double precision) returns double precision
language sql immutable as $$ select greatest(60::double precision, least(900::double precision, coalesce(x, 480))) $$;

create or replace function hq_clamp_y(y double precision) returns double precision
language sql immutable as $$ select greatest(136::double precision, least(546::double precision, coalesce(y, 540))) $$;

-- 서 있는 돗자리. 없으면 null.
-- O/X : O(90,170,340,300)  X(530,170,340,300)
-- 객관식: (90,150) (530,150) (90,320) (530,320) 각 340x140
create or replace function hq_zone_at(p_type text, x double precision, y double precision)
returns text language sql immutable as $$
  select case
    when x is null or y is null then null
    when p_type = 'ox' then
      case
        when x between 90  and 430 and y between 170 and 470 then 'O'
        when x between 530 and 870 and y between 170 and 470 then 'X'
      end
    else
      case
        when x between 90  and 430 and y between 150 and 290 then '0'
        when x between 530 and 870 and y between 150 and 290 then '1'
        when x between 90  and 430 and y between 320 and 460 then '2'
        when x between 530 and 870 and y between 320 and 460 then '3'
      end
  end
$$;

-- 문제당 제한 시간: O/X 12초, 객관식 20초
create or replace function hq_seconds(p_type text) returns int
language sql immutable as $$ select case when p_type = 'mc' then 20 else 12 end $$;

-- 칭호(10점 만점)
create or replace function hq_title(p_score int) returns text
language sql immutable as $$
  select case
    when p_score >= 10 then '왕'
    when p_score >= 9  then '조선의 학자'
    when p_score >= 7  then '귀족'
    when p_score >= 5  then '평민'
    when p_score >= 3  then '양민'
    else '천민'
  end
$$;

create or replace function hq_title_say(p_score int) returns text
language sql immutable as $$
  select case
    when p_score >= 10 then '모두 맞혔어요! 오늘 부스의 임금님이에요.'
    when p_score >= 9  then '거의 다 맞혔어요! 집현전 학자도 놀랄 실력이에요.'
    when p_score >= 7  then '대단해요! 역사 이야기를 많이 알고 있네요.'
    when p_score >= 5  then '절반 넘게 맞혔어요! 우리 역사와 꽤 친해졌어요.'
    when p_score >= 3  then '조금씩 알아가고 있어요. 해설을 다시 읽어 보면 더 잘할 수 있어요.'
    else '이제 막 역사 여행을 시작했어요. 다시 풀면 금방 올라갈 수 있어요!'
  end
$$;

-- 정답을 사람이 읽는 말로
create or replace function hq_answer_label(p_type text, p_answer text, p_choices jsonb)
returns text language sql immutable as $$
  select case
    when p_type = 'ox' then case when p_answer = 'O' then '○ (맞아요)' else '× (아니에요)' end
    else (array['①','②','③','④'])[p_answer::int + 1] || ' ' || (p_choices ->> p_answer::int)
  end
$$;

-- 한 판에 쓸 10문제를 뽑는다.
-- 30문제를 한 바퀴 다 돌 때까지 같은 문제가 다시 나오지 않고, 객관식은 보기 순서도 섞는다.
-- (단일 파일 버전의 buildRound 와 같은 규칙)
create or replace function hq_build_round(p_level text, p_used jsonb)
returns jsonb language plpgsql as $$
declare
  v_used  int[];
  v_fresh int[];
  v_fill  int[];
  v_ids   int[];
  v_need  int;
  v_new_used int[];
  v_round jsonb := '[]'::jsonb;
  v_order int[];
  v_choices jsonb;
  v_answer text;
  r questions%rowtype;
  i int;
begin
  select coalesce(array_agg(value::int), '{}'::int[]) into v_used
    from jsonb_array_elements_text(coalesce(p_used -> p_level, '[]'::jsonb));

  select coalesce(array_agg(idx order by random()), '{}'::int[]) into v_fresh
    from questions where level = p_level and not (idx = any(v_used));

  if coalesce(array_length(v_fresh, 1), 0) >= 10 then
    v_ids := v_fresh[1:10];
    v_new_used := v_used || v_ids;
  else
    v_need := 10 - coalesce(array_length(v_fresh, 1), 0);
    select coalesce(array_agg(idx order by random()), '{}'::int[]) into v_fill
      from questions where level = p_level and not (idx = any(v_fresh));
    v_fill := v_fill[1:v_need];
    select coalesce(array_agg(x order by random()), '{}'::int[]) into v_ids
      from unnest(v_fresh || v_fill) x;
    v_new_used := v_fill;
  end if;

  foreach i in array v_ids loop
    select * into r from questions where level = p_level and idx = i;
    if r.type = 'mc' then
      select array_agg(k order by random()) into v_order from generate_series(0, 3) k;
      select jsonb_agg(r.choices -> v_order[n] order by n) into v_choices from generate_series(1, 4) n;
      select (n - 1)::text into v_answer from generate_series(1, 4) n where v_order[n] = r.answer::int;
    else
      v_choices := null;
      v_answer  := r.answer;
    end if;
    v_round := v_round || jsonb_build_object(
      'src', i, 'type', r.type, 'q', r.q, 'choices', v_choices,
      'answer', v_answer, 'hint', r.hint, 'explain', r.explain);
  end loop;

  return jsonb_build_object(
    'round', v_round,
    'used',  jsonb_set(coalesce(p_used, '{}'::jsonb), array[p_level], to_jsonb(v_new_used))
  );
end $$;


-- ======================================================
-- 0003_rpc.sql
-- ======================================================

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


-- ======================================================
-- 0004_seed_questions.sql
-- ======================================================

-- data/questions.json 에서 자동으로 만든 파일입니다. 직접 고치지 말고
-- data/questions.json 을 고친 뒤 `npm run seed` 를 실행하세요.

delete from questions;
delete from levels;

insert into levels(key, name, kind, descr, sort) values
  ('elem', '초등부', 'O/X 퀴즈', '태극기, 한글, 명절처럼 생활 속에서 만나는 우리 역사', 0),
  ('mid', '중등부', '객관식 + O/X', '고조선부터 임시 정부까지, 시대 순서로 따라가는 한국사', 1);

insert into questions(level, idx, type, q, choices, answer, hint, explain) values
  ('elem', 0, 'ox', '우리나라 국기의 이름은 ''태극기''이다.', null, 'O', '가운데에 빨간색과 파란색 동그라미가 있어요.', '태극기는 가운데 태극 무늬와 네 귀퉁이의 검은 막대(4괘)로 이루어져 있어요.'),
  ('elem', 1, 'ox', '한글을 만든 왕은 세종대왕이다.', null, 'O', '10월 9일 한글날과 관련 있는 왕이에요.', '세종대왕은 백성이 쉽게 글을 쓰도록 훈민정음(한글)을 만들었어요.'),
  ('elem', 2, 'ox', '우리나라의 나라꽃은 해바라기이다.', null, 'X', '''끝없이 피고 또 핀다''는 뜻의 이름을 가진 꽃이에요.', '우리나라의 나라꽃은 무궁화예요.'),
  ('elem', 3, 'ox', '광복절은 3월 1일이다.', null, 'X', '여름방학 즈음에 있는 기념일이에요.', '광복절은 8월 15일이에요. 3월 1일은 삼일절이에요.'),
  ('elem', 4, 'ox', '설날에는 송편을 먹는다.', null, 'X', '설날 음식을 먹으면 한 살 더 먹는다고 해요.', '설날에는 떡국을 먹어요. 송편은 추석에 먹는 음식이에요.'),
  ('elem', 5, 'ox', '옛날 집에서 방바닥을 따뜻하게 데우던 방법을 ''온돌''이라고 한다.', null, 'O', '아궁이에 불을 때면 방바닥이 뜨끈해져요.', '온돌은 아궁이의 열기가 방바닥 아래로 지나가며 방을 데우는 우리 고유의 난방법이에요.'),
  ('elem', 6, 'ox', '독도는 우리나라 땅이다.', null, 'O', '동해에 있는 섬이에요.', '독도는 경상북도 울릉군에 속한 우리나라 섬이에요.'),
  ('elem', 7, 'ox', '거북선을 이끌고 바다에서 왜군과 싸운 장군은 강감찬이다.', null, 'X', '광화문 광장에 동상이 있는 장군이에요.', '거북선으로 왜군을 물리친 장군은 이순신이에요. 강감찬은 고려 때 거란군을 물리쳤어요.'),
  ('elem', 8, 'ox', '우리나라의 나라 노래(국가)는 ''아리랑''이다.', null, 'X', '"동해 물과 백두산이~"로 시작해요.', '우리나라의 국가는 애국가예요.'),
  ('elem', 9, 'ox', '경주에 있는 첨성대는 옛날에 별을 관찰하던 곳이다.', null, 'O', '이름에 ''별(星)''이라는 글자가 들어 있어요.', '첨성대는 신라 시대에 하늘과 별을 관찰하던 천문대예요.'),
  ('elem', 10, 'ox', '추석은 음력 8월 15일이다.', null, 'O', '일 년 중 보름달이 가장 크고 둥글게 뜨는 날이에요.', '추석은 음력 8월 15일로, 햇곡식과 송편으로 차례를 지내요.'),
  ('elem', 11, 'ox', '한글날은 8월 15일이다.', null, 'X', '가을, 10월에 있는 기념일이에요.', '한글날은 10월 9일이에요. 8월 15일은 광복절이에요.'),
  ('elem', 12, 'ox', '우리나라의 전통 옷은 ''기모노''이다.', null, 'X', '설날이나 추석에 곱게 차려입는 옷이에요.', '우리나라의 전통 옷은 한복이에요. 기모노는 일본의 전통 옷이에요.'),
  ('elem', 13, 'ox', '김치는 배추나 무 같은 채소를 소금에 절여 양념해 만든 음식이다.', null, 'O', '겨울을 앞두고 온 가족이 모여 ''김장''을 해요.', '김치는 채소를 절이고 양념해 발효시킨 우리 고유의 음식이에요.'),
  ('elem', 14, 'ox', '조선의 수도 한양은 지금의 서울이다.', null, 'O', '경복궁이 있는 도시를 떠올려 보세요.', '이성계는 조선을 세운 뒤 수도를 한양으로 옮겼고, 한양이 지금의 서울이에요.'),
  ('elem', 15, 'ox', '고조선을 세운 사람은 주몽이다.', null, 'X', '곰이 사람이 되었다는 이야기와 관련 있어요.', '고조선은 단군왕검이 세웠어요. 주몽은 고구려를 세웠어요.'),
  ('elem', 16, 'ox', '윷놀이는 주사위 여섯 개를 던져서 하는 놀이이다.', null, 'X', '''도, 개, 걸, 윷, 모''를 떠올려 보세요.', '윷놀이는 나무 막대 네 개(윷가락)를 던져서 하는 놀이예요.'),
  ('elem', 17, 'ox', '세종대왕 때 장영실이 해시계와 물시계를 만들었다.', null, 'O', '장영실은 세종대왕이 아낀 과학자예요.', '장영실은 해시계 앙부일구와 저절로 시간을 알리는 물시계 자격루를 만들었어요.'),
  ('elem', 18, 'ox', '옛날 사람들이 짚으로 엮어 신던 신발을 ''짚신''이라고 한다.', null, 'O', '신발 이름에 재료가 그대로 들어 있어요.', '짚신은 볏짚을 엮어 만든 신발로, 옛날 사람들이 흔히 신었어요.'),
  ('elem', 19, 'ox', '경복궁은 신라의 궁궐이다.', null, 'X', '서울 광화문 뒤에 있는 궁궐이에요.', '경복궁은 조선을 세운 뒤 한양에 지은 조선의 궁궐이에요.'),
  ('elem', 20, 'ox', '삼일절 같은 국경일에는 집집마다 태극기를 단다.', null, 'O', '나라의 기쁜 날을 함께 기념하는 방법이에요.', '삼일절, 광복절, 개천절, 한글날 같은 국경일에는 태극기를 달아요.'),
  ('elem', 21, 'ox', '만 원짜리 지폐에 그려진 인물은 이순신이다.', null, 'X', '한글을 만든 왕이에요.', '만 원짜리 지폐에는 세종대왕이 그려져 있어요. 이순신은 백 원짜리 동전에 있어요.'),
  ('elem', 22, 'ox', '유관순은 3·1 운동 때 만세를 외친 독립운동가이다.', null, 'O', '태극기를 나눠 주며 아우내 장터에서 만세를 불렀어요.', '유관순은 고향 천안 아우내 장터에서 만세 운동을 이끈 독립운동가예요.'),
  ('elem', 23, 'ox', '탈을 쓰고 춤추며 이야기를 펼치는 놀이를 ''탈춤''이라고 한다.', null, 'O', '얼굴에 쓰는 것을 ''탈''이라고 해요.', '탈춤은 탈을 쓰고 춤과 노래, 이야기로 웃음을 주던 우리 전통 놀이예요.'),
  ('elem', 24, 'ox', '지붕을 기와로 덮은 집을 ''초가집''이라고 한다.', null, 'X', '초가집의 지붕은 볏짚으로 덮어요.', '기와로 덮은 집은 기와집이에요. 볏짚으로 지붕을 덮은 집이 초가집이에요.'),
  ('elem', 25, 'ox', '거북선은 배 위를 덮개로 덮어 적의 공격을 막은 배이다.', null, 'O', '거북의 등딱지를 닮았어요.', '거북선은 등을 덮개로 덮고 뾰족한 쇠못을 꽂아 적이 올라오지 못하게 했어요.'),
  ('elem', 26, 'ox', '한글을 처음 만들었을 때의 이름은 ''훈민정음''이다.', null, 'O', '''백성을 가르치는 바른 소리''라는 뜻이에요.', '세종대왕은 한글을 만들고 훈민정음이라는 이름을 붙였어요.'),
  ('elem', 27, 'ox', '다보탑과 석가탑은 경주 불국사에 있다.', null, 'O', '신라의 수도였던 도시에 있는 절이에요.', '다보탑과 석가탑은 신라 때 세운 탑으로, 경주 불국사에 나란히 서 있어요.'),
  ('elem', 28, 'ox', '동짓날에는 송편을 먹는다.', null, 'X', '빨간 팥으로 만든 음식이 나쁜 기운을 쫓는다고 믿었어요.', '동짓날에는 팥죽을 먹어요. 송편은 추석 음식이에요.'),
  ('elem', 29, 'ox', '강강술래는 혼자서 추는 춤이다.', null, 'X', '보름달 아래에서 여럿이 손을 잡아요.', '강강술래는 여러 사람이 손을 잡고 둥글게 돌며 노래하고 춤추는 놀이예요.'),
  ('mid', 0, 'mc', '우리 역사에서 처음 세워진 나라는?', '["고구려","고조선","신라","가야"]'::jsonb, '1', '단군 이야기와 관련 있어요.', '고조선은 단군왕검이 세운 우리 역사 최초의 국가예요.'),
  ('mid', 1, 'ox', '고구려·백제·신라가 함께 있던 시대를 ''삼국 시대''라고 한다.', null, 'O', '나라가 몇 개였는지 세어 보세요.', '세 나라가 경쟁하며 발전한 시대를 삼국 시대라고 불러요.'),
  ('mid', 2, 'mc', '고구려의 영토를 크게 넓혀 이름에 ''땅을 넓혔다''는 뜻이 담긴 왕은?', '["광개토대왕","세종대왕","태조 왕건","정조"]'::jsonb, '0', '이름에 ''넓을 광(廣)'', ''열 개(開)'', ''땅 토(土)''가 들어가요.', '광개토대왕은 만주와 한반도 북부까지 영토를 크게 넓혔어요.'),
  ('mid', 3, 'ox', '고려를 세운 사람은 이성계이다.', null, 'X', '이성계는 고려 다음 나라를 세웠어요.', '고려를 세운 사람은 왕건이고, 이성계는 조선을 세웠어요.'),
  ('mid', 4, 'mc', '고려 시대에 만들어져 지금 해인사에 보관된 불교 경판은?', '["팔만대장경","훈민정음 해례본","직지심체요절","조선왕조실록"]'::jsonb, '0', '나무판이 무려 8만 장이 넘어요.', '팔만대장경은 부처의 힘으로 몽골의 침입을 막고자 하는 바람을 담아 만들었어요.'),
  ('mid', 5, 'ox', '『직지심체요절』은 현재 남아 있는 세계에서 가장 오래된 금속 활자 인쇄본이다.', null, 'O', '고려는 금속 활자 기술이 뛰어났어요.', '직지는 고려 때 금속 활자로 찍은 책으로, 유네스코 세계기록유산이에요.'),
  ('mid', 6, 'mc', '임진왜란 때 한산도 대첩을 승리로 이끈 장군은?', '["강감찬","을지문덕","이순신","김유신"]'::jsonb, '2', '거북선과 함께 기억되는 장군이에요.', '이순신은 학이 날개를 편 모양의 학익진 전법으로 한산도에서 왜군을 크게 이겼어요.'),
  ('mid', 7, 'ox', '수원 화성을 쌓을 때 정약용이 고안한 거중기가 쓰였다.', null, 'O', '무거운 돌을 적은 힘으로 들어 올리는 기계예요.', '거중기 덕분에 공사 기간과 비용을 크게 줄일 수 있었어요.'),
  ('mid', 8, 'mc', '1919년 일제에 맞서 전국에서 일어난 만세 운동은?', '["3·1 운동","동학 농민 운동","4·19 혁명","6·25 전쟁"]'::jsonb, '0', '이 운동을 기념하는 날이 국경일이에요.', '3·1 운동은 민족 전체가 독립 의지를 세계에 알린 운동이에요.'),
  ('mid', 9, 'ox', '대한민국 임시 정부는 서울에 세워졌다.', null, 'X', '일제의 감시를 피해 다른 나라에 세웠어요.', '대한민국 임시 정부는 1919년 중국 상하이에 세워졌어요.'),
  ('mid', 10, 'mc', '고구려를 세운 사람은?', '["주몽","온조","박혁거세","김수로"]'::jsonb, '0', '활을 아주 잘 쏘았다고 전해져요.', '주몽은 고구려를 세웠어요. 온조는 백제, 박혁거세는 신라, 김수로는 가야를 세웠어요.'),
  ('mid', 11, 'ox', '백제를 세운 사람은 온조이다.', null, 'O', '온조는 주몽의 아들이라고 전해져요.', '온조는 한강 근처에 백제를 세웠어요.'),
  ('mid', 12, 'mc', '신라가 삼국을 통일하는 데 큰 역할을 한 장군은?', '["김유신","계백","을지문덕","연개소문"]'::jsonb, '0', '신라 사람이에요. 나머지는 백제와 고구려 사람이에요.', '김유신은 김춘추(태종 무열왕)와 함께 삼국 통일을 이끌었어요.'),
  ('mid', 13, 'ox', '살수 대첩에서 수나라 군대를 물리친 장군은 강감찬이다.', null, 'X', '살수 대첩은 고구려 때 일어난 싸움이에요.', '살수 대첩을 이끈 장군은 고구려의 을지문덕이에요. 강감찬은 고려 때 귀주 대첩을 이끌었어요.'),
  ('mid', 14, 'mc', '고구려가 멸망한 뒤 대조영이 세운 나라는?', '["발해","후백제","가야","동예"]'::jsonb, '0', '''해동성국(바다 동쪽의 번성한 나라)''이라고 불렸어요.', '대조영은 고구려 사람들을 모아 발해를 세웠어요.'),
  ('mid', 15, 'ox', '귀주 대첩에서 거란군을 크게 물리친 장군은 강감찬이다.', null, 'O', '고려 때 거란이 여러 번 쳐들어왔어요.', '강감찬은 1019년 귀주에서 거란군을 크게 물리쳤어요.'),
  ('mid', 16, 'mc', '고려 시대에 만들어진, 푸른빛이 도는 아름다운 도자기는?', '["고려청자","백자","분청사기","빗살무늬 토기"]'::jsonb, '0', '이름에 나라 이름과 색깔이 들어 있어요.', '고려청자는 맑은 푸른빛과 상감 기법으로 세계적으로 이름난 도자기예요.'),
  ('mid', 17, 'ox', '조선의 수도는 개경이었다.', null, 'X', '개경은 조선 이전 나라의 수도예요.', '조선의 수도는 한양(지금의 서울)이에요. 개경은 고려의 수도였어요.'),
  ('mid', 18, 'mc', '세종 때 만들어져 비가 내린 양을 재던 기구는?', '["측우기","거중기","혼천의","앙부일구"]'::jsonb, '0', '이름에 ''비 우(雨)'' 자가 들어 있어요.', '측우기 덕분에 전국의 비 내린 양을 재서 농사에 활용할 수 있었어요.'),
  ('mid', 19, 'ox', '『조선왕조실록』은 고려 시대에 만들어졌다.', null, 'X', '책 이름에 나라 이름이 들어 있어요.', '『조선왕조실록』은 조선 왕들의 일을 기록한 책으로, 유네스코 세계기록유산이에요.'),
  ('mid', 20, 'mc', '임진왜란이 일어난 해는?', '["1392년","1592년","1636년","1910년"]'::jsonb, '1', '조선이 세워지고 약 200년 뒤예요.', '임진왜란은 1592년 일본이 조선에 쳐들어오면서 시작되었어요.'),
  ('mid', 21, 'ox', '병자호란 때 인조는 남한산성으로 피란했다.', null, 'O', '서울 남쪽 경기도 광주에 있는 산성이에요.', '1636년 청나라가 쳐들어오자 인조는 남한산성에서 버티다가 결국 항복했어요.'),
  ('mid', 22, 'mc', '『목민심서』를 쓴 조선 후기의 실학자는?', '["정약용","이황","이이","김정호"]'::jsonb, '0', '거중기를 고안한 사람이에요.', '정약용은 백성을 다스리는 관리의 바른 자세를 『목민심서』에 담았어요.'),
  ('mid', 23, 'ox', '「대동여지도」를 만든 사람은 정약용이다.', null, 'X', '평생 지도를 만든 사람으로 알려져 있어요.', '「대동여지도」는 김정호가 만든 우리나라 지도예요.'),
  ('mid', 24, 'mc', '1894년 전봉준이 이끈 농민들의 봉기는?', '["동학 농민 운동","3·1 운동","갑신정변","임오군란"]'::jsonb, '0', '''사람이 곧 하늘''이라고 가르친 종교와 관련 있어요.', '동학 농민 운동은 탐관오리와 외세에 맞서 농민들이 일어난 운동이에요.'),
  ('mid', 25, 'ox', '안중근은 하얼빈에서 이토 히로부미를 처단했다.', null, 'O', '1909년 중국의 한 기차역에서 일어난 일이에요.', '안중근은 1909년 하얼빈역에서 침략의 우두머리 이토 히로부미를 처단했어요.'),
  ('mid', 26, 'mc', '우리나라가 일제로부터 광복을 맞은 해는?', '["1919년","1945년","1948년","1950년"]'::jsonb, '1', '제2차 세계 대전이 끝난 해예요.', '우리나라는 1945년 8월 15일 광복을 맞았어요.'),
  ('mid', 27, 'ox', '6·25 전쟁은 1945년에 시작되었다.', null, 'X', '광복을 맞고 몇 년 뒤의 일이에요.', '6·25 전쟁은 1950년 6월 25일에 시작되었어요.'),
  ('mid', 28, 'mc', '흥선 대원군이 왕실의 힘을 높이려고 다시 지은 궁궐은?', '["경복궁","창덕궁","덕수궁","경희궁"]'::jsonb, '0', '임진왜란 때 불타 오랫동안 비어 있던 조선의 첫 궁궐이에요.', '흥선 대원군은 임진왜란 때 불탄 경복궁을 다시 지었어요.'),
  ('mid', 29, 'ox', '이황과 이이는 조선의 이름난 학자로, 지금 지폐에도 얼굴이 실려 있다.', null, 'O', '천 원과 오천 원짜리 지폐를 떠올려 보세요.', '천 원짜리에는 이황, 오천 원짜리에는 이이가 그려져 있어요.');
