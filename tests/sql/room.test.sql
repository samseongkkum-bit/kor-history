-- 방 운영: 정원, 재접속, 중간 입장, 위치 검증, 힌트, 출제 순환, 빈 방 정리.
\set ON_ERROR_STOP on
\pset pager off
set client_min_messages = notice;

/* ---------- 정원 30명 ---------- */
do $$
declare v jsonb; v_code text; i int; ok boolean := false;
begin
  v := host_create_room(); v_code := v ->> 'code';
  for i in 1..30 loop perform play_join(v_code, '학생' || i, 'red'); end loop;
  assert (select count(*) from players where room_code = v_code) = 30, '30명까지 들어온다';
  -- 모두 'red'를 달라고 했어도 저고리 색은 서로 겹치지 않는다
  assert (select count(distinct color) from players where room_code = v_code) = 30, '30명의 색이 모두 다르다';
  assert (select bool_and(color = any(hq_colors())) from players where room_code = v_code), '정해진 색 목록 안에서 준다';
  begin
    perform play_join(v_code, '서른한번째', 'red');
  exception when raise_exception then ok := true;
  end;
  assert ok, '31번째는 들어올 수 없다';
  delete from rooms where code = v_code;
  raise notice '정원 테스트 통과';
end $$;

/* ---------- 이름 ---------- */
do $$
declare v jsonb; v_code text;
begin
  v := host_create_room(); v_code := v ->> 'code';
  v := play_join(v_code, '민수', 'red');
  assert (select name from players where id = (v->>'playerId')::uuid) = '민수';
  v := play_join(v_code, '민수', 'red');
  assert (select name from players where id = (v->>'playerId')::uuid) = '민수2', '같은 이름이면 숫자를 붙인다';
  v := play_join(v_code, '가나다라마바사아자차', 'red');
  assert (select name from players where id = (v->>'playerId')::uuid) = '가나다라마바사아', '이름은 8자까지';
  v := play_join(v_code, '   ', 'red');
  assert (select name from players where id = (v->>'playerId')::uuid) = '친구', '비어 있으면 기본 이름';
  delete from rooms where code = v_code;
  raise notice '이름 테스트 통과';
end $$;

/* ---------- 재접속 ---------- */
do $$
declare v jsonb; v_code text; t uuid; id1 uuid; v2 jsonb;
begin
  v := host_create_room(); v_code := v ->> 'code';
  v := play_join(v_code, '민수', 'red');
  t := (v->>'playerToken')::uuid; id1 := (v->>'playerId')::uuid;
  update players set score = 7, bonus = 2.5 where id = id1;
  perform play_leave(t);
  assert not (select connected from players where id = id1), '화면을 닫으면 연결 끊김으로 표시된다';

  v2 := play_join(v_code, '다른이름', 'cheong', t);
  assert (v2->>'rejoined')::boolean, '같은 기기면 재접속으로 본다';
  assert (v2->>'playerId')::uuid = id1, '같은 학생이다';
  assert (select name from players where id = id1) = '민수', '이름이 그대로';
  assert (select score from players where id = id1) = 7, '점수가 그대로';
  assert (select count(*) from players where room_code = v_code) = 1, '사람이 늘지 않는다';
  assert (v2 -> 'snapshot' -> 'you' ->> 'score')::int = 7, '본인 상황도 함께 온다';

  -- 모르는 열쇠면 새 학생
  v2 := play_join(v_code, '민수', 'red', gen_random_uuid());
  assert not (v2->>'rejoined')::boolean and (select name from players where id = (v2->>'playerId')::uuid) = '민수2';
  delete from rooms where code = v_code;
  raise notice '재접속 테스트 통과';
end $$;

/* ---------- 중간 입장 ---------- */
do $$
declare v jsonb; v_code text; v_host uuid; ta uuid; tb uuid; ib uuid;
begin
  v := host_create_room(); v_code := v->>'code'; v_host := (v->>'hostToken')::uuid;
  v := play_join(v_code, '먼저', 'red'); ta := (v->>'playerToken')::uuid;
  perform host_start(v_code, v_host);

  v := play_join(v_code, '나중', 'red'); ib := (v->>'playerId')::uuid; tb := (v->>'playerToken')::uuid;
  assert (select pending from players where id = ib), '문제 도중에 들어오면 이번 문제는 쉰다';
  assert not (play_lock(tb) ->> 'ok')::boolean, '쉬는 중에는 결정할 수 없다';

  perform t_expire(v_code);
  perform grade_question(v_code);
  assert not exists (select 1 from answers where player_id = ib), '쉰 학생은 채점하지 않는다';
  assert (select score from players where id = ib) = 0;

  perform host_next(v_code, v_host);
  assert not (select pending from players where id = ib), '다음 문제부터는 함께 푼다';
  delete from rooms where code = v_code;
  raise notice '중간 입장 테스트 통과';
end $$;

/* ---------- 위치 ---------- */
do $$
declare v jsonb; v_code text; t uuid; id1 uuid; x double precision; y double precision; d double precision;
begin
  v := host_create_room(); v_code := v->>'code';
  v := play_join(v_code, '민수', 'red'); t := (v->>'playerToken')::uuid; id1 := (v->>'playerId')::uuid;

  -- 마당 밖으로는 못 나간다
  update players set pos_at = now() - interval '5 seconds' where id = id1;
  v := play_move(t, -9999, -9999);
  assert (v->>'x')::float8 >= 60 and (v->>'y')::float8 >= 136, '왼쪽 위로 못 나간다: ' || v::text;
  update players set pos_at = now() - interval '5 seconds' where id = id1;
  v := play_move(t, 9999, 9999);
  assert (v->>'x')::float8 <= 900 and (v->>'y')::float8 <= 546, '오른쪽 아래로 못 나간다: ' || v::text;

  -- 걷는 속도보다 빠른 이동은 그만큼만 인정한다
  update players set pos_x = 480, pos_y = 540, pos_at = now() where id = id1;
  v := play_move(t, 100, 150);
  d := sqrt(((v->>'x')::float8 - 480)^2 + ((v->>'y')::float8 - 540)^2);
  assert d < 80, '한 번에 ' || round(d::numeric) || 'px 밖에 못 간다';

  -- 천천히 여러 번이면 도착한다
  for x in 1..20 loop
    update players set pos_at = now() - interval '300 milliseconds' where id = id1;
    v := play_move(t, 100, 150);
  end loop;
  assert sqrt(((v->>'x')::float8 - 100)^2 + ((v->>'y')::float8 - 150)^2) < 5, '제대로 걸어가면 도착한다';
  delete from rooms where code = v_code;
  raise notice '위치 테스트 통과';
end $$;

/* ---------- 힌트와 결정 ---------- */
do $$
declare v jsonb; v_code text; v_host uuid; t uuid; id1 uuid; v_hint text; v_type text; v_ans text;
begin
  v := host_create_room(); v_code := v->>'code'; v_host := (v->>'hostToken')::uuid;
  v := play_join(v_code, '민수', 'red'); t := (v->>'playerToken')::uuid; id1 := (v->>'playerId')::uuid;
  perform host_start(v_code, v_host);

  select rs.round -> 0 ->> 'hint', rs.round -> 0 ->> 'type', rs.round -> 0 ->> 'answer'
    into v_hint, v_type, v_ans from room_secrets rs where rs.code = v_code;

  -- 힌트는 물어본 학생에게만, 방 상황에는 섞이지 않는다
  assert play_hint(t) ->> 'hint' = v_hint, '힌트를 받는다';
  assert (select hint_used from players where id = id1), '힌트를 본 것이 기록된다';
  assert position(v_hint in get_snapshot(v_code, null)::text) = 0, '힌트가 방 상황에 섞이지 않는다';

  -- 자리 밖에서는 결정할 수 없다
  assert (play_lock(t) ->> 'reason') = 'zone', '출발 지점에서는 결정할 수 없다';

  -- 자리 안에서는 결정할 수 있고, 두 번은 안 된다
  update players set pos_at = now() - interval '5 seconds' where id = id1;
  perform play_move(t, (t_center(v_type, v_ans))[1], (t_center(v_type, v_ans))[2]);
  assert (play_lock(t) ->> 'ok')::boolean, '자리 안에서는 결정할 수 있다';
  assert not (play_lock(t) ->> 'ok')::boolean, '두 번 결정할 수는 없다';

  -- 마감 뒤에는 결정할 수 없다
  perform t_expire(v_code);
  update players set locked_x = null, locked_y = null, locked_at = null where id = id1;
  assert not (play_lock(t) ->> 'ok')::boolean, '시간이 지나면 결정할 수 없다';
  delete from rooms where code = v_code;
  raise notice '힌트·결정 테스트 통과';
end $$;

/* ---------- 출제 순환 ---------- */
do $$
declare v_used jsonb := '{}'::jsonb; v_built jsonb; seen int[] := '{}'::int[]; i int; v_round jsonb; n int;
begin
  for i in 1..3 loop
    v_built := hq_build_round('elem', v_used);
    v_used := v_built -> 'used';
    v_round := v_built -> 'round';
    assert jsonb_array_length(v_round) = 10, '한 판은 10문제';
    for n in 0..9 loop seen := seen || ((v_round -> n ->> 'src')::int); end loop;
  end loop;
  assert array_length(seen, 1) = 30, '3판에 30문제';
  assert (select count(distinct x) from unnest(seen) x) = 30, '30문제를 한 바퀴 도는 동안 겹치지 않는다';

  -- 네 번째 판도 10문제가 나온다
  v_built := hq_build_round('elem', v_used);
  assert jsonb_array_length(v_built -> 'round') = 10, '한 바퀴 뒤에도 10문제';
  raise notice '출제 순환 테스트 통과';
end $$;

/* ---------- 중등부: 문제가 많아도 한 바퀴 돌 때까지 겹치지 않는다 ---------- */
do $$
declare v_used jsonb := '{}'::jsonb; v_built jsonb; seen int[] := '{}'::int[]; v_total int; i int; n int;
begin
  select count(*) into v_total from questions where level = 'mid';
  assert v_total >= 100, '중등부 문제는 100개 이상';
  for i in 1..(v_total / 10) loop
    v_built := hq_build_round('mid', v_used);
    v_used := v_built -> 'used';
    for n in 0..9 loop seen := seen || ((v_built -> 'round' -> n ->> 'src')::int); end loop;
  end loop;
  assert (select count(distinct x) from unnest(seen) x) = array_length(seen, 1),
         '중등부 ' || array_length(seen, 1) || '문제가 한 번도 겹치지 않는다';
  raise notice '중등부 출제 순환 테스트 통과 (문제 %개, %판)', v_total, v_total / 10;
end $$;

/* ---------- 객관식 보기 섞기 ---------- */
do $$
declare v_built jsonb; v_round jsonb; q jsonb; i int; src int; orig jsonb; checked int := 0; r int;
begin
  for r in 1..30 loop
    v_built := hq_build_round('mid', '{}'::jsonb);
    v_round := v_built -> 'round';
    for i in 0..9 loop
      q := v_round -> i;
      if q ->> 'type' <> 'mc' then continue; end if;
      src := (q ->> 'src')::int;
      select to_jsonb(x) into orig from questions x where level = 'mid' and idx = src;
      assert (q -> 'choices' ->> (q ->> 'answer')::int) = (orig -> 'choices' ->> (orig ->> 'answer')::int),
             '보기를 섞어도 정답 내용은 같다: ' || (q ->> 'q');
      assert (select count(distinct value) from jsonb_array_elements_text(q -> 'choices')) = 4, '보기 4개가 그대로';
      assert q ->> 'q' = orig ->> 'q', '문제 문구는 바뀌지 않는다';
      checked := checked + 1;
    end loop;
  end loop;
  assert checked > 50, '객관식 ' || checked || '개를 확인했다';
  raise notice '보기 섞기 테스트 통과 (객관식 %개 확인)', checked;
end $$;

/* ---------- 여러 방과 빈 방 정리 ---------- */
do $$
declare codes text[] := '{}'; v jsonb; i int; v_code text; n int;
begin
  for i in 1..20 loop v := host_create_room(); codes := codes || (v ->> 'code'); end loop;
  assert (select count(distinct x) from unnest(codes) x) = 20, '방 코드가 겹치지 않는다';
  foreach v_code in array codes loop
    assert v_code ~ '^\d{4}$', '코드는 숫자 4자리';
    assert get_snapshot(v_code, null) is not null, '코드로 방을 찾을 수 있다';
  end loop;

  -- 오래된 방은 정리된다
  update rooms set last_seen = now() - interval '20 minutes' where code = codes[1];
  perform hq_sweep();
  assert get_snapshot(codes[1], null) is null, '아무도 없이 오래된 방은 정리된다';
  assert get_snapshot(codes[2], null) is not null, '방금 만든 방은 남는다';

  delete from rooms where code = any(codes);
  raise notice '여러 방·정리 테스트 통과';
end $$;

/* ---------- 강제 종료 ---------- */
do $$
declare v jsonb; v_code text; v_host uuid; t uuid; v_snap jsonb;
begin
  v := host_create_room(); v_code := v->>'code'; v_host := (v->>'hostToken')::uuid;
  v := play_join(v_code, '민수', 'red'); t := (v->>'playerToken')::uuid;
  perform host_start(v_code, v_host);
  update players set score = 30 where room_code = v_code;
  perform host_end(v_code, v_host);
  v_snap := get_snapshot(v_code, null);
  assert v_snap ->> 'phase' = 'final', '강제 종료하면 최종 결과';
  assert (v_snap -> 'ranking' -> 0 ->> 'score')::int = 30;
  assert (v_snap -> 'ranking' -> 0 ->> 'title') = '양민', '30점은 양민';
  delete from rooms where code = v_code;
  raise notice '강제 종료 테스트 통과';
end $$;

/* ---------- 내보내기 ---------- */
do $$
declare v jsonb; v_code text; v_host uuid; id1 uuid;
begin
  v := host_create_room(); v_code := v->>'code'; v_host := (v->>'hostToken')::uuid;
  v := play_join(v_code, '장난이', 'red'); id1 := (v->>'playerId')::uuid;
  perform play_join(v_code, '민수', 'red');
  perform host_kick(v_code, v_host, id1);
  assert (select count(*) from players where room_code = v_code) = 1, '내보낸 학생은 사라진다';
  assert not exists (select 1 from player_secrets where player_id = id1), '열쇠도 함께 지워진다';
  delete from rooms where code = v_code;
  raise notice '내보내기 테스트 통과';
end $$;

/* ---------- 칭호 ---------- */
do $$
declare want text[] := array['천민','천민','천민','양민','양민','평민','평민','귀족','귀족','조선의 학자','왕']; i int;
begin
  for i in 0..10 loop
    assert hq_title(i * 10) = want[i + 1], (i * 10) || '점은 ' || want[i + 1];
  end loop;
  raise notice '칭호 테스트 통과';
end $$;
