-- 강제 종료 → 새 방, 이전 학생 다시 초대.
\set ON_ERROR_STOP on
\pset pager off
set client_min_messages = notice;

do $$
declare
  v jsonb; old_code text; old_tok uuid; nv jsonb; nv2 jsonb; new_code text; new_tok uuid;
  a jsonb; b jsonb; c jsonb; s jsonb; r jsonb; ok boolean := false;
begin
  v := host_create_room(); old_code := v ->> 'code'; old_tok := (v ->> 'hostToken')::uuid;
  perform host_set_level(old_code, old_tok, 'mid');
  a := play_join(old_code, '민수', 'cheong');
  b := play_join(old_code, '지아', 'red');
  c := play_join(old_code, '서준', 'red');
  perform host_start(old_code, old_tok);
  update players set score = 3 where room_code = old_code and name = '민수';

  -- 강제 종료하면 옛 방은 최종 결과, 새 방이 생긴다
  nv := host_new_room(old_code, old_tok);
  new_code := nv ->> 'code'; new_tok := (nv ->> 'hostToken')::uuid;
  assert new_code <> old_code, '새 방 코드는 다르다';
  assert nv -> 'finished' ->> 'phase' = 'final', '옛 방은 최종 결과로 끝난다';
  assert (nv -> 'finished' -> 'ranking' -> 0 ->> 'name') = '민수', '최종 순위는 옛 방에 남는다';
  assert nv -> 'snapshot' ->> 'phase' = 'lobby', '새 방은 대기실';
  assert nv -> 'snapshot' ->> 'level' = 'mid', '단계를 이어받는다';
  assert nv -> 'snapshot' ->> 'prevCode' = old_code;
  assert jsonb_array_length(nv -> 'snapshot' -> 'prev') = 3, '이전 방 학생 명단이 보인다';
  assert (select count(*) from participation) >= 1, '참여 기록이 남는다';

  -- 두 번 눌러도 새 방은 하나
  nv2 := host_new_room(old_code, old_tok);
  assert nv2 ->> 'code' = new_code and nv2 ->> 'hostToken' = new_tok::text, '같은 새 방을 돌려준다';

  -- 다른 사람은 초대할 수 없다
  begin perform host_invite(new_code, old_tok); exception when raise_exception then ok := true; end;
  assert ok, '새 방 진행자 열쇠가 있어야 초대할 수 있다';

  -- 한 명만 초대
  s := host_invite(new_code, new_tok, (b ->> 'playerId')::uuid);
  assert (select invited_to from players where id = (b->>'playerId')::uuid) = new_code;
  assert (select invited_to from players where id = (a->>'playerId')::uuid) is null, '다른 학생은 아직';
  s := get_snapshot(old_code, (b ->> 'playerToken')::uuid);
  assert s -> 'you' ->> 'invite' = new_code, '초대받은 학생 화면에 초대가 보인다';
  s := get_snapshot(old_code, (a ->> 'playerToken')::uuid);
  assert s -> 'you' ->> 'invite' is null;

  -- 초대를 받아 옮겨 간다
  r := play_accept_invite((b ->> 'playerToken')::uuid);
  assert r ->> 'code' = new_code;
  assert (select room_code from players where id = (r->>'playerId')::uuid) = new_code;
  assert (select name || color from players where id = (r->>'playerId')::uuid)
       = (select name || color from players where id = (b->>'playerId')::uuid), '이름과 색을 그대로';
  assert (select score from players where id = (r->>'playerId')::uuid) = 0, '점수는 새로 시작';
  assert (select moved from players where id = (b->>'playerId')::uuid);
  s := get_snapshot(old_code, (b ->> 'playerToken')::uuid);
  assert s -> 'you' ->> 'invite' is null, '옮긴 뒤에는 초대가 사라진다';
  ok := false;
  begin perform play_accept_invite((b ->> 'playerToken')::uuid); exception when raise_exception then ok := true; end;
  assert ok, '두 번 옮길 수 없다';
  ok := false;
  begin perform play_accept_invite((a ->> 'playerToken')::uuid); exception when raise_exception then ok := true; end;
  assert ok, '초대받지 않으면 옮길 수 없다';

  -- 나머지 모두 초대(이미 옮긴 학생은 건드리지 않는다)
  s := host_invite(new_code, new_tok);
  assert (select count(*) from players where room_code = old_code and invited_to = new_code) = 3;
  assert (select count(*) from jsonb_array_elements(s -> 'prev') e where (e ->> 'moved')::boolean) = 1;
  perform play_accept_invite((a ->> 'playerToken')::uuid);
  perform play_accept_invite((c ->> 'playerToken')::uuid);
  assert (select count(*) from players where room_code = new_code) = 3, '셋 다 새 방에 왔다';

  -- 새 방에서 다시 강제 종료하면 또 새 방
  perform host_start(new_code, new_tok);
  nv2 := host_new_room(new_code, new_tok);
  assert nv2 ->> 'code' not in (old_code, new_code), '강제 종료할 때마다 새 방';
  assert jsonb_array_length(nv2 -> 'snapshot' -> 'prev') = 3;

  -- 옛 방이 정리되면 고리도 끊긴다
  delete from rooms where code = old_code;
  assert (select prev_code from rooms where code = new_code) is null;
  ok := false;
  begin perform host_invite(new_code, new_tok); exception when raise_exception then ok := true; end;
  assert ok, '이전 방이 없으면 초대할 수 없다';

  delete from rooms where code in (new_code, nv2 ->> 'code');
  raise notice '새 방·다시 초대 테스트 통과';
end $$;
