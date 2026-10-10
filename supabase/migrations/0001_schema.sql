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
