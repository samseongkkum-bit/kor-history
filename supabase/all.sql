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
  type     text not null,                                   -- ox: O/X · mc: 객관식 · sa: 주관식
  q        text not null,
  choices  jsonb,                                           -- 객관식일 때 보기 4개
  answer   text not null,                                   -- ox: 'O'/'X' · mc: '0'~'3' · sa: 정답 낱말
  hint     text not null,
  explain  text not null,
  primary key (level, idx),
  constraint mc_has_four_choices check (
    type <> 'mc' or (jsonb_typeof(choices) = 'array' and jsonb_array_length(choices) = 4)
  )
);
-- 주관식: 정답 말고도 맞다고 쳐 줄 다른 이름들(예: 광개토대왕 → 광개토왕)
alter table questions add column if not exists accept jsonb;
-- 문제 종류와 정답 모양. 이미 만들어 둔 표에도 주관식(sa)이 들어가도록 다시 건다.
alter table questions drop constraint if exists questions_type_check;
alter table questions add constraint questions_type_check check (type in ('ox','mc','sa'));
alter table questions drop constraint if exists answer_shape;
alter table questions add constraint answer_shape check (
  (type = 'ox' and answer in ('O','X')) or (type = 'mc' and answer in ('0','1','2','3'))
  or (type = 'sa' and btrim(answer) <> '')
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
-- 주관식 문제에 학생이 써 둔 답(이번 문제 것만. 다음 문제로 넘어가면 비운다)
alter table players add column if not exists typed text;
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
  picked    text,                                 -- null = 어느 자리에도 서 있지 않았음(주관식은 써 낸 답)
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

-- 문제당 제한 시간: O/X 22초, 객관식 30초, 주관식 40초(폰으로 글자를 쳐야 하니까)
create or replace function hq_seconds(p_type text) returns int
language sql immutable as $$ select case when p_type = 'mc' then 30 when p_type = 'sa' then 40 else 22 end $$;

-- 주관식 답 비교용으로 다듬는다: 띄어쓰기·가운뎃점·괄호·따옴표 같은 것은 빼고, '1592년'과 '1592'는 같게 본다.
-- public/solo/index.html 의 normAnswer 와 같은 규칙.
create or replace function hq_norm(p text) returns text
language sql immutable as $$
  select regexp_replace(
           regexp_replace(lower(coalesce(p, '')), '[][[:space:]·ㆍ.,''"‘’“”()（）『』「」<>《》〈〉!?~-]', '', 'g'),
           '([0-9])년$', '\1')
$$;

-- 주관식 채점: 정답이나 함께 인정하는 이름 중 하나와 같으면 맞다.
create or replace function hq_sa_correct(p_typed text, p_answer text, p_accept jsonb) returns boolean
language sql immutable as $$
  select hq_norm(p_typed) <> '' and hq_norm(p_typed) in (
    select hq_norm(p_answer)
    union all
    select hq_norm(x) from jsonb_array_elements_text(coalesce(p_accept, '[]'::jsonb)) x
  )
$$;

-- 한 문제 맞히면 받는 점수(10문제 100점 만점)
create or replace function hq_points() returns int
language sql immutable as $$ select 10 $$;

-- 저고리 색 목록(public/shared/consts.js 의 COLORS 와 같은 순서·같은 개수). 한 방 최대 인원(30명)만큼 있다.
create or replace function hq_colors() returns text[]
language sql immutable as $$ select array[
  'red','cheong','hwang','pink','purple','sky','navy','green','lime','orange',
  'brown','plum','mint','lav','coral','olive','teal','lemon','rose','blue',
  'meok','gray','peach','wine','forest','cyan','violet','tan','magenta','steel'
] $$;

-- 칭호(100점 만점)
create or replace function hq_title(p_score int) returns text
language sql immutable as $$
  select case
    when p_score >= 100 then '왕'
    when p_score >= 90  then '조선의 학자'
    when p_score >= 70  then '귀족'
    when p_score >= 50  then '평민'
    when p_score >= 30  then '양민'
    else '천민'
  end
$$;

create or replace function hq_title_say(p_score int) returns text
language sql immutable as $$
  select case
    when p_score >= 100 then '모두 맞혔어요! 오늘 부스의 임금님이에요.'
    when p_score >= 90  then '거의 다 맞혔어요! 집현전 학자도 놀랄 실력이에요.'
    when p_score >= 70  then '대단해요! 역사 이야기를 많이 알고 있네요.'
    when p_score >= 50  then '절반 넘게 맞혔어요! 우리 역사와 꽤 친해졌어요.'
    when p_score >= 30  then '조금씩 알아가고 있어요. 해설을 다시 읽어 보면 더 잘할 수 있어요.'
    else '이제 막 역사 여행을 시작했어요. 다시 풀면 금방 올라갈 수 있어요!'
  end
$$;

-- 정답을 사람이 읽는 말로
create or replace function hq_answer_label(p_type text, p_answer text, p_choices jsonb)
returns text language sql immutable as $$
  select case
    when p_type = 'ox' then case when p_answer = 'O' then '○ (맞아요)' else '× (아니에요)' end
    when p_type = 'sa' then p_answer
    else (array['①','②','③','④'])[p_answer::int + 1] || ' ' || (p_choices ->> p_answer::int)
  end
$$;

-- 한 판에 쓸 10문제를 뽑는다.
-- 문제를 한 바퀴 다 돌 때까지 같은 문제가 다시 나오지 않고, 객관식은 보기 순서도 섞는다.
-- 주관식은 함께 인정하는 이름(accept)도 같이 담아 둔다(room_secrets 에만 들어가므로 손님은 못 본다).
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
      'answer', v_answer, 'accept', r.accept, 'hint', r.hint, 'explain', r.explain);
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
    pending = false, hint_used = false, typed = null,
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

    if v_type = 'sa' then
      -- 주관식: 마감 때까지 써 둔 답("답 내기"를 눌렀으면 그때 낸 답)
      v_picked  := nullif(btrim(p.typed), '');
      v_correct := v_picked is not null and hq_sa_correct(v_picked, v_answer, v_q -> 'accept');
    else
      v_picked  := hq_zone_at(v_type, v_x, v_y);
      v_correct := v_picked is not null and v_picked = v_answer;
    end if;
    -- 빠르기 보너스: 점수에는 더하지 않고 순위 동점 처리에만 쓴다
    v_bonus := case when v_correct
      then greatest(0, least(1, extract(epoch from (v_room.ends_at - v_at)) * 1000 / v_total_ms))
      else 0 end;

    insert into answers(room_code, q_index, player_id, picked, correct, bonus)
    values (p_code, v_room.q_index, p.id, v_picked, v_correct, v_bonus)
    on conflict (room_code, q_index, player_id) do nothing;

    if v_correct then
      update players set score = score + hq_points(), bonus = bonus + v_bonus where id = p.id;
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
  v_id uuid; v_new_token uuid; v_base text; v_name text; v_n int; v_count int; v_color text;
begin
  select * into v_room from rooms where code = p_code for update;
  if not found then raise exception '그런 입장 코드가 없어요. 진행자 화면의 숫자를 다시 확인해 주세요.'; end if;

  -- 재접속: 같은 기기(열쇠)면 이름과 점수를 그대로 이어 간다
  if p_token is not null then
    select ps.player_id into v_id from player_secrets ps
      join players pl on pl.id = ps.player_id
     where ps.token = p_token and pl.room_code = p_code;
    if v_id is not null then
      update players set connected = true, last_seen = now() where id = v_id;
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

  -- 저고리 색은 학생이 고르지 않는다. 이 방에서 아직 아무도 안 입은 색 중 하나를 무작위로 준다.
  -- (p_color 는 새 방으로 옮겨 갈 때 입던 색을 이어 입으려는 것. 그 색이 비어 있을 때만 쓴다.)
  -- 방 줄을 for update 로 잡고 있으므로 동시에 들어와도 색이 겹치지 않는다.
  if p_color = any(hq_colors())
     and not exists (select 1 from players where room_code = p_code and color = p_color) then
    v_color := p_color;
  else
    select c into v_color from unnest(hq_colors()) c
     where not exists (select 1 from players where room_code = p_code and color = c)
     order by random() limit 1;
  end if;

  insert into players(room_code, name, color, pending)
  values (p_code, v_name, coalesce(v_color, 'red'), v_room.phase = 'question')
  returning id into v_id;
  insert into player_secrets(player_id) values (v_id) returning token into v_new_token;

  perform hq_touch(p_code);
  return jsonb_build_object('playerId', v_id, 'playerToken', v_new_token, 'rejoined', false,
                            'snapshot', get_snapshot(p_code, v_new_token));
end $$;

-- 초대받은 학생이 새 방으로 옮겨 간다. 이름과 색은 그대로(색이 이미 쓰였으면 새 색), 점수는 새로 시작한다.
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
  if v_type = 'sa' then return jsonb_build_object('ok', false, 'reason', 'type'); end if;   -- 주관식은 play_answer
  v_zone := hq_zone_at(v_type, p.pos_x, p.pos_y);
  if v_zone is null then return jsonb_build_object('ok', false, 'reason', 'zone'); end if;

  update players set locked_x = pos_x, locked_y = pos_y, locked_at = now() where id = p.id;
  return jsonb_build_object('ok', true, 'zone', v_zone);
end $$;

-- 주관식 답을 써 둔다. p_lock 이면 "답 내기" — 그 순간의 시각을 고정하고(빠르기 보너스의 근거) 더는 못 고친다.
-- 답 내기를 누르지 않아도 마감 때 써 둔 답으로 채점한다.
create or replace function play_answer(p_token uuid, p_text text, p_lock boolean default false)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare p players%rowtype; v_room rooms%rowtype; v_type text; v_text text;
begin
  select pl.* into p from players pl join player_secrets ps on ps.player_id = pl.id where ps.token = p_token;
  if not found then return jsonb_build_object('ok', false, 'reason', 'player'); end if;

  select * into v_room from rooms where code = p.room_code;
  if v_room.phase <> 'question' or now() > v_room.ends_at or p.pending or p.locked_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'phase');
  end if;
  select rs.round -> v_room.q_index ->> 'type' into v_type from room_secrets rs where rs.code = p.room_code;
  if v_type is distinct from 'sa' then return jsonb_build_object('ok', false, 'reason', 'type'); end if;

  v_text := nullif(left(btrim(regexp_replace(coalesce(p_text, ''), '\s+', ' ', 'g')), 30), '');
  if p_lock and v_text is null then return jsonb_build_object('ok', false, 'reason', 'empty'); end if;

  update players set typed = v_text, last_seen = now(),
         locked_at = case when p_lock then now() end
   where id = p.id;
  return jsonb_build_object('ok', true, 'locked', p_lock);
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
    'play_lock(uuid,double precision,double precision)', 'play_answer(uuid,text,boolean)',
    'play_hint(uuid)', 'play_leave(uuid)',
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

-- 단계는 지우지 않고 고쳐 쓴다(열려 있는 방이 단계를 가리키고 있어도 다시 실행할 수 있게).
insert into levels(key, name, kind, descr, sort) values
  ('elem', '초등부', 'O/X 퀴즈', '태극기, 한글, 명절처럼 생활 속에서 만나는 우리 역사', 0),
  ('mid', '중등부', '객관식 + O/X', '고조선부터 임시 정부까지, 시대 순서로 따라가는 한국사', 1),
  ('high', '고등부', '주관식', '중등부 객관식 문제를 보기 없이, 답을 직접 써서 풀어요', 2)
on conflict (key) do update set name = excluded.name, kind = excluded.kind, descr = excluded.descr, sort = excluded.sort;
delete from levels l where l.key not in ('elem', 'mid', 'high')
  and not exists (select 1 from rooms r where r.level = l.key);

insert into questions(level, idx, type, q, choices, answer, accept, hint, explain) values
  ('elem', 0, 'ox', '우리나라 국기의 이름은 ''태극기''이다.', null, 'O', null, '가운데에 빨간색과 파란색 동그라미가 있어요.', '태극기는 가운데 태극 무늬와 네 귀퉁이의 검은 막대(4괘)로 이루어져 있어요.'),
  ('elem', 1, 'ox', '한글을 만든 왕은 세종대왕이다.', null, 'O', null, '10월 9일 한글날과 관련 있는 왕이에요.', '세종대왕은 백성이 쉽게 글을 쓰도록 훈민정음(한글)을 만들었어요.'),
  ('elem', 2, 'ox', '우리나라의 나라꽃은 해바라기이다.', null, 'X', null, '''끝없이 피고 또 핀다''는 뜻의 이름을 가진 꽃이에요.', '우리나라의 나라꽃은 무궁화예요.'),
  ('elem', 3, 'ox', '광복절은 3월 1일이다.', null, 'X', null, '여름방학 즈음에 있는 기념일이에요.', '광복절은 8월 15일이에요. 3월 1일은 삼일절이에요.'),
  ('elem', 4, 'ox', '설날에는 송편을 먹는다.', null, 'X', null, '설날 음식을 먹으면 한 살 더 먹는다고 해요.', '설날에는 떡국을 먹어요. 송편은 추석에 먹는 음식이에요.'),
  ('elem', 5, 'ox', '옛날 집에서 방바닥을 따뜻하게 데우던 방법을 ''온돌''이라고 한다.', null, 'O', null, '아궁이에 불을 때면 방바닥이 뜨끈해져요.', '온돌은 아궁이의 열기가 방바닥 아래로 지나가며 방을 데우는 우리 고유의 난방법이에요.'),
  ('elem', 6, 'ox', '독도는 우리나라 땅이다.', null, 'O', null, '동해에 있는 섬이에요.', '독도는 경상북도 울릉군에 속한 우리나라 섬이에요.'),
  ('elem', 7, 'ox', '거북선을 이끌고 바다에서 왜군과 싸운 장군은 강감찬이다.', null, 'X', null, '광화문 광장에 동상이 있는 장군이에요.', '거북선으로 왜군을 물리친 장군은 이순신이에요. 강감찬은 고려 때 거란군을 물리쳤어요.'),
  ('elem', 8, 'ox', '우리나라의 나라 노래(국가)는 ''아리랑''이다.', null, 'X', null, '"동해 물과 백두산이~"로 시작해요.', '우리나라의 국가는 애국가예요.'),
  ('elem', 9, 'ox', '경주에 있는 첨성대는 옛날에 별을 관찰하던 곳이다.', null, 'O', null, '이름에 ''별(星)''이라는 글자가 들어 있어요.', '첨성대는 신라 시대에 하늘과 별을 관찰하던 천문대예요.'),
  ('elem', 10, 'ox', '추석은 음력 8월 15일이다.', null, 'O', null, '일 년 중 보름달이 가장 크고 둥글게 뜨는 날이에요.', '추석은 음력 8월 15일로, 햇곡식과 송편으로 차례를 지내요.'),
  ('elem', 11, 'ox', '한글날은 8월 15일이다.', null, 'X', null, '가을, 10월에 있는 기념일이에요.', '한글날은 10월 9일이에요. 8월 15일은 광복절이에요.'),
  ('elem', 12, 'ox', '우리나라의 전통 옷은 ''기모노''이다.', null, 'X', null, '설날이나 추석에 곱게 차려입는 옷이에요.', '우리나라의 전통 옷은 한복이에요. 기모노는 일본의 전통 옷이에요.'),
  ('elem', 13, 'ox', '김치는 배추나 무 같은 채소를 소금에 절여 양념해 만든 음식이다.', null, 'O', null, '겨울을 앞두고 온 가족이 모여 ''김장''을 해요.', '김치는 채소를 절이고 양념해 발효시킨 우리 고유의 음식이에요.'),
  ('elem', 14, 'ox', '조선의 수도 한양은 지금의 서울이다.', null, 'O', null, '경복궁이 있는 도시를 떠올려 보세요.', '이성계는 조선을 세운 뒤 수도를 한양으로 옮겼고, 한양이 지금의 서울이에요.'),
  ('elem', 15, 'ox', '고조선을 세운 사람은 주몽이다.', null, 'X', null, '곰이 사람이 되었다는 이야기와 관련 있어요.', '고조선은 단군왕검이 세웠어요. 주몽은 고구려를 세웠어요.'),
  ('elem', 16, 'ox', '윷놀이는 주사위 여섯 개를 던져서 하는 놀이이다.', null, 'X', null, '''도, 개, 걸, 윷, 모''를 떠올려 보세요.', '윷놀이는 나무 막대 네 개(윷가락)를 던져서 하는 놀이예요.'),
  ('elem', 17, 'ox', '세종대왕 때 장영실이 해시계와 물시계를 만들었다.', null, 'O', null, '장영실은 세종대왕이 아낀 과학자예요.', '장영실은 해시계 앙부일구와 저절로 시간을 알리는 물시계 자격루를 만들었어요.'),
  ('elem', 18, 'ox', '옛날 사람들이 짚으로 엮어 신던 신발을 ''짚신''이라고 한다.', null, 'O', null, '신발 이름에 재료가 그대로 들어 있어요.', '짚신은 볏짚을 엮어 만든 신발로, 옛날 사람들이 흔히 신었어요.'),
  ('elem', 19, 'ox', '경복궁은 신라의 궁궐이다.', null, 'X', null, '서울 광화문 뒤에 있는 궁궐이에요.', '경복궁은 조선을 세운 뒤 한양에 지은 조선의 궁궐이에요.'),
  ('elem', 20, 'ox', '삼일절 같은 국경일에는 집집마다 태극기를 단다.', null, 'O', null, '나라의 기쁜 날을 함께 기념하는 방법이에요.', '삼일절, 광복절, 개천절, 한글날 같은 국경일에는 태극기를 달아요.'),
  ('elem', 21, 'ox', '만 원짜리 지폐에 그려진 인물은 이순신이다.', null, 'X', null, '한글을 만든 왕이에요.', '만 원짜리 지폐에는 세종대왕이 그려져 있어요. 이순신은 백 원짜리 동전에 있어요.'),
  ('elem', 22, 'ox', '유관순은 3·1 운동 때 만세를 외친 독립운동가이다.', null, 'O', null, '태극기를 나눠 주며 아우내 장터에서 만세를 불렀어요.', '유관순은 고향 천안 아우내 장터에서 만세 운동을 이끈 독립운동가예요.'),
  ('elem', 23, 'ox', '탈을 쓰고 춤추며 이야기를 펼치는 놀이를 ''탈춤''이라고 한다.', null, 'O', null, '얼굴에 쓰는 것을 ''탈''이라고 해요.', '탈춤은 탈을 쓰고 춤과 노래, 이야기로 웃음을 주던 우리 전통 놀이예요.'),
  ('elem', 24, 'ox', '지붕을 기와로 덮은 집을 ''초가집''이라고 한다.', null, 'X', null, '초가집의 지붕은 볏짚으로 덮어요.', '기와로 덮은 집은 기와집이에요. 볏짚으로 지붕을 덮은 집이 초가집이에요.'),
  ('elem', 25, 'ox', '거북선은 배 위를 덮개로 덮어 적의 공격을 막은 배이다.', null, 'O', null, '거북의 등딱지를 닮았어요.', '거북선은 등을 덮개로 덮고 뾰족한 쇠못을 꽂아 적이 올라오지 못하게 했어요.'),
  ('elem', 26, 'ox', '한글을 처음 만들었을 때의 이름은 ''훈민정음''이다.', null, 'O', null, '''백성을 가르치는 바른 소리''라는 뜻이에요.', '세종대왕은 한글을 만들고 훈민정음이라는 이름을 붙였어요.'),
  ('elem', 27, 'ox', '다보탑과 석가탑은 경주 불국사에 있다.', null, 'O', null, '신라의 수도였던 도시에 있는 절이에요.', '다보탑과 석가탑은 신라 때 세운 탑으로, 경주 불국사에 나란히 서 있어요.'),
  ('elem', 28, 'ox', '동짓날에는 송편을 먹는다.', null, 'X', null, '빨간 팥으로 만든 음식이 나쁜 기운을 쫓는다고 믿었어요.', '동짓날에는 팥죽을 먹어요. 송편은 추석 음식이에요.'),
  ('elem', 29, 'ox', '강강술래는 혼자서 추는 춤이다.', null, 'X', null, '보름달 아래에서 여럿이 손을 잡아요.', '강강술래는 여러 사람이 손을 잡고 둥글게 돌며 노래하고 춤추는 놀이예요.'),
  ('mid', 0, 'mc', '우리 역사에서 처음 세워진 나라는?', '["고구려","고조선","신라","가야"]'::jsonb, '1', null, '단군 이야기와 관련 있어요.', '고조선은 단군왕검이 세운 우리 역사 최초의 국가예요.'),
  ('mid', 1, 'ox', '고구려·백제·신라가 함께 있던 시대를 ''삼국 시대''라고 한다.', null, 'O', null, '나라가 몇 개였는지 세어 보세요.', '세 나라가 경쟁하며 발전한 시대를 삼국 시대라고 불러요.'),
  ('mid', 2, 'mc', '고구려의 영토를 크게 넓혀 이름에 ''땅을 넓혔다''는 뜻이 담긴 왕은?', '["광개토대왕","세종대왕","태조 왕건","정조"]'::jsonb, '0', null, '이름에 ''넓을 광(廣)'', ''열 개(開)'', ''땅 토(土)''가 들어가요.', '광개토대왕은 만주와 한반도 북부까지 영토를 크게 넓혔어요.'),
  ('mid', 3, 'ox', '고려를 세운 사람은 이성계이다.', null, 'X', null, '이성계는 고려 다음 나라를 세웠어요.', '고려를 세운 사람은 왕건이고, 이성계는 조선을 세웠어요.'),
  ('mid', 4, 'mc', '고려 시대에 만들어져 지금 해인사에 보관된 불교 경판은?', '["팔만대장경","훈민정음 해례본","직지심체요절","조선왕조실록"]'::jsonb, '0', null, '나무판이 무려 8만 장이 넘어요.', '팔만대장경은 부처의 힘으로 몽골의 침입을 막고자 하는 바람을 담아 만들었어요.'),
  ('mid', 5, 'ox', '『직지심체요절』은 현재 남아 있는 세계에서 가장 오래된 금속 활자 인쇄본이다.', null, 'O', null, '고려는 금속 활자 기술이 뛰어났어요.', '직지는 고려 때 금속 활자로 찍은 책으로, 유네스코 세계기록유산이에요.'),
  ('mid', 6, 'mc', '임진왜란 때 한산도 대첩을 승리로 이끈 장군은?', '["강감찬","을지문덕","이순신","김유신"]'::jsonb, '2', null, '거북선과 함께 기억되는 장군이에요.', '이순신은 학이 날개를 편 모양의 학익진 전법으로 한산도에서 왜군을 크게 이겼어요.'),
  ('mid', 7, 'ox', '수원 화성을 쌓을 때 정약용이 고안한 거중기가 쓰였다.', null, 'O', null, '무거운 돌을 적은 힘으로 들어 올리는 기계예요.', '거중기 덕분에 공사 기간과 비용을 크게 줄일 수 있었어요.'),
  ('mid', 8, 'mc', '1919년 일제에 맞서 전국에서 일어난 만세 운동은?', '["3·1 운동","동학 농민 운동","4·19 혁명","6·25 전쟁"]'::jsonb, '0', null, '이 운동을 기념하는 날이 국경일이에요.', '3·1 운동은 민족 전체가 독립 의지를 세계에 알린 운동이에요.'),
  ('mid', 9, 'ox', '대한민국 임시 정부는 서울에 세워졌다.', null, 'X', null, '일제의 감시를 피해 다른 나라에 세웠어요.', '대한민국 임시 정부는 1919년 중국 상하이에 세워졌어요.'),
  ('mid', 10, 'mc', '고구려를 세운 사람은?', '["주몽","온조","박혁거세","김수로"]'::jsonb, '0', null, '활을 아주 잘 쏘았다고 전해져요.', '주몽은 고구려를 세웠어요. 온조는 백제, 박혁거세는 신라, 김수로는 가야를 세웠어요.'),
  ('mid', 11, 'ox', '백제를 세운 사람은 온조이다.', null, 'O', null, '온조는 주몽의 아들이라고 전해져요.', '온조는 한강 근처에 백제를 세웠어요.'),
  ('mid', 12, 'mc', '신라가 삼국을 통일하는 데 큰 역할을 한 장군은?', '["김유신","계백","을지문덕","연개소문"]'::jsonb, '0', null, '신라 사람이에요. 나머지는 백제와 고구려 사람이에요.', '김유신은 김춘추(태종 무열왕)와 함께 삼국 통일을 이끌었어요.'),
  ('mid', 13, 'ox', '살수 대첩에서 수나라 군대를 물리친 장군은 강감찬이다.', null, 'X', null, '살수 대첩은 고구려 때 일어난 싸움이에요.', '살수 대첩을 이끈 장군은 고구려의 을지문덕이에요. 강감찬은 고려 때 귀주 대첩을 이끌었어요.'),
  ('mid', 14, 'mc', '고구려가 멸망한 뒤 대조영이 세운 나라는?', '["발해","후백제","가야","동예"]'::jsonb, '0', null, '''해동성국(바다 동쪽의 번성한 나라)''이라고 불렸어요.', '대조영은 고구려 사람들을 모아 발해를 세웠어요.'),
  ('mid', 15, 'ox', '귀주 대첩에서 거란군을 크게 물리친 장군은 강감찬이다.', null, 'O', null, '고려 때 거란이 여러 번 쳐들어왔어요.', '강감찬은 1019년 귀주에서 거란군을 크게 물리쳤어요.'),
  ('mid', 16, 'mc', '고려 시대에 만들어진, 푸른빛이 도는 아름다운 도자기는?', '["고려청자","백자","분청사기","빗살무늬 토기"]'::jsonb, '0', null, '이름에 나라 이름과 색깔이 들어 있어요.', '고려청자는 맑은 푸른빛과 상감 기법으로 세계적으로 이름난 도자기예요.'),
  ('mid', 17, 'ox', '조선의 수도는 개경이었다.', null, 'X', null, '개경은 조선 이전 나라의 수도예요.', '조선의 수도는 한양(지금의 서울)이에요. 개경은 고려의 수도였어요.'),
  ('mid', 18, 'mc', '세종 때 만들어져 비가 내린 양을 재던 기구는?', '["측우기","거중기","혼천의","앙부일구"]'::jsonb, '0', null, '이름에 ''비 우(雨)'' 자가 들어 있어요.', '측우기 덕분에 전국의 비 내린 양을 재서 농사에 활용할 수 있었어요.'),
  ('mid', 19, 'ox', '『조선왕조실록』은 고려 시대에 만들어졌다.', null, 'X', null, '책 이름에 나라 이름이 들어 있어요.', '『조선왕조실록』은 조선 왕들의 일을 기록한 책으로, 유네스코 세계기록유산이에요.'),
  ('mid', 20, 'mc', '임진왜란이 일어난 해는?', '["1392년","1592년","1636년","1910년"]'::jsonb, '1', null, '조선이 세워지고 약 200년 뒤예요.', '임진왜란은 1592년 일본이 조선에 쳐들어오면서 시작되었어요.'),
  ('mid', 21, 'ox', '병자호란 때 인조는 남한산성으로 피란했다.', null, 'O', null, '서울 남쪽 경기도 광주에 있는 산성이에요.', '1636년 청나라가 쳐들어오자 인조는 남한산성에서 버티다가 결국 항복했어요.'),
  ('mid', 22, 'mc', '『목민심서』를 쓴 조선 후기의 실학자는?', '["정약용","이황","이이","김정호"]'::jsonb, '0', null, '거중기를 고안한 사람이에요.', '정약용은 백성을 다스리는 관리의 바른 자세를 『목민심서』에 담았어요.'),
  ('mid', 23, 'ox', '「대동여지도」를 만든 사람은 정약용이다.', null, 'X', null, '평생 지도를 만든 사람으로 알려져 있어요.', '「대동여지도」는 김정호가 만든 우리나라 지도예요.'),
  ('mid', 24, 'mc', '1894년 전봉준이 이끈 농민들의 봉기는?', '["동학 농민 운동","3·1 운동","갑신정변","임오군란"]'::jsonb, '0', null, '''사람이 곧 하늘''이라고 가르친 종교와 관련 있어요.', '동학 농민 운동은 탐관오리와 외세에 맞서 농민들이 일어난 운동이에요.'),
  ('mid', 25, 'ox', '안중근은 하얼빈에서 이토 히로부미를 처단했다.', null, 'O', null, '1909년 중국의 한 기차역에서 일어난 일이에요.', '안중근은 1909년 하얼빈역에서 침략의 우두머리 이토 히로부미를 처단했어요.'),
  ('mid', 26, 'mc', '우리나라가 일제로부터 광복을 맞은 해는?', '["1919년","1945년","1948년","1950년"]'::jsonb, '1', null, '제2차 세계 대전이 끝난 해예요.', '우리나라는 1945년 8월 15일 광복을 맞았어요.'),
  ('mid', 27, 'ox', '6·25 전쟁은 1945년에 시작되었다.', null, 'X', null, '광복을 맞고 몇 년 뒤의 일이에요.', '6·25 전쟁은 1950년 6월 25일에 시작되었어요.'),
  ('mid', 28, 'mc', '흥선 대원군이 왕실의 힘을 높이려고 다시 지은 궁궐은?', '["경복궁","창덕궁","덕수궁","경희궁"]'::jsonb, '0', null, '임진왜란 때 불타 오랫동안 비어 있던 조선의 첫 궁궐이에요.', '흥선 대원군은 임진왜란 때 불탄 경복궁을 다시 지었어요.'),
  ('mid', 29, 'ox', '이황과 이이는 조선의 이름난 학자로, 지금 지폐에도 얼굴이 실려 있다.', null, 'O', null, '천 원과 오천 원짜리 지폐를 떠올려 보세요.', '천 원짜리에는 이황, 오천 원짜리에는 이이가 그려져 있어요.'),
  ('mid', 30, 'mc', '고조선에서 사회 질서를 지키려고 만든 법으로, 지금은 3개 조항만 전해지는 것은?', '["8조법","경국대전","율령","노비안검법"]'::jsonb, '0', null, '법 이름에 숫자가 들어가요.', '고조선의 8조법은 ''사람을 죽인 자는 사형'', ''남을 다치게 한 자는 곡식으로 갚는다'', ''도둑질한 자는 노비로 삼는다'' 세 조항이 전해져요.'),
  ('mid', 31, 'ox', '고조선의 8조법에는 ''남을 다치게 한 자는 곡식으로 갚는다''는 내용이 있다.', null, 'O', null, '농사를 짓던 사회라 곡식이 귀했어요.', '8조법을 보면 고조선이 사람의 생명과 노동력, 개인의 재산을 소중히 여긴 사회였음을 알 수 있어요.'),
  ('mid', 32, 'ox', '고조선의 8조법에 따르면 도둑질한 사람은 노비가 되었다.', null, 'O', null, '신분의 차이가 있던 사회였어요.', '8조법에는 ''도둑질한 자는 그 집의 노비로 삼는다''는 조항이 있어 고조선에 신분 제도가 있었음을 알 수 있어요.'),
  ('mid', 33, 'mc', '단군왕검이 세웠다고 전해지는 나라는?', '["부여","고조선","옥저","삼한"]'::jsonb, '1', null, '우리 역사 최초의 나라예요.', '『삼국유사』에는 단군왕검이 고조선을 세웠다는 건국 이야기가 실려 있어요.'),
  ('mid', 34, 'ox', '단군 이야기에서 곰은 쑥과 마늘을 먹고 사람(웅녀)이 되었다.', null, 'O', null, '호랑이는 참지 못하고 뛰쳐나갔어요.', '곰은 동굴에서 쑥과 마늘을 먹으며 견뎌 웅녀가 되었고, 환웅과 혼인해 단군왕검을 낳았다고 전해져요.'),
  ('mid', 35, 'mc', '고조선의 건국 이야기에 나오는 ''널리 인간을 이롭게 하라''는 뜻의 이념은?', '["탕평","실사구시","홍익인간","위정척사"]'::jsonb, '2', null, '우리나라 교육 이념이기도 해요.', '홍익인간은 단군 이야기에 담긴 건국 이념으로, 지금도 대한민국 교육 이념으로 쓰여요.'),
  ('mid', 36, 'ox', '고조선은 중국 한나라의 공격을 받아 멸망하였다.', null, 'O', null, '기원전 108년의 일이에요.', '고조선은 한 무제의 침략에 맞서 1년 가까이 버텼지만 기원전 108년 수도 왕검성이 함락되며 멸망했어요.'),
  ('mid', 37, 'mc', '고조선 때 만들어진 것으로, 고조선의 세력 범위를 알려 주는 유물은?', '["금동 대향로","청자 상감 운학문 매병","거북선","비파형 동검"]'::jsonb, '3', null, '악기 비파를 닮은 청동 칼이에요.', '비파형 동검과 탁자식 고인돌이 나온 지역을 보면 고조선의 세력 범위를 짐작할 수 있어요.'),
  ('mid', 38, 'ox', '광개토대왕은 신라에 쳐들어온 왜를 물리쳐 주었다.', null, 'O', null, '신라 내물왕이 도움을 청했어요.', '광개토대왕은 400년에 군대를 보내 신라를 침입한 왜를 물리쳤어요. 이 일은 광개토대왕릉비에 기록되어 있어요.'),
  ('mid', 39, 'mc', '광개토대왕의 업적을 기록하려고 아들 장수왕이 세운 비석은?', '["광개토대왕릉비","북한산 순수비","척화비","단양 신라 적성비"]'::jsonb, '0', null, '중국 지린성 지안에 지금도 서 있어요.', '장수왕은 아버지의 업적을 기리려고 광개토대왕릉비를 세웠어요. 높이가 6m가 넘는 큰 비석이에요.'),
  ('mid', 40, 'ox', '광개토대왕은 ''영락''이라는 독자적인 연호를 썼다.', null, 'O', null, '중국과 대등하다는 자신감을 보여 줘요.', '광개토대왕은 ''영락''이라는 연호를 써서 고구려가 중국과 대등한 나라임을 드러냈어요.'),
  ('mid', 41, 'mc', '427년 수도를 평양으로 옮기고 남쪽으로 영토를 넓힌 고구려의 왕은?', '["광개토대왕","장수왕","소수림왕","고국천왕"]'::jsonb, '1', null, '98세까지 살아 이름에 ''오래 살았다''는 뜻이 있어요.', '장수왕은 국내성에서 평양으로 수도를 옮기고 남진 정책을 펼쳤어요.'),
  ('mid', 42, 'ox', '장수왕은 백제의 수도 한성을 함락하고 한강 유역을 차지하였다.', null, 'O', null, '475년, 백제 개로왕이 이때 죽었어요.', '장수왕은 475년 한성을 함락해 한강 유역을 차지했고, 백제는 웅진(공주)으로 수도를 옮겼어요.'),
  ('mid', 43, 'mc', '장수왕이 남쪽으로 영토를 넓힌 것을 보여 주는, 충청북도에 있는 고구려 비석은?', '["광개토대왕릉비","북한산 순수비","충주 고구려비","사택지적비"]'::jsonb, '2', null, '옛 이름은 ''중원 고구려비''예요.', '충주 고구려비는 남한에 있는 유일한 고구려 비석으로, 고구려가 남한강 유역까지 내려왔음을 보여 줘요.'),
  ('mid', 44, 'ox', '장수왕의 남진 정책에 맞서 신라와 백제는 나제 동맹을 맺었다.', null, 'O', null, '두 나라가 힘을 합쳤어요.', '433년 신라 눌지왕과 백제 비유왕이 고구려의 남진에 맞서 나제 동맹을 맺었어요.'),
  ('mid', 45, 'mc', '고구려에서 불교를 받아들이고 태학을 세웠으며 율령을 반포한 왕은?', '["장수왕","미천왕","영양왕","소수림왕"]'::jsonb, '3', null, '광개토대왕의 큰아버지예요.', '소수림왕은 372년 불교를 받아들이고 태학을 세웠으며, 373년 율령을 반포해 나라의 기틀을 다졌어요.'),
  ('mid', 46, 'ox', '고구려를 처음 세운 곳은 평양이다.', null, 'X', null, '주몽은 졸본 지역에 나라를 세웠어요.', '고구려는 졸본에서 건국되어 국내성을 거쳐 장수왕 때 평양으로 수도를 옮겼어요.'),
  ('mid', 47, 'mc', '수나라 113만 대군을 살수에서 크게 물리친 고구려의 장군은?', '["을지문덕","양만춘","연개소문","강감찬"]'::jsonb, '0', null, '적장 우중문에게 시를 지어 보냈어요.', '을지문덕은 612년 살수(청천강)에서 수나라 군대를 크게 물리쳤어요(살수 대첩).'),
  ('mid', 48, 'ox', '안시성 싸움에서 고구려는 당 태종의 군대를 물리쳤다.', null, 'O', null, '645년, 성주 양만춘이 이끌었다고 전해져요.', '안시성 사람들은 88일 동안 당 태종의 공격을 막아 내 당나라 군대를 돌려보냈어요.'),
  ('mid', 49, 'mc', '4세기에 백제의 전성기를 이끌고 마한을 정복한 왕은?', '["무령왕","근초고왕","성왕","의자왕"]'::jsonb, '1', null, '이름 앞에 ''근''자가 붙어요.', '근초고왕은 마한을 정복하고 고구려 평양성을 공격해 고국원왕을 전사시키는 등 백제의 전성기를 열었어요.'),
  ('mid', 50, 'ox', '근초고왕은 고구려의 평양성을 공격하여 고국원왕을 전사시켰다.', null, 'O', null, '371년의 일이에요.', '근초고왕은 371년 평양성을 공격했고, 이 싸움에서 고구려 고국원왕이 전사했어요.'),
  ('mid', 51, 'ox', '근초고왕 때 백제는 왜에 칠지도를 보냈다.', null, 'O', null, '가지가 일곱 개인 칼이에요.', '칠지도는 백제가 왜에 보낸 칼로, 당시 백제와 왜가 가깝게 교류했음을 보여 줘요. 지금은 일본에 있어요.'),
  ('mid', 52, 'mc', '백제의 수도를 사비(부여)로 옮기고 나라 이름을 ''남부여''로 바꾼 왕은?', '["근초고왕","무령왕","성왕","온조왕"]'::jsonb, '2', null, '관산성 싸움에서 전사했어요.', '성왕은 538년 사비로 수도를 옮기고 국호를 남부여로 바꾸며 백제의 중흥을 꾀했어요.'),
  ('mid', 53, 'ox', '백제 성왕은 신라와 힘을 합쳐 한강 유역을 되찾았지만, 신라 진흥왕에게 다시 빼앗겼다.', null, 'O', null, '나제 동맹이 깨진 사건이에요.', '551년 백제와 신라는 함께 한강 유역을 되찾았지만, 진흥왕이 백제 몫까지 차지하면서 나제 동맹이 깨졌어요.'),
  ('mid', 54, 'mc', '성왕이 신라와 싸우다 전사한 싸움은?', '["황산벌 전투","살수 대첩","귀주 대첩","관산성 전투"]'::jsonb, '3', null, '554년, 지금의 충북 옥천 지역이에요.', '한강 유역을 빼앗긴 성왕은 신라를 공격했지만 관산성 전투에서 전사했어요.'),
  ('mid', 55, 'ox', '공주에서 발견된 무령왕릉은 중국 남조의 영향을 받은 벽돌무덤이다.', null, 'O', null, '1971년 도굴되지 않은 채로 발견되었어요.', '무령왕릉은 벽돌로 쌓은 무덤으로, 백제가 중국 남조와 활발히 교류했음을 보여 줘요.'),
  ('mid', 56, 'mc', '660년 황산벌에서 5천 결사대를 이끌고 신라군과 싸운 백제의 장군은?', '["계백","흑치상지","을지문덕","김유신"]'::jsonb, '0', null, '싸움에 앞서 가족을 먼저 떠나보냈다고 전해져요.', '계백은 황산벌에서 김유신의 신라군에 맞서 네 번을 이겼지만 끝내 전사했고, 백제는 곧 멸망했어요.'),
  ('mid', 57, 'mc', '부여에서 출토된, 백제 금속 공예의 걸작으로 꼽히는 유물은?', '["금관총 금관","백제 금동 대향로","성덕 대왕 신종","고려청자"]'::jsonb, '1', null, '향을 피우던 그릇이에요.', '백제 금동 대향로는 신선이 사는 산과 봉황을 섬세하게 새긴 향로로, 백제의 뛰어난 공예 기술을 보여 줘요.'),
  ('mid', 58, 'mc', '이차돈의 순교를 계기로 불교를 공인한 신라의 왕은?', '["진흥왕","지증왕","법흥왕","내물왕"]'::jsonb, '2', null, '율령도 반포한 왕이에요.', '법흥왕은 527년 이차돈의 순교를 계기로 불교를 공인했어요.'),
  ('mid', 59, 'ox', '법흥왕은 율령을 반포하고 관리의 공복(옷 색깔)을 정하였다.', null, 'O', null, '520년의 일이에요.', '법흥왕은 율령을 반포하고 관리의 등급에 따라 옷 색을 정해 나라의 체제를 정비했어요.'),
  ('mid', 60, 'ox', '법흥왕은 금관가야를 신라에 합쳤다.', null, 'O', null, '532년, 김유신의 증조할아버지 김구해가 항복했어요.', '법흥왕은 532년 금관가야를 병합해 낙동강 유역으로 세력을 넓혔어요.'),
  ('mid', 61, 'mc', '법흥왕 때 처음 사용한 신라의 독자적인 연호는?', '["영락","광덕","천통","건원"]'::jsonb, '3', null, '''처음 세운 으뜸''이라는 뜻이에요.', '법흥왕은 ''건원''이라는 연호를 써서 왕권이 강해졌음을 보여 줬어요.'),
  ('mid', 62, 'mc', '한강 유역을 차지하고 대가야를 정복하는 등 신라의 영토를 크게 넓힌 왕은?', '["진흥왕","법흥왕","선덕 여왕","문무왕"]'::jsonb, '0', null, '넓힌 땅에 순수비를 세웠어요.', '진흥왕은 한강 유역과 대가야를 차지하고 함경도까지 진출해 신라의 전성기를 열었어요.'),
  ('mid', 63, 'ox', '진흥왕은 화랑도를 국가 조직으로 개편하여 인재를 길렀다.', null, 'O', null, '김유신도 화랑 출신이에요.', '진흥왕은 청소년 단체였던 화랑도를 나라의 조직으로 키워 인재를 길렀어요.'),
  ('mid', 64, 'mc', '진흥왕이 영토를 넓힌 뒤 세운 비석이 아닌 것은?', '["북한산 순수비","광개토대왕릉비","단양 신라 적성비","창녕 척경비"]'::jsonb, '1', null, '고구려의 비석을 찾으세요.', '진흥왕은 단양 적성비, 창녕 척경비, 북한산·황초령·마운령 순수비를 세웠어요. 광개토대왕릉비는 고구려 비석이에요.'),
  ('mid', 65, 'ox', '진흥왕이 한강 유역을 차지하면서 신라는 중국과 직접 교류할 수 있게 되었다.', null, 'O', null, '한강 하류는 서해로 이어져요.', '한강 유역을 차지한 신라는 서해를 통해 중국과 직접 오갈 수 있게 되었고, 이는 삼국 통일의 밑바탕이 되었어요.'),
  ('mid', 66, 'mc', '신라 최초의 여왕으로, 첨성대와 황룡사 9층 목탑을 세운 왕은?', '["진덕 여왕","진성 여왕","선덕 여왕","진흥왕"]'::jsonb, '2', null, '모란꽃 그림 이야기로 유명해요.', '선덕 여왕 때 첨성대와 황룡사 9층 목탑이 세워졌어요.'),
  ('mid', 67, 'ox', '신라는 왕을 ''마립간''이라고 부르던 시기가 있었다.', null, 'O', null, '내물왕 때부터 썼어요.', '신라는 내물 마립간 때부터 ''마립간'' 칭호를 쓰다가 지증왕 때 ''왕''으로 바꿨어요.'),
  ('mid', 68, 'mc', '신라 지증왕 때 이사부가 정복한 곳은?', '["탐라(제주도)","대가야","금관가야","우산국(울릉도)"]'::jsonb, '3', null, '독도와도 관련 있어요.', '512년 이사부는 우산국(울릉도)을 정복해 신라 땅으로 삼았어요.'),
  ('mid', 69, 'mc', '김수로왕이 세웠다고 전해지며 철이 풍부했던 나라는?', '["금관가야","백제","부여","동예"]'::jsonb, '0', null, '지금의 김해 지역이에요.', '금관가야는 질 좋은 철을 생산해 낙랑과 왜에 수출했어요.'),
  ('mid', 70, 'mc', '고구려의 남진에 맞서 433년 신라와 백제가 맺은 동맹은?', '["나당 동맹","나제 동맹","나려 동맹","조미 동맹"]'::jsonb, '1', null, '신라(羅)와 백제(濟)의 앞 글자예요.', '나제 동맹은 장수왕의 남진 정책에 맞서 신라와 백제가 맺은 동맹으로, 약 120년 동안 이어졌어요.'),
  ('mid', 71, 'ox', '나제 동맹은 신라 진흥왕이 백제가 되찾은 한강 하류를 차지하면서 깨졌다.', null, 'O', null, '553년의 일이에요.', '진흥왕이 백제가 되찾은 한강 하류까지 차지하자 동맹이 깨졌고, 성왕은 관산성에서 전사했어요.'),
  ('mid', 72, 'mc', '648년 김춘추가 당나라에 가서 맺은 동맹은?', '["나제 동맹","한일 의정서","나당 동맹","조청 상민 수륙 무역 장정"]'::jsonb, '2', null, '신라와 당나라가 손을 잡았어요.', '김춘추는 당 태종을 만나 나당 동맹을 맺었고, 신라와 당은 함께 백제(660)와 고구려(668)를 멸망시켰어요.'),
  ('mid', 73, 'mc', '나당 연합군에게 가장 먼저 멸망한 나라는?', '["고구려","가야","발해","백제"]'::jsonb, '3', null, '660년의 일이에요.', '백제는 660년, 고구려는 668년에 나당 연합군에게 멸망했어요.'),
  ('mid', 74, 'ox', '고구려는 나당 연합군의 공격을 받아 668년에 멸망하였다.', null, 'O', null, '연개소문이 죽은 뒤 내분이 일어났어요.', '연개소문이 죽은 뒤 아들들 사이에 다툼이 벌어졌고, 고구려는 668년 평양성이 함락되며 멸망했어요.'),
  ('mid', 75, 'mc', '신라가 당나라 군대를 몰아낸 싸움이 아닌 것은?', '["살수 대첩","매소성 전투","기벌포 전투","천성 전투"]'::jsonb, '0', null, '수나라와 싸운 고구려의 싸움을 찾으세요.', '신라는 매소성(675)과 기벌포(676)에서 당군을 물리쳐 삼국 통일을 이루었어요. 살수 대첩은 고구려와 수의 싸움이에요.'),
  ('mid', 76, 'ox', '당나라는 백제와 고구려가 멸망한 뒤 신라까지 지배하려 하였다.', null, 'O', null, '그래서 나당 전쟁이 일어났어요.', '당은 계림 도독부를 두어 신라까지 지배하려 했고, 신라는 나당 전쟁에서 당을 몰아냈어요.'),
  ('mid', 77, 'mc', '676년 삼국 통일을 완성한 신라의 왕은?', '["무열왕","문무왕","신문왕","진흥왕"]'::jsonb, '1', null, '죽어서 동해의 용이 되겠다고 했어요.', '문무왕은 당군을 몰아내 676년 삼국 통일을 완성했고, 동해 바다의 대왕암에 묻혔다고 전해져요.'),
  ('mid', 78, 'ox', '김춘추는 진골 출신으로 처음 왕이 된 태종 무열왕이다.', null, 'O', null, '그 전까지는 성골이 왕이 되었어요.', '김춘추는 654년 진골 출신 최초로 왕위에 올라 태종 무열왕이 되었어요.'),
  ('mid', 79, 'mc', '김흠돌의 난을 진압하고 녹읍을 폐지하는 등 왕권을 강화한 통일 신라의 왕은?', '["문무왕","원성왕","신문왕","경순왕"]'::jsonb, '2', null, '만파식적 이야기와 관련 있어요.', '신문왕은 귀족 세력을 누르고 녹읍을 폐지했으며, 국학을 세우고 9주 5소경 체제를 갖췄어요.'),
  ('mid', 80, 'ox', '통일 신라는 전국을 9주 5소경으로 나누어 다스렸다.', null, 'O', null, '숫자 9와 5를 기억하세요.', '신문왕 때 전국을 9주로 나누고 중요한 곳에 5소경을 두어 지방을 다스렸어요.'),
  ('mid', 81, 'mc', '통일 신라 원성왕 때 유교 경전 이해 수준으로 관리를 뽑으려 한 제도는?', '["과거제","음서제","골품제","독서삼품과"]'::jsonb, '3', null, '책 읽은 수준을 세 등급으로 나눴어요.', '독서삼품과는 유학 실력으로 관리를 뽑으려 한 제도지만, 진골 귀족의 반대로 큰 효과를 보지 못했어요.'),
  ('mid', 82, 'mc', '청해진을 설치하고 해적을 소탕하여 바다를 주름잡은 통일 신라의 인물은?', '["장보고","최치원","원효","의상"]'::jsonb, '0', null, '''해상왕''이라고 불려요.', '장보고는 완도에 청해진을 설치해 해적을 물리치고 당·신라·일본을 잇는 해상 무역을 이끌었어요.'),
  ('mid', 83, 'ox', '원효는 ''나무아미타불''만 외워도 극락에 갈 수 있다고 하여 불교를 널리 알렸다.', null, 'O', null, '해골 물 이야기로 유명한 스님이에요.', '원효는 어려운 불교를 백성도 쉽게 믿을 수 있도록 아미타 신앙을 퍼뜨렸어요.'),
  ('mid', 84, 'mc', '통일 신라 때 경주에 세워진 유네스코 세계 유산은?', '["종묘","불국사와 석굴암","해인사 장경판전","수원 화성"]'::jsonb, '1', null, '토함산에 있어요.', '불국사와 석굴암은 통일 신라의 뛰어난 불교 예술을 보여 주는 유산으로 1995년 세계 유산이 되었어요.'),
  ('mid', 85, 'mc', '''에밀레종''이라고도 불리는 통일 신라의 범종은?', '["상원사 동종","보신각종","성덕 대왕 신종","용주사 동종"]'::jsonb, '2', null, '경덕왕이 만들기 시작해 혜공왕 때 완성했어요.', '성덕 대왕 신종은 현재 남아 있는 우리나라 종 가운데 가장 크고, 맑고 긴 울림으로 유명해요.'),
  ('mid', 86, 'ox', '최치원은 당나라의 빈공과에 합격한 6두품 출신 학자이다.', null, 'O', null, '''토황소격문''을 쓴 인물이에요.', '최치원은 당의 외국인 과거인 빈공과에 합격했고, 신라로 돌아와 진성 여왕에게 개혁안(시무 10여 조)을 올렸어요.'),
  ('mid', 87, 'mc', '900년 완산주(전주)에 도읍하여 후백제를 세운 사람은?', '["궁예","왕건","양길","견훤"]'::jsonb, '3', null, '아들 신검에게 쫓겨나 고려에 항복했어요.', '견훤은 900년 후백제를 세웠지만, 뒤에 아들 신검에게 금산사에 갇혔다가 왕건에게 귀순했어요.'),
  ('mid', 88, 'mc', '901년 후고구려를 세우고 나라 이름을 마진, 태봉으로 바꾼 사람은?', '["궁예","견훤","왕건","신검"]'::jsonb, '0', null, '스스로 미륵불이라 했어요.', '궁예는 송악(개성)에서 후고구려를 세웠으나, 폭정 때문에 신하들에게 쫓겨났어요.'),
  ('mid', 89, 'ox', '후삼국은 후백제, 후고구려(태봉), 신라를 말한다.', null, 'O', null, '삼국 시대와 비슷한 모습이 다시 나타났어요.', '통일 신라 말 지방 세력이 커지면서 후백제와 후고구려가 세워져 후삼국 시대가 되었어요.'),
  ('mid', 90, 'ox', '신라의 마지막 왕 경순왕은 고려에 스스로 나라를 넘겨주었다.', null, 'O', null, '935년의 일이에요.', '경순왕은 935년 고려에 항복했고, 이듬해 고려는 후백제를 무너뜨려 후삼국을 통일했어요.'),
  ('mid', 91, 'mc', '고려가 후백제를 물리쳐 후삼국 통일을 이룬 해는?', '["918년","936년","676년","1392년"]'::jsonb, '1', null, '고려가 세워지고 18년 뒤예요.', '고려는 936년 일리천 전투에서 후백제의 신검을 물리치고 후삼국을 통일했어요.'),
  ('mid', 92, 'ox', '발해의 지배층은 주로 고구려 사람이었다.', null, 'O', null, '대조영은 고구려 장수 출신이에요.', '발해는 고구려 유민이 지배층을 이루고 말갈인이 다수를 이룬 나라로, 고구려를 계승했어요.'),
  ('mid', 93, 'ox', '발해는 일본에 보낸 국서에서 스스로 ''고려(고구려)''라고 불렀다.', null, 'O', null, '고구려를 이어받았다는 뜻이에요.', '발해 문왕은 일본에 보낸 국서에서 ''고려 국왕''이라 칭해 고구려 계승 의식을 드러냈어요.'),
  ('mid', 94, 'mc', '발해가 전성기에 중국으로부터 불린 이름은?', '["동방예의지국","고요한 아침의 나라","해동성국","은둔의 나라"]'::jsonb, '2', null, '''바다 동쪽의 번성한 나라''라는 뜻이에요.', '발해는 선왕 때 영토를 크게 넓혀 ''해동성국''이라 불렸어요.'),
  ('mid', 95, 'mc', '장문휴를 보내 당나라의 산둥 지방을 공격한 발해의 왕은?', '["문왕","선왕","대조영","무왕"]'::jsonb, '3', null, '대조영의 아들이에요.', '발해 무왕은 영토를 넓히고 장문휴를 보내 당의 산둥 지방(등주)을 공격했어요.'),
  ('mid', 96, 'ox', '발해는 고려에 의해 멸망하였다.', null, 'X', null, '북쪽의 유목 민족이 쳐들어왔어요.', '발해는 926년 거란의 침략으로 멸망했고, 많은 유민이 고려로 넘어왔어요.'),
  ('mid', 97, 'mc', '918년 고려를 세운 사람은?', '["왕건","궁예","견훤","이성계"]'::jsonb, '0', null, '송악(개성) 출신 호족이에요.', '왕건은 궁예를 몰아내고 918년 고려를 세웠어요.'),
  ('mid', 98, 'mc', '태조 왕건이 후대 왕들에게 남긴 열 가지 가르침은?', '["시무 28조","훈요 10조","홍범 14조","8조법"]'::jsonb, '1', null, '''가르침의 요점''이라는 뜻이에요.', '왕건은 훈요 10조에서 불교 숭상, 북진 정책, 서경(평양) 중시 등을 당부했어요.'),
  ('mid', 99, 'ox', '태조 왕건은 호족의 딸들과 혼인하여 호족을 포섭하였다.', null, 'O', null, '부인이 29명이나 되었어요.', '왕건은 혼인 정책과 성씨 하사 등으로 지방 호족을 끌어안았어요.'),
  ('mid', 100, 'mc', '태조 왕건이 지방 호족을 견제하려고 실시한 제도는?', '["과거제와 노비안검법","호패법과 신문고","사심관 제도와 기인 제도","균역법과 탕평책"]'::jsonb, '2', null, '출신 지역을 맡기고, 자제를 볼모로 삼았어요.', '사심관 제도는 고위 관리에게 출신지를 책임지게 한 것이고, 기인 제도는 호족의 자제를 수도에 머물게 한 것이에요.'),
  ('mid', 101, 'ox', '태조 왕건은 고구려를 이어받는다는 뜻으로 북진 정책을 펼쳤다.', null, 'O', null, '나라 이름 ''고려''에도 그 뜻이 담겨 있어요.', '왕건은 서경(평양)을 중시하고 북쪽으로 영토를 넓혀 나가는 북진 정책을 폈어요.'),
  ('mid', 102, 'mc', '거란의 침입에 대비하여 30만 명의 광군을 조직한 고려의 왕은?', '["광종","성종","현종","정종"]'::jsonb, '3', null, '고려의 제3대 왕이에요.', '고려 정종은 947년 거란의 침입에 대비해 광군 30만 명을 조직했어요. 서경으로 수도를 옮기려고도 했어요.'),
  ('mid', 103, 'ox', '고려 정종은 왕실과 가까운 서경(평양)으로 수도를 옮기려 하였다.', null, 'O', null, '개경 호족의 힘을 피하고 싶었어요.', '정종은 개경 호족의 세력을 누르려고 서경 천도를 추진했지만, 일찍 세상을 떠나 이루지 못했어요.'),
  ('mid', 104, 'mc', '노비안검법을 실시하여 억울하게 노비가 된 사람을 풀어 준 고려의 왕은?', '["광종","태조","성종","공민왕"]'::jsonb, '0', null, '과거제도 실시했어요.', '광종은 956년 노비안검법으로 호족의 힘을 약화시키고 왕권을 강화했어요.'),
  ('mid', 105, 'ox', '고려 광종은 쌍기의 건의로 과거제를 처음 실시하였다.', null, 'O', null, '958년, 쌍기는 중국 후주 사람이에요.', '광종은 과거제를 실시해 실력 있는 인재를 관리로 뽑았어요.'),
  ('mid', 106, 'mc', '고려 광종이 왕권을 강화하려고 한 일이 아닌 것은?', '["노비안검법 실시","훈요 10조 남기기","과거제 실시","''광덕''·''준풍'' 연호 사용"]'::jsonb, '1', null, '태조 왕건이 한 일을 찾으세요.', '광종은 노비안검법·과거제를 실시하고 황제를 칭하며 독자적 연호를 썼어요. 훈요 10조는 태조 왕건이 남겼어요.'),
  ('mid', 107, 'ox', '고려 광종은 관리의 등급에 따라 공복(옷 색깔)을 정하였다.', null, 'O', null, '자색·단색·비색·녹색으로 나눴어요.', '광종은 공복을 제정해 관리의 위계 질서를 바로 세웠어요.'),
  ('mid', 108, 'mc', '최승로의 시무 28조를 받아들여 유교 정치를 펼친 고려의 왕은?', '["광종","현종","성종","숙종"]'::jsonb, '2', null, '지방에 처음으로 12목을 설치했어요.', '성종은 시무 28조를 받아들여 유교를 정치 이념으로 삼고, 12목에 지방관을 보냈어요.'),
  ('mid', 109, 'mc', '거란의 1차 침입 때 외교 담판으로 강동 6주를 얻은 인물은?', '["강감찬","윤관","김부식","서희"]'::jsonb, '3', null, '거란 장수 소손녕과 담판했어요.', '서희는 993년 소손녕과 담판을 벌여 싸우지 않고 강동 6주를 얻었어요.'),
  ('mid', 110, 'mc', '별무반을 이끌고 여진을 정벌한 뒤 동북 9성을 쌓은 고려의 장수는?', '["윤관","서희","강감찬","최영"]'::jsonb, '0', null, '기병이 강한 여진에 맞서 특수 부대를 만들었어요.', '윤관은 별무반을 조직해 여진을 물리치고 동북 9성을 쌓았어요.'),
  ('mid', 111, 'ox', '1170년 무신들이 문신 중심의 정치에 반발하여 무신 정변을 일으켰다.', null, 'O', null, '정중부·이의방 등이 일으켰어요.', '무신 정변 이후 약 100년 동안 무신들이 권력을 잡는 무신 정권 시대가 이어졌어요.'),
  ('mid', 112, 'ox', '몽골의 침입에 맞서 고려는 수도를 강화도로 옮겼다.', null, 'O', null, '몽골군은 바다에 약했어요.', '최우 정권은 1232년 강화도로 수도를 옮겨 약 40년 동안 몽골에 맞섰어요.'),
  ('mid', 113, 'mc', '고려가 몽골과 강화한 뒤에도 진도와 제주도로 옮겨 가며 끝까지 몽골에 맞선 부대는?', '["별무반","삼별초","광군","훈련도감"]'::jsonb, '1', null, '좌별초·우별초·신의군을 합친 이름이에요.', '삼별초는 배중손·김통정 등의 지휘로 강화도→진도→제주도로 옮겨 가며 항쟁했어요.'),
  ('mid', 114, 'mc', '원나라의 간섭에서 벗어나려고 반원 개혁을 펼친 고려의 왕은?', '["광종","충렬왕","공민왕","우왕"]'::jsonb, '2', null, '부인은 원나라 공주 노국 대장 공주예요.', '공민왕은 친원 세력 기철 등을 없애고 원의 간섭에서 벗어나려 했어요.'),
  ('mid', 115, 'ox', '공민왕은 쌍성총관부를 공격하여 철령 이북의 땅을 되찾았다.', null, 'O', null, '1356년의 일로, 이성계의 아버지 이자춘도 도왔어요.', '공민왕은 원이 다스리던 쌍성총관부를 무력으로 되찾아 영토를 회복했어요.'),
  ('mid', 116, 'mc', '공민왕이 신돈을 등용하여 빼앗긴 땅과 노비를 되돌려 주려고 설치한 기구는?', '["정동행성","교정도감","집현전","전민변정도감"]'::jsonb, '3', null, '''땅(田)과 백성(民)을 바로잡는 관청''이에요.', '전민변정도감은 권문세족이 빼앗은 토지와 노비를 원래대로 돌려놓으려고 설치한 기구예요.'),
  ('mid', 117, 'ox', '공민왕은 몽골식 머리 모양(변발)과 옷차림을 따르도록 장려하였다.', null, 'X', null, '반원 개혁을 한 왕이에요.', '공민왕은 오히려 몽골식 변발과 호복을 금지하고 원의 연호 사용을 중단했어요.'),
  ('mid', 118, 'ox', '공민왕은 원나라가 고려의 내정을 간섭하던 정동행성 이문소를 폐지하였다.', null, 'O', null, '반원 개혁의 하나예요.', '공민왕은 정동행성 이문소를 없애고 원의 간섭에서 벗어나려 했어요.'),
  ('mid', 119, 'mc', '고려 말 홍건적과 왜구를 물리치며 이름을 떨친 장수로, 뒤에 조선을 세운 사람은?', '["이성계","최영","정몽주","정도전"]'::jsonb, '0', null, '황산 대첩에서 왜구를 물리쳤어요.', '이성계는 홍건적과 왜구를 물리치며 신진 무인 세력으로 성장했어요.'),
  ('mid', 120, 'mc', '고려 시대 김부식이 쓴, 현재 남아 있는 우리나라에서 가장 오래된 역사책은?', '["삼국유사","삼국사기","고려사","동국통감"]'::jsonb, '1', null, '인종의 명으로 1145년에 썼어요.', '『삼국사기』는 김부식이 쓴 역사책이에요. 『삼국유사』는 일연이 썼고 단군 이야기가 실려 있어요.'),
  ('mid', 121, 'mc', '이성계가 요동 정벌에 나섰다가 군대를 돌려 권력을 잡은 사건은?', '["계유정난","인조반정","위화도 회군","무신 정변"]'::jsonb, '2', null, '압록강의 섬에서 돌아왔어요.', '이성계는 1388년 위화도에서 군대를 돌려 최영을 몰아내고 권력을 잡았어요.'),
  ('mid', 122, 'ox', '이성계는 ''작은 나라가 큰 나라를 거스르는 것은 옳지 않다'' 등 4불가론을 들어 요동 정벌에 반대하였다.', null, 'O', null, '여름철 군사 동원, 왜구의 침입 등도 이유였어요.', '이성계는 4불가론을 내세워 요동 정벌에 반대했고, 결국 위화도에서 회군했어요.'),
  ('mid', 123, 'mc', '조선을 세운 이성계가 수도로 정한 곳은?', '["개경","평양","경주","한양"]'::jsonb, '3', null, '지금의 서울이에요.', '이성계는 1392년 조선을 세우고 1394년 한양으로 수도를 옮겼어요.'),
  ('mid', 124, 'mc', '이성계를 도와 조선을 세우고 『조선경국전』을 지은 인물은?', '["정도전","정몽주","이방원","황희"]'::jsonb, '0', null, '경복궁 이름도 지었어요.', '정도전은 조선 건국의 설계자로 한양 도성 건설과 제도 정비에 힘썼지만, 이방원에게 죽임을 당했어요.'),
  ('mid', 125, 'ox', '고려를 지키려던 정몽주는 이방원의 「하여가」에 「단심가」로 답하였다.', null, 'O', null, '''이 몸이 죽고 죽어 일백 번 고쳐 죽어''로 시작해요.', '정몽주는 「단심가」로 고려에 대한 충성을 지키겠다는 뜻을 밝혔고, 결국 선죽교에서 죽임을 당했어요.'),
  ('mid', 126, 'mc', '16세 이상 남자에게 신분증을 차게 한 조선 태종(이방원)의 제도는?', '["균역법","호패법","대동법","직전법"]'::jsonb, '1', null, '오늘날의 주민 등록증과 비슷해요.', '태종은 호패법을 실시해 인구를 파악하고 세금과 군역을 공평하게 매기려 했어요.'),
  ('mid', 127, 'ox', '태종 이방원은 사병을 없애고 6조 직계제를 실시하여 왕권을 강화하였다.', null, 'O', null, '6조가 의정부를 거치지 않고 왕에게 바로 보고했어요.', '태종은 사병 혁파와 6조 직계제로 왕권을 강화했어요.'),
  ('mid', 128, 'ox', '억울한 일이 있는 백성이 북을 쳐서 왕에게 알리도록 한 신문고는 태종 때 설치되었다.', null, 'O', null, '대궐 밖에 북을 매달았어요.', '태종은 백성의 억울함을 들으려고 신문고를 설치했어요.'),
  ('mid', 129, 'mc', '이방원이 정도전 등을 없애고 권력을 잡은 사건은?', '["계유정난","중종반정","제1차 왕자의 난","무오사화"]'::jsonb, '2', null, '1398년, 왕자들 사이의 다툼이에요.', '이방원은 1398년 제1차 왕자의 난으로 정도전과 세자 방석을 제거하고 권력을 잡았어요.'),
  ('mid', 130, 'mc', '세종 때 학자들이 모여 학문을 연구하던 기관은?', '["규장각","성균관","홍문관","집현전"]'::jsonb, '3', null, '''어진 사람들이 모인 곳''이라는 뜻이에요.', '세종은 집현전을 두어 학자들을 키웠고, 이곳 학자들이 훈민정음 창제를 도왔어요.'),
  ('mid', 131, 'ox', '세종 때 최윤덕과 김종서가 4군 6진을 개척하여 지금과 비슷한 국경선이 만들어졌다.', null, 'O', null, '압록강과 두만강이 국경이 되었어요.', '세종은 여진을 몰아내고 4군 6진을 설치해 압록강~두만강을 국경으로 삼았어요.'),
  ('mid', 132, 'mc', '세종 때 장영실이 만든, 저절로 시간을 알려 주는 물시계는?', '["자격루","앙부일구","측우기","혼천의"]'::jsonb, '0', null, '''스스로(自) 치는(擊) 물시계(漏)''예요.', '자격루는 정해진 시각이 되면 인형이 종·북·징을 쳐서 시간을 알려 주는 자동 물시계예요.'),
  ('mid', 133, 'mc', '세종 때 펴낸, 우리 풍토에 맞는 농사법을 정리한 책은?', '["목민심서","농사직설","동의보감","택리지"]'::jsonb, '1', null, '농부들의 경험을 모아 만들었어요.', '『농사직설』은 각 지역 농민의 경험을 모아 우리 땅에 맞는 농법을 정리한 책이에요.'),
  ('mid', 134, 'ox', '세종은 이종무를 보내 왜구의 근거지인 쓰시마섬(대마도)을 정벌하였다.', null, 'O', null, '1419년의 일이에요.', '세종 때(상왕 태종 주도) 이종무가 쓰시마섬을 정벌해 왜구를 토벌했어요.'),
  ('mid', 135, 'mc', '어린 조카 단종을 몰아내고 왕이 된 조선의 왕은?', '["태종","중종","세조","인조"]'::jsonb, '2', null, '수양 대군이라고 불렸어요.', '수양 대군은 계유정난으로 권력을 잡은 뒤 단종을 몰아내고 세조가 되었어요.'),
  ('mid', 136, 'mc', '1453년 수양 대군이 김종서 등을 죽이고 권력을 잡은 사건은?', '["위화도 회군","인조반정","갑자사화","계유정난"]'::jsonb, '3', null, '그해의 간지를 딴 이름이에요.', '수양 대군은 계유정난으로 김종서·황보인을 제거하고 실권을 잡았어요.'),
  ('mid', 137, 'ox', '세조는 현직 관리에게만 토지를 주는 직전법을 실시하였다.', null, 'O', null, '''직(職)''은 직책을 뜻해요.', '세조는 관리에게 줄 땅이 부족해지자 현직 관리에게만 수조권을 주는 직전법을 실시했어요.'),
  ('mid', 138, 'ox', '세조는 집현전을 없애고 6조 직계제를 다시 실시하였다.', null, 'O', null, '사육신 사건과 관련 있어요.', '단종 복위 운동에 집현전 학자들이 참여하자 세조는 집현전을 없애고 왕권을 강화했어요.'),
  ('mid', 139, 'mc', '세조 때 편찬을 시작하여 성종 때 완성된 조선의 기본 법전은?', '["경국대전","속대전","대전통편","8조법"]'::jsonb, '0', null, '''나라를 다스리는 큰 법전''이에요.', '『경국대전』은 세조 때 만들기 시작해 성종 때 완성·반포된 조선의 기본 법전이에요.'),
  ('mid', 140, 'mc', '폭정을 일삼다 중종반정으로 왕위에서 쫓겨난 조선의 왕은?', '["광해군","연산군","단종","세조"]'::jsonb, '1', null, '무오사화와 갑자사화를 일으켰어요.', '연산군은 사화를 일으키고 폭정을 하다 1506년 중종반정으로 쫓겨났어요.'),
  ('mid', 141, 'ox', '연산군 때 일어난 사화는 무오사화와 갑자사화이다.', null, 'O', null, '1498년과 1504년이에요.', '연산군 때 김종직의 「조의제문」을 문제 삼은 무오사화와, 어머니 폐비 윤씨 사건과 관련된 갑자사화가 일어났어요.'),
  ('mid', 142, 'ox', '연산군과 광해군은 ''왕(조·종)''이 아닌 ''군''으로 불린다.', null, 'O', null, '왕위에서 쫓겨난 왕이에요.', '반정으로 쫓겨난 연산군과 광해군은 묘호를 받지 못해 ''군''으로 불려요.'),
  ('mid', 143, 'mc', '조선 중종 때 개혁 정치를 펼치다 기묘사화로 죽임을 당한 인물은?', '["정도전","김종직","조광조","송시열"]'::jsonb, '2', null, '현량과 실시를 주장했어요.', '조광조는 현량과 실시, 소격서 폐지 등 개혁을 펼쳤지만 훈구 세력의 반발로 기묘사화 때 죽었어요.'),
  ('mid', 144, 'mc', '임진왜란을 일으킨 일본의 인물은?', '["이토 히로부미","도쿠가와 이에야스","오다 노부나가","도요토미 히데요시"]'::jsonb, '3', null, '일본을 통일한 인물이에요.', '도요토미 히데요시는 일본을 통일한 뒤 1592년 조선을 침략했어요.'),
  ('mid', 145, 'mc', '임진왜란 때 이순신이 13척의 배로 133척의 왜선을 물리친 싸움은?', '["명량 대첩","한산도 대첩","노량 해전","옥포 해전"]'::jsonb, '0', null, '울돌목에서 벌어졌어요.', '1597년 정유재란 때 이순신은 명량(울돌목)에서 13척으로 왜군을 크게 물리쳤어요.'),
  ('mid', 146, 'ox', '이순신은 노량 해전에서 전사하였다.', null, 'O', null, '''나의 죽음을 적에게 알리지 말라.''', '이순신은 1598년 노량 해전에서 물러가는 왜군과 싸우다 전사했어요.'),
  ('mid', 147, 'mc', '임진왜란 때 권율이 왜군을 크게 물리친 싸움은?', '["진주 대첩","행주 대첩","살수 대첩","귀주 대첩"]'::jsonb, '1', null, '여인들이 앞치마로 돌을 날랐다는 이야기가 있어요.', '1593년 권율은 행주산성에서 왜군을 크게 물리쳤어요.'),
  ('mid', 148, 'mc', '임진왜란 때 진주성에서 왜군을 물리친 장군은?', '["권율","곽재우","김시민","신립"]'::jsonb, '2', null, '1592년 진주 대첩의 주인공이에요.', '김시민은 1592년 진주성에서 3,800여 명의 군사로 2만여 왜군을 물리쳤지만 전투 중 입은 상처로 숨졌어요.'),
  ('mid', 149, 'ox', '곽재우는 임진왜란 때 의병을 일으켜 ''홍의 장군''이라고 불렸다.', null, 'O', null, '붉은 옷을 입고 싸웠어요.', '곽재우는 경상도 의령에서 의병을 일으켜 붉은 옷을 입고 싸워 ''홍의 장군''이라 불렸어요.'),
  ('mid', 150, 'ox', '임진왜란 때 명나라는 조선에 군대를 보내 도와주었다.', null, 'O', null, '평양성 탈환에 함께했어요.', '명은 조선에 지원군을 보냈고, 조·명 연합군은 1593년 평양성을 되찾았어요.'),
  ('mid', 151, 'mc', '임진왜란 중에 군사력을 키우려고 설치한, 포수·사수·살수로 이루어진 부대는?', '["별무반","삼별초","광군","훈련도감"]'::jsonb, '3', null, '조선 후기 5군영의 시작이에요.', '훈련도감은 임진왜란 중 설치된 직업 군인 부대로, 포수·사수·살수의 삼수병으로 이루어졌어요.'),
  ('mid', 152, 'mc', '임진왜란 뒤 명과 후금 사이에서 중립 외교를 펼친 조선의 왕은?', '["광해군","인조","선조","효종"]'::jsonb, '0', null, '대동법을 처음 실시한 왕이에요.', '광해군은 강홍립에게 형세를 보아 행동하라 하며 명과 후금 사이에서 실리를 챙겼어요.'),
  ('mid', 153, 'ox', '광해군 때 처음 실시된 대동법은 특산물 대신 쌀로 세금을 내게 한 제도이다.', null, 'O', null, '경기도에서 먼저 실시했어요.', '대동법은 공납을 쌀이나 베, 돈으로 내게 한 제도로 1608년 경기도에서 처음 실시되었어요.'),
  ('mid', 154, 'mc', '광해군 때 허준이 완성한 의학책은?', '["향약집성방","동의보감","의방유취","목민심서"]'::jsonb, '1', null, '유네스코 세계 기록 유산이에요.', '허준의 『동의보감』은 1610년 완성된 의학책으로, 2009년 세계 기록 유산이 되었어요.'),
  ('mid', 155, 'mc', '광해군을 몰아내고 인조를 왕으로 세운 사건은?', '["중종반정","계유정난","인조반정","위화도 회군"]'::jsonb, '2', null, '1623년 서인이 일으켰어요.', '서인 세력은 1623년 인조반정으로 광해군을 몰아내고 친명배금 정책을 폈어요.'),
  ('mid', 156, 'mc', '1627년 후금이 조선에 쳐들어온 전쟁은?', '["병자호란","임진왜란","정유재란","정묘호란"]'::jsonb, '3', null, '병자호란보다 9년 앞서요.', '정묘호란 때 인조는 강화도로 피란했고, 조선은 후금과 형제 관계를 맺었어요.'),
  ('mid', 157, 'mc', '병자호란 뒤 인조가 청 태종에게 항복한 곳은?', '["삼전도","강화도","남한산성","의주"]'::jsonb, '0', null, '지금의 서울 송파구예요.', '인조는 1637년 남한산성에서 나와 삼전도에서 청 태종에게 항복했어요.'),
  ('mid', 158, 'ox', '병자호란은 청나라가 조선에 군신 관계를 요구하며 일어난 전쟁이다.', null, 'O', null, '1636년의 일이에요.', '후금이 나라 이름을 청으로 바꾸고 군신 관계를 요구하자 조선이 거부했고, 청이 1636년 쳐들어왔어요.'),
  ('mid', 159, 'ox', '병자호란 뒤 소현 세자와 봉림 대군이 청에 인질로 끌려갔다.', null, 'O', null, '봉림 대군은 뒤에 효종이 되었어요.', '두 왕자는 청의 수도 심양에 인질로 잡혀갔어요.'),
  ('mid', 160, 'mc', '병자호란의 치욕을 씻으려고 청나라를 치자는 북벌을 추진한 왕은?', '["인조","효종","숙종","영조"]'::jsonb, '1', null, '봉림 대군이었어요.', '효종은 송시열 등과 북벌을 준비했지만 이루지 못했어요. 이때 키운 조총 부대는 나선 정벌에 쓰였어요.'),
  ('mid', 161, 'ox', '병자호란 때 김상헌은 끝까지 싸우자는 척화를, 최명길은 화해하자는 주화를 주장하였다.', null, 'O', null, '남한산성 안에서 벌어진 논쟁이에요.', '남한산성에서 김상헌(척화파)과 최명길(주화파)은 서로 다른 주장을 펼쳤어요.'),
  ('mid', 162, 'mc', '붕당의 다툼을 막으려고 탕평책을 펴고 균역법을 실시한 왕은?', '["정조","숙종","영조","순조"]'::jsonb, '2', null, '조선에서 가장 오래 왕위에 있었어요.', '영조는 탕평비를 세우고 탕평책을 펼쳤으며, 군포를 1필로 줄인 균역법을 실시했어요.'),
  ('mid', 163, 'mc', '정조가 세운 왕실 도서관이자 학문 연구 기관은?', '["집현전","성균관","향교","규장각"]'::jsonb, '3', null, '서얼 출신도 검서관으로 뽑았어요.', '정조는 규장각을 세워 젊은 인재를 키우고 개혁 정치를 뒷받침하게 했어요.'),
  ('mid', 164, 'ox', '정조는 왕의 친위 부대인 장용영을 설치하였다.', null, 'O', null, '왕권을 강화하려는 목적이에요.', '정조는 장용영을 두어 군사력을 손에 쥐고 왕권을 강화했어요.'),
  ('mid', 165, 'ox', '순조 이후 왕의 외척 가문이 권력을 독차지한 정치를 세도 정치라고 한다.', null, 'O', null, '안동 김씨, 풍양 조씨 등이에요.', '세도 정치로 관직을 사고파는 일이 많아지고 삼정이 문란해져 백성의 삶이 어려워졌어요.'),
  ('mid', 166, 'mc', '1811년 평안도 차별에 맞서 일어난 농민 봉기는?', '["홍경래의 난","임술 농민 봉기","동학 농민 운동","망이·망소이의 난"]'::jsonb, '0', null, '봉기를 이끈 사람의 이름이 붙었어요.', '홍경래의 난은 서북 지방 차별과 세도 정치에 맞서 일어났어요.'),
  ('mid', 167, 'ox', '흥선 대원군은 전국의 서원을 47곳만 남기고 정리하였다.', null, 'O', null, '서원이 백성을 괴롭히고 세금을 피했어요.', '흥선 대원군은 서원을 정리해 양반의 힘을 누르고 나라 재정을 튼튼히 하려 했어요.'),
  ('mid', 168, 'mc', '흥선 대원군이 서양과 교류하지 않겠다는 뜻을 알리려고 전국에 세운 비석은?', '["탕평비","척화비","순수비","광개토대왕릉비"]'::jsonb, '1', null, '''서양 오랑캐와 화친하자는 것은 나라를 파는 것이다.''', '흥선 대원군은 신미양요 뒤 척화비를 세워 통상 수교 거부 의지를 밝혔어요.'),
  ('mid', 169, 'mc', '1866년 프랑스가 천주교 박해를 구실로 강화도를 침략한 사건은?', '["신미양요","운요호 사건","병인양요","임오군란"]'::jsonb, '2', null, '외규장각 도서를 빼앗겼어요.', '병인양요 때 프랑스군은 양헌수 부대에 패해 물러가며 외규장각 도서를 약탈해 갔어요.'),
  ('mid', 170, 'ox', '신미양요는 미국이 제너럴셔먼호 사건을 구실로 강화도를 침략한 사건이다.', null, 'O', null, '1871년, 어재연 장군이 광성보에서 싸웠어요.', '신미양요 때 어재연 부대는 광성보에서 미군에 맞서 끝까지 싸웠어요.'),
  ('mid', 171, 'mc', '1876년 일본과 맺은, 우리나라 최초의 근대적 조약이자 불평등 조약은?', '["을사늑약","한일 병합 조약","제물포 조약","강화도 조약"]'::jsonb, '3', null, '''조일 수호 조규''라고도 해요.', '강화도 조약으로 부산·원산·인천이 개항되었고, 일본은 해안 측량권과 치외 법권을 얻었어요.'),
  ('mid', 172, 'mc', '1884년 김옥균 등 급진 개화파가 우정총국 개국 축하연에서 일으킨 정변은?', '["갑신정변","임오군란","갑오개혁","을미사변"]'::jsonb, '0', null, '3일 만에 끝나 ''3일 천하''라고 해요.', '갑신정변은 청군의 개입으로 3일 만에 실패했어요.'),
  ('mid', 173, 'ox', '1882년 임오군란은 신식 군대와 차별받던 구식 군인들이 일으켰다.', null, 'O', null, '밀린 급료로 모래 섞인 쌀을 받았어요.', '구식 군인들은 차별 대우와 밀린 급료 문제로 봉기했어요.'),
  ('mid', 174, 'ox', '1895년 일본은 명성 황후를 시해하는 을미사변을 일으켰다.', null, 'O', null, '경복궁 건청궁에서 일어났어요.', '일본은 러시아와 가까워지던 명성 황후를 시해했고, 이후 을미의병이 일어났어요.'),
  ('mid', 175, 'mc', '을미사변 뒤 고종이 러시아 공사관으로 거처를 옮긴 사건은?', '["갑신정변","아관 파천","병인양요","임오군란"]'::jsonb, '1', null, '''아관''은 러시아 공사관을 뜻해요.', '고종은 1896년 아관 파천으로 러시아 공사관에 약 1년간 머물렀어요.'),
  ('mid', 176, 'mc', '1897년 고종이 황제로 즉위하며 세운 나라의 이름은?', '["대한민국","조선","대한 제국","고려"]'::jsonb, '2', null, '연호는 ''광무''예요.', '고종은 경운궁(덕수궁)으로 돌아와 환구단에서 황제로 즉위하고 대한 제국을 선포했어요.'),
  ('mid', 177, 'ox', '서재필은 독립 협회를 만들고 독립문을 세웠다.', null, 'O', null, '영은문을 헐고 그 자리에 세웠어요.', '독립 협회는 독립신문을 펴내고 만민 공동회를 열어 자주독립과 민권을 외쳤어요.'),
  ('mid', 178, 'mc', '1905년 일본이 대한 제국의 외교권을 강제로 빼앗은 조약은?', '["강화도 조약","한일 병합 조약","한일 의정서","을사늑약"]'::jsonb, '3', null, '''늑약''은 억지로 맺은 조약이라는 뜻이에요.', '을사늑약으로 외교권을 빼앗기고 통감부가 설치되었으며, 초대 통감은 이토 히로부미였어요.'),
  ('mid', 179, 'ox', '고종은 을사늑약이 무효임을 알리려고 헤이그 만국 평화 회의에 특사를 보냈다.', null, 'O', null, '이준·이상설·이위종이에요.', '1907년 헤이그 특사가 파견되었지만 일본의 방해로 회의장에 들어가지 못했고, 일본은 이를 구실로 고종을 강제로 물러나게 했어요.'),
  ('mid', 180, 'mc', '1907년 나라의 빚을 국민의 힘으로 갚자며 대구에서 시작된 운동은?', '["국채 보상 운동","물산 장려 운동","브나로드 운동","새마을 운동"]'::jsonb, '0', null, '담배를 끊고 금반지를 내놓았어요.', '국채 보상 운동은 일본에 진 빚 1,300만 원을 갚자는 운동으로 전국으로 퍼졌어요.'),
  ('mid', 181, 'ox', '우리나라는 1910년 한일 병합 조약으로 국권을 빼앗겼다.', null, 'O', null, '이날을 ''경술국치''라고 해요.', '1910년 8월 29일 대한 제국은 일본에 국권을 빼앗겼어요.'),
  ('mid', 182, 'mc', '일제가 1910년대에 헌병 경찰을 앞세워 펼친 통치 방식은?', '["문화 통치","무단 통치","민족 말살 통치","탕평 정치"]'::jsonb, '1', null, '교사도 제복을 입고 칼을 찼어요.', '일제는 1910년대에 헌병 경찰제를 실시하고 조선 태형령을 만드는 등 무단 통치를 했어요.'),
  ('mid', 183, 'ox', '일제는 1910년대에 토지 조사 사업을 벌여 많은 땅을 빼앗았다.', null, 'O', null, '신고하지 않은 땅은 총독부 차지가 되었어요.', '토지 조사 사업으로 많은 농민이 땅을 잃고 소작농이 되었어요.'),
  ('mid', 184, 'mc', '3·1 운동 때 천안 아우내 장터에서 만세 운동을 이끌다 순국한 학생은?', '["윤봉길","이봉창","유관순","안중근"]'::jsonb, '2', null, '이화 학당 학생이었어요.', '유관순은 고향 천안에서 만세 운동을 이끌었고, 서대문 형무소에서 순국했어요.'),
  ('mid', 185, 'ox', '3·1 운동 뒤 일제는 통치 방식을 이른바 ''문화 통치''로 바꾸었다.', null, 'O', null, '겉으로만 부드러워졌어요.', '일제는 보통 경찰제로 바꾸고 신문 발행을 허용했지만, 실제로는 경찰 수를 늘리고 친일파를 길렀어요.'),
  ('mid', 186, 'mc', '1920년 홍범도가 이끈 독립군이 일본군을 크게 물리친 싸움은?', '["청산리 대첩","행주 대첩","쌍성보 전투","봉오동 전투"]'::jsonb, '3', null, '청산리 대첩보다 몇 달 앞서요.', '홍범도의 대한 독립군 등은 1920년 6월 봉오동에서 일본군을 크게 물리쳤어요.'),
  ('mid', 187, 'mc', '1920년 김좌진의 북로 군정서 등이 일본군을 크게 물리친 싸움은?', '["청산리 대첩","봉오동 전투","한산도 대첩","명량 대첩"]'::jsonb, '0', null, '백운평·어랑촌 등에서 6일간 싸웠어요.', '김좌진과 홍범도 등이 이끈 독립군 연합 부대는 1920년 10월 청산리에서 일본군을 크게 물리쳤어요.'),
  ('mid', 188, 'ox', '1926년 순종의 장례일에 맞추어 6·10 만세 운동이 일어났다.', null, 'O', null, '대한 제국의 마지막 황제예요.', '학생들이 중심이 되어 순종의 인산일에 만세 운동을 벌였어요.'),
  ('mid', 189, 'mc', '1929년 한국인과 일본인 학생의 충돌을 계기로 일어난 학생 항일 운동은?', '["6·10 만세 운동","광주 학생 항일 운동","4·19 혁명","3·1 운동"]'::jsonb, '1', null, '나주역 사건이 계기였어요.', '광주 학생 항일 운동은 3·1 운동 이후 가장 큰 민족 운동으로 전국에 퍼졌어요.'),
  ('mid', 190, 'mc', '1932년 상하이 훙커우 공원에서 일본군 장성들에게 폭탄을 던진 의사는?', '["이봉창","안중근","윤봉길","김구"]'::jsonb, '2', null, '한인 애국단 단원이에요.', '윤봉길 의거로 중국 국민당 정부가 대한민국 임시 정부를 적극 돕게 되었어요.'),
  ('mid', 191, 'ox', '이봉창은 도쿄에서 일본 국왕에게 폭탄을 던졌다.', null, 'O', null, '1932년 1월, 한인 애국단의 첫 의거예요.', '이봉창 의거는 비록 실패했지만 한국인의 독립 의지를 세계에 알렸어요.'),
  ('mid', 192, 'mc', '김구가 1931년 상하이에서 만든 항일 비밀 단체는?', '["의열단","신민회","독립 협회","한인 애국단"]'::jsonb, '3', null, '이봉창·윤봉길이 단원이었어요.', '김구는 침체된 임시 정부에 활기를 불어넣으려고 한인 애국단을 만들었어요.'),
  ('mid', 193, 'mc', '1919년 김원봉이 만든, 일제 기관 파괴와 요인 암살을 펼친 단체는?', '["의열단","한인 애국단","신간회","근우회"]'::jsonb, '0', null, '신채호가 「조선 혁명 선언」을 써 주었어요.', '의열단은 김상옥·나석주 등이 조선 총독부, 종로 경찰서, 동양 척식 주식회사 등을 공격했어요.'),
  ('mid', 194, 'ox', '일제는 1930년대 이후 한국인에게 일본식 이름을 쓰도록 강요하였다.', null, 'O', null, '''창씨개명''이라고 해요.', '일제는 민족 말살 통치를 펼치며 창씨개명, 신사 참배, 황국 신민 서사 암송 등을 강요했어요.'),
  ('mid', 195, 'mc', '1940년 대한민국 임시 정부가 충칭에서 만든 정규 군대는?', '["별무반","한국광복군","훈련도감","대한 독립군"]'::jsonb, '1', null, '총사령관은 지청천이에요.', '한국광복군은 연합군과 함께 싸웠고 국내 진공 작전을 준비했지만, 그 전에 광복을 맞았어요.'),
  ('mid', 196, 'ox', '1927년 민족주의자와 사회주의자가 힘을 합쳐 신간회를 만들었다.', null, 'O', null, '일제 강점기 최대의 항일 단체예요.', '신간회는 민족 협동 전선으로 만들어져 광주 학생 항일 운동 때 진상 조사단을 보내기도 했어요.'),
  ('mid', 197, 'mc', '1920년대 ''조선 사람 조선 것''이라는 구호로 우리 물건을 쓰자고 한 운동은?', '["국채 보상 운동","브나로드 운동","물산 장려 운동","새마을 운동"]'::jsonb, '2', null, '평양에서 조만식 등이 시작했어요.', '물산 장려 운동은 민족 기업을 키우려고 국산품을 애용하자는 운동이에요.'),
  ('high', 0, 'sa', '우리 역사에서 처음 세워진 나라는?', null, '고조선', '[]'::jsonb, '단군 이야기와 관련 있어요.', '고조선은 단군왕검이 세운 우리 역사 최초의 국가예요.'),
  ('high', 1, 'sa', '고구려의 영토를 크게 넓혀 이름에 ''땅을 넓혔다''는 뜻이 담긴 왕은?', null, '광개토대왕', '["광개토왕","광개토태왕"]'::jsonb, '이름에 ''넓을 광(廣)'', ''열 개(開)'', ''땅 토(土)''가 들어가요.', '광개토대왕은 만주와 한반도 북부까지 영토를 크게 넓혔어요.'),
  ('high', 2, 'sa', '고려 시대에 만들어져 지금 해인사에 보관된 불교 경판은?', null, '팔만대장경', '["고려대장경","재조대장경","8만대장경"]'::jsonb, '나무판이 무려 8만 장이 넘어요.', '팔만대장경은 부처의 힘으로 몽골의 침입을 막고자 하는 바람을 담아 만들었어요.'),
  ('high', 3, 'sa', '임진왜란 때 한산도 대첩을 승리로 이끈 장군은?', null, '이순신', '["이순신 장군","충무공"]'::jsonb, '거북선과 함께 기억되는 장군이에요.', '이순신은 학이 날개를 편 모양의 학익진 전법으로 한산도에서 왜군을 크게 이겼어요.'),
  ('high', 4, 'sa', '1919년 일제에 맞서 전국에서 일어난 만세 운동은?', null, '3·1 운동', '["삼일 운동","3·1 만세 운동","기미 독립 운동"]'::jsonb, '이 운동을 기념하는 날이 국경일이에요.', '3·1 운동은 민족 전체가 독립 의지를 세계에 알린 운동이에요.'),
  ('high', 5, 'sa', '고구려를 세운 사람은?', null, '주몽', '["동명성왕","고주몽"]'::jsonb, '활을 아주 잘 쏘았다고 전해져요.', '주몽은 고구려를 세웠어요. 온조는 백제, 박혁거세는 신라, 김수로는 가야를 세웠어요.'),
  ('high', 6, 'sa', '신라가 삼국을 통일하는 데 큰 역할을 한 장군은?', null, '김유신', '["김유신 장군"]'::jsonb, '가야 왕족의 후손으로, 김춘추와 함께 삼국 통일을 이끌었어요.', '김유신은 김춘추(태종 무열왕)와 함께 삼국 통일을 이끌었어요.'),
  ('high', 7, 'sa', '고구려가 멸망한 뒤 대조영이 세운 나라는?', null, '발해', '[]'::jsonb, '''해동성국(바다 동쪽의 번성한 나라)''이라고 불렸어요.', '대조영은 고구려 사람들을 모아 발해를 세웠어요.'),
  ('high', 8, 'sa', '고려 시대에 만들어진, 푸른빛이 도는 아름다운 도자기는?', null, '고려청자', '["청자","상감 청자"]'::jsonb, '이름에 나라 이름과 색깔이 들어 있어요.', '고려청자는 맑은 푸른빛과 상감 기법으로 세계적으로 이름난 도자기예요.'),
  ('high', 9, 'sa', '세종 때 만들어져 비가 내린 양을 재던 기구는?', null, '측우기', '[]'::jsonb, '이름에 ''비 우(雨)'' 자가 들어 있어요.', '측우기 덕분에 전국의 비 내린 양을 재서 농사에 활용할 수 있었어요.'),
  ('high', 10, 'sa', '임진왜란이 일어난 해는?', null, '1592년', '[]'::jsonb, '조선이 세워지고 약 200년 뒤예요.', '임진왜란은 1592년 일본이 조선에 쳐들어오면서 시작되었어요.'),
  ('high', 11, 'sa', '『목민심서』를 쓴 조선 후기의 실학자는?', null, '정약용', '["다산","다산 정약용"]'::jsonb, '거중기를 고안한 사람이에요.', '정약용은 백성을 다스리는 관리의 바른 자세를 『목민심서』에 담았어요.'),
  ('high', 12, 'sa', '1894년 전봉준이 이끈 농민들의 봉기는?', null, '동학 농민 운동', '["동학 농민 혁명","동학 농민 전쟁","갑오 농민 전쟁"]'::jsonb, '''사람이 곧 하늘''이라고 가르친 종교와 관련 있어요.', '동학 농민 운동은 탐관오리와 외세에 맞서 농민들이 일어난 운동이에요.'),
  ('high', 13, 'sa', '우리나라가 일제로부터 광복을 맞은 해는?', null, '1945년', '[]'::jsonb, '제2차 세계 대전이 끝난 해예요.', '우리나라는 1945년 8월 15일 광복을 맞았어요.'),
  ('high', 14, 'sa', '흥선 대원군이 왕실의 힘을 높이려고 다시 지은 궁궐은?', null, '경복궁', '[]'::jsonb, '임진왜란 때 불타 오랫동안 비어 있던 조선의 첫 궁궐이에요.', '흥선 대원군은 임진왜란 때 불탄 경복궁을 다시 지었어요.'),
  ('high', 15, 'sa', '고조선에서 사회 질서를 지키려고 만든 법으로, 지금은 3개 조항만 전해지는 것은?', null, '8조법', '["팔조법","8조금법","팔조금법","범금 8조"]'::jsonb, '법 이름에 숫자가 들어가요.', '고조선의 8조법은 ''사람을 죽인 자는 사형'', ''남을 다치게 한 자는 곡식으로 갚는다'', ''도둑질한 자는 노비로 삼는다'' 세 조항이 전해져요.'),
  ('high', 16, 'sa', '단군왕검이 세웠다고 전해지는 나라는?', null, '고조선', '[]'::jsonb, '우리 역사 최초의 나라예요.', '『삼국유사』에는 단군왕검이 고조선을 세웠다는 건국 이야기가 실려 있어요.'),
  ('high', 17, 'sa', '고조선의 건국 이야기에 나오는 ''널리 인간을 이롭게 하라''는 뜻의 이념은?', null, '홍익인간', '[]'::jsonb, '우리나라 교육 이념이기도 해요.', '홍익인간은 단군 이야기에 담긴 건국 이념으로, 지금도 대한민국 교육 이념으로 쓰여요.'),
  ('high', 18, 'sa', '고조선 때 만들어진 것으로, 고조선의 세력 범위를 알려 주는 유물은?', null, '비파형 동검', '[]'::jsonb, '악기 비파를 닮은 청동 칼이에요.', '비파형 동검과 탁자식 고인돌이 나온 지역을 보면 고조선의 세력 범위를 짐작할 수 있어요.'),
  ('high', 19, 'sa', '광개토대왕의 업적을 기록하려고 아들 장수왕이 세운 비석은?', null, '광개토대왕릉비', '["광개토왕릉비","광개토대왕비","광개토왕비"]'::jsonb, '중국 지린성 지안에 지금도 서 있어요.', '장수왕은 아버지의 업적을 기리려고 광개토대왕릉비를 세웠어요. 높이가 6m가 넘는 큰 비석이에요.'),
  ('high', 20, 'sa', '427년 수도를 평양으로 옮기고 남쪽으로 영토를 넓힌 고구려의 왕은?', null, '장수왕', '[]'::jsonb, '98세까지 살아 이름에 ''오래 살았다''는 뜻이 있어요.', '장수왕은 국내성에서 평양으로 수도를 옮기고 남진 정책을 펼쳤어요.'),
  ('high', 21, 'sa', '장수왕이 남쪽으로 영토를 넓힌 것을 보여 주는, 충청북도에 있는 고구려 비석은?', null, '충주 고구려비', '["중원 고구려비"]'::jsonb, '옛 이름은 ''중원 고구려비''예요.', '충주 고구려비는 남한에 있는 유일한 고구려 비석으로, 고구려가 남한강 유역까지 내려왔음을 보여 줘요.'),
  ('high', 22, 'sa', '고구려에서 불교를 받아들이고 태학을 세웠으며 율령을 반포한 왕은?', null, '소수림왕', '[]'::jsonb, '광개토대왕의 큰아버지예요.', '소수림왕은 372년 불교를 받아들이고 태학을 세웠으며, 373년 율령을 반포해 나라의 기틀을 다졌어요.'),
  ('high', 23, 'sa', '수나라 113만 대군을 살수에서 크게 물리친 고구려의 장군은?', null, '을지문덕', '["을지문덕 장군"]'::jsonb, '적장 우중문에게 시를 지어 보냈어요.', '을지문덕은 612년 살수(청천강)에서 수나라 군대를 크게 물리쳤어요(살수 대첩).'),
  ('high', 24, 'sa', '4세기에 백제의 전성기를 이끌고 마한을 정복한 왕은?', null, '근초고왕', '[]'::jsonb, '이름 앞에 ''근''자가 붙어요.', '근초고왕은 마한을 정복하고 고구려 평양성을 공격해 고국원왕을 전사시키는 등 백제의 전성기를 열었어요.'),
  ('high', 25, 'sa', '백제의 수도를 사비(부여)로 옮기고 나라 이름을 ''남부여''로 바꾼 왕은?', null, '성왕', '["성명왕"]'::jsonb, '관산성 싸움에서 전사했어요.', '성왕은 538년 사비로 수도를 옮기고 국호를 남부여로 바꾸며 백제의 중흥을 꾀했어요.'),
  ('high', 26, 'sa', '성왕이 신라와 싸우다 전사한 싸움은?', null, '관산성 전투', '["관산성","관산성 싸움"]'::jsonb, '554년, 지금의 충북 옥천 지역이에요.', '한강 유역을 빼앗긴 성왕은 신라를 공격했지만 관산성 전투에서 전사했어요.'),
  ('high', 27, 'sa', '660년 황산벌에서 5천 결사대를 이끌고 신라군과 싸운 백제의 장군은?', null, '계백', '["계백 장군"]'::jsonb, '싸움에 앞서 가족을 먼저 떠나보냈다고 전해져요.', '계백은 황산벌에서 김유신의 신라군에 맞서 네 번을 이겼지만 끝내 전사했고, 백제는 곧 멸망했어요.'),
  ('high', 28, 'sa', '부여에서 출토된, 백제 금속 공예의 걸작으로 꼽히는 유물은?', null, '백제 금동 대향로', '["금동 대향로","백제 금동 용봉 봉래산 향로","금동 용봉 봉래산 향로"]'::jsonb, '향을 피우던 그릇이에요.', '백제 금동 대향로는 신선이 사는 산과 봉황을 섬세하게 새긴 향로로, 백제의 뛰어난 공예 기술을 보여 줘요.'),
  ('high', 29, 'sa', '이차돈의 순교를 계기로 불교를 공인한 신라의 왕은?', null, '법흥왕', '[]'::jsonb, '율령도 반포한 왕이에요.', '법흥왕은 527년 이차돈의 순교를 계기로 불교를 공인했어요.'),
  ('high', 30, 'sa', '법흥왕 때 처음 사용한 신라의 독자적인 연호는?', null, '건원', '[]'::jsonb, '''처음 세운 으뜸''이라는 뜻이에요.', '법흥왕은 ''건원''이라는 연호를 써서 왕권이 강해졌음을 보여 줬어요.'),
  ('high', 31, 'sa', '한강 유역을 차지하고 대가야를 정복하는 등 신라의 영토를 크게 넓힌 왕은?', null, '진흥왕', '[]'::jsonb, '넓힌 땅에 순수비를 세웠어요.', '진흥왕은 한강 유역과 대가야를 차지하고 함경도까지 진출해 신라의 전성기를 열었어요.'),
  ('high', 32, 'sa', '신라 최초의 여왕으로, 첨성대와 황룡사 9층 목탑을 세운 왕은?', null, '선덕 여왕', '["선덕왕"]'::jsonb, '모란꽃 그림 이야기로 유명해요.', '선덕 여왕 때 첨성대와 황룡사 9층 목탑이 세워졌어요.'),
  ('high', 33, 'sa', '신라 지증왕 때 이사부가 정복한 곳은?', null, '우산국(울릉도)', '["우산국","울릉도"]'::jsonb, '독도와도 관련 있어요.', '512년 이사부는 우산국(울릉도)을 정복해 신라 땅으로 삼았어요.'),
  ('high', 34, 'sa', '김수로왕이 세웠다고 전해지며 철이 풍부했던 나라는?', null, '금관가야', '["가락국","본가야"]'::jsonb, '지금의 김해 지역이에요.', '금관가야는 질 좋은 철을 생산해 낙랑과 왜에 수출했어요.'),
  ('high', 35, 'sa', '고구려의 남진에 맞서 433년 신라와 백제가 맺은 동맹은?', null, '나제 동맹', '["제라 동맹"]'::jsonb, '신라(羅)와 백제(濟)의 앞 글자예요.', '나제 동맹은 장수왕의 남진 정책에 맞서 신라와 백제가 맺은 동맹으로, 약 120년 동안 이어졌어요.'),
  ('high', 36, 'sa', '648년 김춘추가 당나라에 가서 맺은 동맹은?', null, '나당 동맹', '[]'::jsonb, '신라와 당나라가 손을 잡았어요.', '김춘추는 당 태종을 만나 나당 동맹을 맺었고, 신라와 당은 함께 백제(660)와 고구려(668)를 멸망시켰어요.'),
  ('high', 37, 'sa', '나당 연합군에게 가장 먼저 멸망한 나라는?', null, '백제', '[]'::jsonb, '660년의 일이에요.', '백제는 660년, 고구려는 668년에 나당 연합군에게 멸망했어요.'),
  ('high', 38, 'sa', '676년 삼국 통일을 완성한 신라의 왕은?', null, '문무왕', '["문무대왕"]'::jsonb, '죽어서 동해의 용이 되겠다고 했어요.', '문무왕은 당군을 몰아내 676년 삼국 통일을 완성했고, 동해 바다의 대왕암에 묻혔다고 전해져요.'),
  ('high', 39, 'sa', '김흠돌의 난을 진압하고 녹읍을 폐지하는 등 왕권을 강화한 통일 신라의 왕은?', null, '신문왕', '[]'::jsonb, '만파식적 이야기와 관련 있어요.', '신문왕은 귀족 세력을 누르고 녹읍을 폐지했으며, 국학을 세우고 9주 5소경 체제를 갖췄어요.'),
  ('high', 40, 'sa', '통일 신라 원성왕 때 유교 경전 이해 수준으로 관리를 뽑으려 한 제도는?', null, '독서삼품과', '["독서출신과"]'::jsonb, '책 읽은 수준을 세 등급으로 나눴어요.', '독서삼품과는 유학 실력으로 관리를 뽑으려 한 제도지만, 진골 귀족의 반대로 큰 효과를 보지 못했어요.'),
  ('high', 41, 'sa', '청해진을 설치하고 해적을 소탕하여 바다를 주름잡은 통일 신라의 인물은?', null, '장보고', '["궁복"]'::jsonb, '''해상왕''이라고 불려요.', '장보고는 완도에 청해진을 설치해 해적을 물리치고 당·신라·일본을 잇는 해상 무역을 이끌었어요.'),
  ('high', 42, 'sa', '통일 신라 때 경주에 세워진 유네스코 세계 유산은?', null, '불국사와 석굴암', '["불국사","석굴암","불국사 석굴암"]'::jsonb, '토함산에 있어요.', '불국사와 석굴암은 통일 신라의 뛰어난 불교 예술을 보여 주는 유산으로 1995년 세계 유산이 되었어요.'),
  ('high', 43, 'sa', '''에밀레종''이라고도 불리는 통일 신라의 범종은?', null, '성덕 대왕 신종', '["봉덕사종"]'::jsonb, '경덕왕이 만들기 시작해 혜공왕 때 완성했어요.', '성덕 대왕 신종은 현재 남아 있는 우리나라 종 가운데 가장 크고, 맑고 긴 울림으로 유명해요.'),
  ('high', 44, 'sa', '900년 완산주(전주)에 도읍하여 후백제를 세운 사람은?', null, '견훤', '[]'::jsonb, '아들 신검에게 쫓겨나 고려에 항복했어요.', '견훤은 900년 후백제를 세웠지만, 뒤에 아들 신검에게 금산사에 갇혔다가 왕건에게 귀순했어요.'),
  ('high', 45, 'sa', '901년 후고구려를 세우고 나라 이름을 마진, 태봉으로 바꾼 사람은?', null, '궁예', '[]'::jsonb, '스스로 미륵불이라 했어요.', '궁예는 송악(개성)에서 후고구려를 세웠으나, 폭정 때문에 신하들에게 쫓겨났어요.'),
  ('high', 46, 'sa', '고려가 후백제를 물리쳐 후삼국 통일을 이룬 해는?', null, '936년', '[]'::jsonb, '고려가 세워지고 18년 뒤예요.', '고려는 936년 일리천 전투에서 후백제의 신검을 물리치고 후삼국을 통일했어요.'),
  ('high', 47, 'sa', '발해가 전성기에 중국으로부터 불린 이름은?', null, '해동성국', '[]'::jsonb, '''바다 동쪽의 번성한 나라''라는 뜻이에요.', '발해는 선왕 때 영토를 크게 넓혀 ''해동성국''이라 불렸어요.'),
  ('high', 48, 'sa', '장문휴를 보내 당나라의 산둥 지방을 공격한 발해의 왕은?', null, '무왕', '["대무예"]'::jsonb, '대조영의 아들이에요.', '발해 무왕은 영토를 넓히고 장문휴를 보내 당의 산둥 지방(등주)을 공격했어요.'),
  ('high', 49, 'sa', '918년 고려를 세운 사람은?', null, '왕건', '["태조 왕건"]'::jsonb, '송악(개성) 출신 호족이에요.', '왕건은 궁예를 몰아내고 918년 고려를 세웠어요.'),
  ('high', 50, 'sa', '태조 왕건이 후대 왕들에게 남긴 열 가지 가르침은?', null, '훈요 10조', '["훈요십조"]'::jsonb, '''가르침의 요점''이라는 뜻이에요.', '왕건은 훈요 10조에서 불교 숭상, 북진 정책, 서경(평양) 중시 등을 당부했어요.'),
  ('high', 51, 'sa', '태조 왕건이 지방 호족을 견제하려고 실시한 제도는?', null, '사심관 제도와 기인 제도', '["사심관 제도","기인 제도","사심관","기인","사심관과 기인"]'::jsonb, '출신 지역을 맡기고, 자제를 볼모로 삼았어요.', '사심관 제도는 고위 관리에게 출신지를 책임지게 한 것이고, 기인 제도는 호족의 자제를 수도에 머물게 한 것이에요.'),
  ('high', 52, 'sa', '거란의 침입에 대비하여 30만 명의 광군을 조직한 고려의 왕은?', null, '정종', '[]'::jsonb, '고려의 제3대 왕이에요.', '고려 정종은 947년 거란의 침입에 대비해 광군 30만 명을 조직했어요. 서경으로 수도를 옮기려고도 했어요.'),
  ('high', 53, 'sa', '노비안검법을 실시하여 억울하게 노비가 된 사람을 풀어 준 고려의 왕은?', null, '광종', '[]'::jsonb, '과거제도 실시했어요.', '광종은 956년 노비안검법으로 호족의 힘을 약화시키고 왕권을 강화했어요.'),
  ('high', 54, 'sa', '최승로의 시무 28조를 받아들여 유교 정치를 펼친 고려의 왕은?', null, '성종', '[]'::jsonb, '지방에 처음으로 12목을 설치했어요.', '성종은 시무 28조를 받아들여 유교를 정치 이념으로 삼고, 12목에 지방관을 보냈어요.'),
  ('high', 55, 'sa', '거란의 1차 침입 때 외교 담판으로 강동 6주를 얻은 인물은?', null, '서희', '[]'::jsonb, '거란 장수 소손녕과 담판했어요.', '서희는 993년 소손녕과 담판을 벌여 싸우지 않고 강동 6주를 얻었어요.'),
  ('high', 56, 'sa', '별무반을 이끌고 여진을 정벌한 뒤 동북 9성을 쌓은 고려의 장수는?', null, '윤관', '["윤관 장군"]'::jsonb, '기병이 강한 여진에 맞서 특수 부대를 만들었어요.', '윤관은 별무반을 조직해 여진을 물리치고 동북 9성을 쌓았어요.'),
  ('high', 57, 'sa', '고려가 몽골과 강화한 뒤에도 진도와 제주도로 옮겨 가며 끝까지 몽골에 맞선 부대는?', null, '삼별초', '[]'::jsonb, '좌별초·우별초·신의군을 합친 이름이에요.', '삼별초는 배중손·김통정 등의 지휘로 강화도→진도→제주도로 옮겨 가며 항쟁했어요.'),
  ('high', 58, 'sa', '원나라의 간섭에서 벗어나려고 반원 개혁을 펼친 고려의 왕은?', null, '공민왕', '[]'::jsonb, '부인은 원나라 공주 노국 대장 공주예요.', '공민왕은 친원 세력 기철 등을 없애고 원의 간섭에서 벗어나려 했어요.'),
  ('high', 59, 'sa', '공민왕이 신돈을 등용하여 빼앗긴 땅과 노비를 되돌려 주려고 설치한 기구는?', null, '전민변정도감', '[]'::jsonb, '''땅(田)과 백성(民)을 바로잡는 관청''이에요.', '전민변정도감은 권문세족이 빼앗은 토지와 노비를 원래대로 돌려놓으려고 설치한 기구예요.'),
  ('high', 60, 'sa', '고려 말 홍건적과 왜구를 물리치며 이름을 떨친 장수로, 뒤에 조선을 세운 사람은?', null, '이성계', '["태조 이성계"]'::jsonb, '황산 대첩에서 왜구를 물리쳤어요.', '이성계는 홍건적과 왜구를 물리치며 신진 무인 세력으로 성장했어요.'),
  ('high', 61, 'sa', '고려 시대 김부식이 쓴, 현재 남아 있는 우리나라에서 가장 오래된 역사책은?', null, '삼국사기', '[]'::jsonb, '인종의 명으로 1145년에 썼어요.', '『삼국사기』는 김부식이 쓴 역사책이에요. 『삼국유사』는 일연이 썼고 단군 이야기가 실려 있어요.'),
  ('high', 62, 'sa', '이성계가 요동 정벌에 나섰다가 군대를 돌려 권력을 잡은 사건은?', null, '위화도 회군', '[]'::jsonb, '압록강의 섬에서 돌아왔어요.', '이성계는 1388년 위화도에서 군대를 돌려 최영을 몰아내고 권력을 잡았어요.'),
  ('high', 63, 'sa', '조선을 세운 이성계가 수도로 정한 곳은?', null, '한양', '["한성"]'::jsonb, '지금의 서울이에요.', '이성계는 1392년 조선을 세우고 1394년 한양으로 수도를 옮겼어요.'),
  ('high', 64, 'sa', '이성계를 도와 조선을 세우고 『조선경국전』을 지은 인물은?', null, '정도전', '["삼봉","삼봉 정도전"]'::jsonb, '경복궁 이름도 지었어요.', '정도전은 조선 건국의 설계자로 한양 도성 건설과 제도 정비에 힘썼지만, 이방원에게 죽임을 당했어요.'),
  ('high', 65, 'sa', '16세 이상 남자에게 신분증을 차게 한 조선 태종(이방원)의 제도는?', null, '호패법', '[]'::jsonb, '오늘날의 주민 등록증과 비슷해요.', '태종은 호패법을 실시해 인구를 파악하고 세금과 군역을 공평하게 매기려 했어요.'),
  ('high', 66, 'sa', '이방원이 정도전 등을 없애고 권력을 잡은 사건은?', null, '제1차 왕자의 난', '["1차 왕자의 난","왕자의 난","무인정사"]'::jsonb, '1398년, 왕자들 사이의 다툼이에요.', '이방원은 1398년 제1차 왕자의 난으로 정도전과 세자 방석을 제거하고 권력을 잡았어요.'),
  ('high', 67, 'sa', '세종 때 학자들이 모여 학문을 연구하던 기관은?', null, '집현전', '[]'::jsonb, '''어진 사람들이 모인 곳''이라는 뜻이에요.', '세종은 집현전을 두어 학자들을 키웠고, 이곳 학자들이 훈민정음 창제를 도왔어요.'),
  ('high', 68, 'sa', '세종 때 장영실이 만든, 저절로 시간을 알려 주는 물시계는?', null, '자격루', '[]'::jsonb, '''스스로(自) 치는(擊) 물시계(漏)''예요.', '자격루는 정해진 시각이 되면 인형이 종·북·징을 쳐서 시간을 알려 주는 자동 물시계예요.'),
  ('high', 69, 'sa', '세종 때 펴낸, 우리 풍토에 맞는 농사법을 정리한 책은?', null, '농사직설', '[]'::jsonb, '농부들의 경험을 모아 만들었어요.', '『농사직설』은 각 지역 농민의 경험을 모아 우리 땅에 맞는 농법을 정리한 책이에요.'),
  ('high', 70, 'sa', '어린 조카 단종을 몰아내고 왕이 된 조선의 왕은?', null, '세조', '["수양 대군"]'::jsonb, '수양 대군이라고 불렸어요.', '수양 대군은 계유정난으로 권력을 잡은 뒤 단종을 몰아내고 세조가 되었어요.'),
  ('high', 71, 'sa', '1453년 수양 대군이 김종서 등을 죽이고 권력을 잡은 사건은?', null, '계유정난', '[]'::jsonb, '그해의 간지를 딴 이름이에요.', '수양 대군은 계유정난으로 김종서·황보인을 제거하고 실권을 잡았어요.'),
  ('high', 72, 'sa', '세조 때 편찬을 시작하여 성종 때 완성된 조선의 기본 법전은?', null, '경국대전', '[]'::jsonb, '''나라를 다스리는 큰 법전''이에요.', '『경국대전』은 세조 때 만들기 시작해 성종 때 완성·반포된 조선의 기본 법전이에요.'),
  ('high', 73, 'sa', '폭정을 일삼다 중종반정으로 왕위에서 쫓겨난 조선의 왕은?', null, '연산군', '[]'::jsonb, '무오사화와 갑자사화를 일으켰어요.', '연산군은 사화를 일으키고 폭정을 하다 1506년 중종반정으로 쫓겨났어요.'),
  ('high', 74, 'sa', '조선 중종 때 개혁 정치를 펼치다 기묘사화로 죽임을 당한 인물은?', null, '조광조', '[]'::jsonb, '현량과 실시를 주장했어요.', '조광조는 현량과 실시, 소격서 폐지 등 개혁을 펼쳤지만 훈구 세력의 반발로 기묘사화 때 죽었어요.'),
  ('high', 75, 'sa', '임진왜란을 일으킨 일본의 인물은?', null, '도요토미 히데요시', '["히데요시","풍신수길"]'::jsonb, '일본을 통일한 인물이에요.', '도요토미 히데요시는 일본을 통일한 뒤 1592년 조선을 침략했어요.'),
  ('high', 76, 'sa', '임진왜란 때 이순신이 13척의 배로 133척의 왜선을 물리친 싸움은?', null, '명량 대첩', '["명량 해전","명량"]'::jsonb, '울돌목에서 벌어졌어요.', '1597년 정유재란 때 이순신은 명량(울돌목)에서 13척으로 왜군을 크게 물리쳤어요.'),
  ('high', 77, 'sa', '임진왜란 때 권율이 왜군을 크게 물리친 싸움은?', null, '행주 대첩', '["행주산성 전투","행주산성 대첩"]'::jsonb, '여인들이 앞치마로 돌을 날랐다는 이야기가 있어요.', '1593년 권율은 행주산성에서 왜군을 크게 물리쳤어요.'),
  ('high', 78, 'sa', '임진왜란 때 진주성에서 왜군을 물리친 장군은?', null, '김시민', '["김시민 장군"]'::jsonb, '1592년 진주 대첩의 주인공이에요.', '김시민은 1592년 진주성에서 3,800여 명의 군사로 2만여 왜군을 물리쳤지만 전투 중 입은 상처로 숨졌어요.'),
  ('high', 79, 'sa', '임진왜란 중에 군사력을 키우려고 설치한, 포수·사수·살수로 이루어진 부대는?', null, '훈련도감', '[]'::jsonb, '조선 후기 5군영의 시작이에요.', '훈련도감은 임진왜란 중 설치된 직업 군인 부대로, 포수·사수·살수의 삼수병으로 이루어졌어요.'),
  ('high', 80, 'sa', '임진왜란 뒤 명과 후금 사이에서 중립 외교를 펼친 조선의 왕은?', null, '광해군', '[]'::jsonb, '대동법을 처음 실시한 왕이에요.', '광해군은 강홍립에게 형세를 보아 행동하라 하며 명과 후금 사이에서 실리를 챙겼어요.'),
  ('high', 81, 'sa', '광해군 때 허준이 완성한 의학책은?', null, '동의보감', '[]'::jsonb, '유네스코 세계 기록 유산이에요.', '허준의 『동의보감』은 1610년 완성된 의학책으로, 2009년 세계 기록 유산이 되었어요.'),
  ('high', 82, 'sa', '광해군을 몰아내고 인조를 왕으로 세운 사건은?', null, '인조반정', '[]'::jsonb, '1623년 서인이 일으켰어요.', '서인 세력은 1623년 인조반정으로 광해군을 몰아내고 친명배금 정책을 폈어요.'),
  ('high', 83, 'sa', '1627년 후금이 조선에 쳐들어온 전쟁은?', null, '정묘호란', '[]'::jsonb, '병자호란보다 9년 앞서요.', '정묘호란 때 인조는 강화도로 피란했고, 조선은 후금과 형제 관계를 맺었어요.'),
  ('high', 84, 'sa', '병자호란 뒤 인조가 청 태종에게 항복한 곳은?', null, '삼전도', '[]'::jsonb, '지금의 서울 송파구예요.', '인조는 1637년 남한산성에서 나와 삼전도에서 청 태종에게 항복했어요.'),
  ('high', 85, 'sa', '병자호란의 치욕을 씻으려고 청나라를 치자는 북벌을 추진한 왕은?', null, '효종', '[]'::jsonb, '봉림 대군이었어요.', '효종은 송시열 등과 북벌을 준비했지만 이루지 못했어요. 이때 키운 조총 부대는 나선 정벌에 쓰였어요.'),
  ('high', 86, 'sa', '붕당의 다툼을 막으려고 탕평책을 펴고 균역법을 실시한 왕은?', null, '영조', '[]'::jsonb, '조선에서 가장 오래 왕위에 있었어요.', '영조는 탕평비를 세우고 탕평책을 펼쳤으며, 군포를 1필로 줄인 균역법을 실시했어요.'),
  ('high', 87, 'sa', '정조가 세운 왕실 도서관이자 학문 연구 기관은?', null, '규장각', '[]'::jsonb, '서얼 출신도 검서관으로 뽑았어요.', '정조는 규장각을 세워 젊은 인재를 키우고 개혁 정치를 뒷받침하게 했어요.'),
  ('high', 88, 'sa', '1811년 평안도 차별에 맞서 일어난 농민 봉기는?', null, '홍경래의 난', '["홍경래 난","평안도 농민 전쟁"]'::jsonb, '봉기를 이끈 사람의 이름이 붙었어요.', '홍경래의 난은 서북 지방 차별과 세도 정치에 맞서 일어났어요.'),
  ('high', 89, 'sa', '흥선 대원군이 서양과 교류하지 않겠다는 뜻을 알리려고 전국에 세운 비석은?', null, '척화비', '[]'::jsonb, '''서양 오랑캐와 화친하자는 것은 나라를 파는 것이다.''', '흥선 대원군은 신미양요 뒤 척화비를 세워 통상 수교 거부 의지를 밝혔어요.'),
  ('high', 90, 'sa', '1866년 프랑스가 천주교 박해를 구실로 강화도를 침략한 사건은?', null, '병인양요', '[]'::jsonb, '외규장각 도서를 빼앗겼어요.', '병인양요 때 프랑스군은 양헌수 부대에 패해 물러가며 외규장각 도서를 약탈해 갔어요.'),
  ('high', 91, 'sa', '1876년 일본과 맺은, 우리나라 최초의 근대적 조약이자 불평등 조약은?', null, '강화도 조약', '["조일 수호 조규","강화조약","병자 수호 조약"]'::jsonb, '''조일 수호 조규''라고도 해요.', '강화도 조약으로 부산·원산·인천이 개항되었고, 일본은 해안 측량권과 치외 법권을 얻었어요.'),
  ('high', 92, 'sa', '1884년 김옥균 등 급진 개화파가 우정총국 개국 축하연에서 일으킨 정변은?', null, '갑신정변', '[]'::jsonb, '3일 만에 끝나 ''3일 천하''라고 해요.', '갑신정변은 청군의 개입으로 3일 만에 실패했어요.'),
  ('high', 93, 'sa', '을미사변 뒤 고종이 러시아 공사관으로 거처를 옮긴 사건은?', null, '아관 파천', '["노관 파천"]'::jsonb, '''아관''은 러시아 공사관을 뜻해요.', '고종은 1896년 아관 파천으로 러시아 공사관에 약 1년간 머물렀어요.'),
  ('high', 94, 'sa', '1897년 고종이 황제로 즉위하며 세운 나라의 이름은?', null, '대한 제국', '[]'::jsonb, '연호는 ''광무''예요.', '고종은 경운궁(덕수궁)으로 돌아와 환구단에서 황제로 즉위하고 대한 제국을 선포했어요.'),
  ('high', 95, 'sa', '1905년 일본이 대한 제국의 외교권을 강제로 빼앗은 조약은?', null, '을사늑약', '["을사조약","을사 보호 조약","제2차 한일 협약"]'::jsonb, '''늑약''은 억지로 맺은 조약이라는 뜻이에요.', '을사늑약으로 외교권을 빼앗기고 통감부가 설치되었으며, 초대 통감은 이토 히로부미였어요.'),
  ('high', 96, 'sa', '1907년 나라의 빚을 국민의 힘으로 갚자며 대구에서 시작된 운동은?', null, '국채 보상 운동', '[]'::jsonb, '담배를 끊고 금반지를 내놓았어요.', '국채 보상 운동은 일본에 진 빚 1,300만 원을 갚자는 운동으로 전국으로 퍼졌어요.'),
  ('high', 97, 'sa', '일제가 1910년대에 헌병 경찰을 앞세워 펼친 통치 방식은?', null, '무단 통치', '["헌병 경찰 통치"]'::jsonb, '교사도 제복을 입고 칼을 찼어요.', '일제는 1910년대에 헌병 경찰제를 실시하고 조선 태형령을 만드는 등 무단 통치를 했어요.'),
  ('high', 98, 'sa', '3·1 운동 때 천안 아우내 장터에서 만세 운동을 이끌다 순국한 학생은?', null, '유관순', '["유관순 열사"]'::jsonb, '이화 학당 학생이었어요.', '유관순은 고향 천안에서 만세 운동을 이끌었고, 서대문 형무소에서 순국했어요.'),
  ('high', 99, 'sa', '1920년 홍범도가 이끈 독립군이 일본군을 크게 물리친 싸움은?', null, '봉오동 전투', '["봉오동 대첩","봉오동"]'::jsonb, '청산리 대첩보다 몇 달 앞서요.', '홍범도의 대한 독립군 등은 1920년 6월 봉오동에서 일본군을 크게 물리쳤어요.'),
  ('high', 100, 'sa', '1920년 김좌진의 북로 군정서 등이 일본군을 크게 물리친 싸움은?', null, '청산리 대첩', '["청산리 전투","청산리"]'::jsonb, '백운평·어랑촌 등에서 6일간 싸웠어요.', '김좌진과 홍범도 등이 이끈 독립군 연합 부대는 1920년 10월 청산리에서 일본군을 크게 물리쳤어요.'),
  ('high', 101, 'sa', '1929년 한국인과 일본인 학생의 충돌을 계기로 일어난 학생 항일 운동은?', null, '광주 학생 항일 운동', '["광주 학생 운동","광주 학생 독립 운동"]'::jsonb, '나주역 사건이 계기였어요.', '광주 학생 항일 운동은 3·1 운동 이후 가장 큰 민족 운동으로 전국에 퍼졌어요.'),
  ('high', 102, 'sa', '1932년 상하이 훙커우 공원에서 일본군 장성들에게 폭탄을 던진 의사는?', null, '윤봉길', '["윤봉길 의사","매헌"]'::jsonb, '한인 애국단 단원이에요.', '윤봉길 의거로 중국 국민당 정부가 대한민국 임시 정부를 적극 돕게 되었어요.'),
  ('high', 103, 'sa', '김구가 1931년 상하이에서 만든 항일 비밀 단체는?', null, '한인 애국단', '[]'::jsonb, '이봉창·윤봉길이 단원이었어요.', '김구는 침체된 임시 정부에 활기를 불어넣으려고 한인 애국단을 만들었어요.'),
  ('high', 104, 'sa', '1919년 김원봉이 만든, 일제 기관 파괴와 요인 암살을 펼친 단체는?', null, '의열단', '[]'::jsonb, '신채호가 「조선 혁명 선언」을 써 주었어요.', '의열단은 김상옥·나석주 등이 조선 총독부, 종로 경찰서, 동양 척식 주식회사 등을 공격했어요.'),
  ('high', 105, 'sa', '1940년 대한민국 임시 정부가 충칭에서 만든 정규 군대는?', null, '한국광복군', '["광복군"]'::jsonb, '총사령관은 지청천이에요.', '한국광복군은 연합군과 함께 싸웠고 국내 진공 작전을 준비했지만, 그 전에 광복을 맞았어요.'),
  ('high', 106, 'sa', '1920년대 ''조선 사람 조선 것''이라는 구호로 우리 물건을 쓰자고 한 운동은?', null, '물산 장려 운동', '[]'::jsonb, '평양에서 조만식 등이 시작했어요.', '물산 장려 운동은 민족 기업을 키우려고 국산품을 애용하자는 운동이에요.');
