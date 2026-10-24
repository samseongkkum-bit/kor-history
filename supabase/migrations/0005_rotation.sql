-- 이미 낸 문제를 방이 아니라 단계별로 기억한다.
-- 진행자 화면을 새로고침해 방을 새로 만들어도, 문제 은행을 한 바퀴 다 돌 때까지 같은 문제가 다시 나오지 않는다.

create table if not exists question_rotation (
  level text primary key references levels(key) on delete cascade,
  used  jsonb not null default '{}'::jsonb      -- hq_build_round 가 쓰는 모양 그대로: {"<level>": [idx, ...]}
);
alter table question_rotation enable row level security;   -- 정책이 없으니 손님은 읽지도 쓰지도 못한다

create or replace function host_start(p_code text, p_token uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_level text; v_used jsonb; v_built jsonb;
begin
  perform hq_check_host(p_code, p_token);
  select r.level into v_level from rooms r where r.code = p_code;

  -- 여러 방이 동시에 시작해도 같은 기록을 겹쳐 쓰지 않게 줄을 잠근다.
  insert into question_rotation(level) values (v_level) on conflict do nothing;
  select qr.used into v_used from question_rotation qr where qr.level = v_level for update;

  v_built := hq_build_round(v_level, coalesce(v_used, '{}'::jsonb));
  update question_rotation set used = v_built -> 'used' where level = v_level;
  update room_secrets set round = v_built -> 'round', used = v_built -> 'used' where code = p_code;

  delete from answers where room_code = p_code;
  update players set score = 0, bonus = 0, pending = false where room_code = p_code;
  update rooms set q_index = -1, graded_index = -1, q_total = jsonb_array_length(v_built -> 'round')
   where code = p_code;

  perform hq_next_question(p_code);
  return get_snapshot(p_code, null);
end $$;
