-- 권한 테스트: 학생(anon)이 정답·힌트·열쇠를 직접 들여다볼 수 없어야 한다.
\set ON_ERROR_STOP on
\pset pager off
set client_min_messages = notice;

-- 테스트용 방 하나
do $$
declare v jsonb;
begin
  v := host_create_room();
  perform play_join(v ->> 'code', '권한이', 'red');
  perform set_config('test.code', v ->> 'code', false);
  perform set_config('test.host', v ->> 'hostToken', false);
end $$;

set role anon;

do $$
declare n int; v jsonb; v_code text;
begin
  v_code := current_setting('test.code');

  /* ---- 읽을 수 있어야 하는 것 ---- */
  select count(*) into n from levels;      assert n = 2, '단계 목록은 볼 수 있다';
  select count(*) into n from rooms;       assert n >= 1, '방의 겉 상태는 볼 수 있다';
  select count(*) into n from players;     assert n >= 1, '학생 이름·색·점수는 볼 수 있다';

  /* ---- 읽으면 안 되는 것 ---- */
  select count(*) into n from questions;      assert n = 0, '문제(정답·해설·힌트)는 못 읽는다';
  select count(*) into n from room_secrets;   assert n = 0, '이번 판 문제와 진행자 열쇠는 못 읽는다';
  select count(*) into n from player_secrets; assert n = 0, '학생 열쇠는 못 읽는다';
  select count(*) into n from answers;        assert n = 0, '남의 답은 못 읽는다';
  select count(*) into n from participation;  assert n = 0, '참여 기록은 못 읽는다';

  /* ---- 쓰면 안 되는 것 ---- */
  begin
    update players set score = 999 where room_code = v_code;
    assert (select max(score) from players where room_code = v_code) = 0, '점수를 직접 고칠 수 없다';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into rooms(code) values ('9999');
    assert not exists (select 1 from rooms where code = '9999'), '방을 직접 만들 수 없다';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from players where room_code = v_code;
    assert exists (select 1 from players where room_code = v_code), '남을 직접 내보낼 수 없다';
  exception when insufficient_privilege then null;
  end;

  /* ---- 안에서만 쓰는 함수는 부를 수 없다 ---- */
  begin
    perform hq_build_round('elem', '{}'::jsonb);
    raise exception '출제 함수를 손님이 부를 수 있으면 안 된다';
  exception when insufficient_privilege then null;
  end;
  begin
    perform hq_next_question(v_code);
    raise exception '문제 넘기기 함수를 손님이 부를 수 있으면 안 된다';
  exception when insufficient_privilege then null;
  end;

  /* ---- 진행자 열쇠가 없으면 진행자 노릇을 못 한다 ---- */
  begin
    perform host_start(v_code, gen_random_uuid());
    raise exception '아무나 게임을 시작하면 안 된다';
  exception when raise_exception then null;
  end;
  begin
    perform host_end(v_code, gen_random_uuid());
    raise exception '아무나 게임을 끝내면 안 된다';
  exception when raise_exception then null;
  end;

  /* ---- 손님이 부를 수 있어야 하는 함수 ---- */
  assert get_levels() is not null, '단계 목록 함수는 부를 수 있다';
  assert get_snapshot(v_code, null) is not null, '지금 상황은 볼 수 있다';
  v := play_join(v_code, '또다른이', 'cheong');
  assert v ->> 'playerToken' is not null, '입장은 할 수 있다';

  /* ---- 지금 상황에 정답이 섞여 나가지 않는다 ---- */
  assert not (get_snapshot(v_code, null)::text like '%"answer"%'), '대기실 상황에 정답이 없다';

  raise notice '권한 테스트 통과';
end $$;

reset role;
delete from rooms where code = current_setting('test.code');

/* ---------- Supabase 처럼 anon 에게 직접 권한이 붙어 있어도 내부 함수는 막힌다 ---------- */
do $$
begin
  assert not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like 'hq\_%'
       and has_function_privilege('anon', p.oid, 'execute')
  ), '안에서만 쓰는 hq_* 함수는 anon 이 부를 수 없다';
  assert has_function_privilege('anon', 'host_new_room(text,uuid)', 'execute');
  assert has_function_privilege('anon', 'play_accept_invite(uuid)', 'execute');
  raise notice '내부 함수 권한 테스트 통과';
end $$;
