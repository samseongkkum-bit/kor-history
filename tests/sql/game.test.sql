-- Supabase 함수 테스트. psql 로 실행하며, 하나라도 어긋나면 그 자리에서 멈춘다.
-- 실행: npm run test:sql
\set ON_ERROR_STOP on
\pset pager off
\set QUIET on
set client_min_messages = notice;

-- 테스트 중에는 시간을 기다리지 않고 마감 시각을 앞당겨서 채점한다.
create or replace function t_expire(p_code text) returns void language plpgsql as $$
declare v_delta interval;
begin
  -- 문제 시작·마감·결정 시각을 통째로 앞으로 당겨, 제한 시간이 막 지난 상태를 만든다
  select (r.ends_at - now()) + interval '10 milliseconds' into v_delta from rooms r where r.code = p_code;
  update rooms  set started_at = started_at - v_delta, ends_at = ends_at - v_delta where code = p_code;
  update players set locked_at = locked_at - v_delta where room_code = p_code and locked_at is not null;
end $$;

-- 학생을 그 자리까지 "걸어가게" 한다(충분한 시간이 지난 것으로 두어 속도 제한을 통과).
create or replace function t_walk(p_token uuid, p_x double precision, p_y double precision) returns void
language plpgsql as $$
begin
  update players set pos_at = now() - interval '3 seconds'
   where id = (select player_id from player_secrets where token = p_token);
  perform play_move(p_token, p_x, p_y);
end $$;

-- "문제가 시작되고 p_secs 초 뒤에 결정을 눌렀다"로 맞춰 준다(보너스 계산을 보려고).
create or replace function t_lock(p_token uuid, p_secs double precision) returns jsonb
language plpgsql as $$
declare v jsonb; v_id uuid;
begin
  v := play_lock(p_token);
  select player_id into v_id from player_secrets where token = p_token;
  update players pl set locked_at = r.started_at + make_interval(secs => p_secs)
    from rooms r where pl.id = v_id and r.code = pl.room_code;
  return v;
end $$;

-- 돗자리 가운데 좌표
create or replace function t_center(p_type text, p_key text) returns double precision[]
language sql immutable as $$
  select case
    when p_type = 'ox' then case when p_key = 'O' then array[260,320] else array[700,320] end
    when p_key = '0' then array[260,220] when p_key = '1' then array[700,220]
    when p_key = '2' then array[260,390] else array[700,390] end::double precision[]
$$;

do $$
declare
  v jsonb; v_code text; v_host uuid;
  ta uuid; tb uuid; tc uuid; ia uuid; ib uuid; ic uuid;
  i int; v_type text; v_right text; v_wrong text; c double precision[];
  v_snap jsonb; v_rank jsonb; v_q jsonb; v_part_before int; v_today_before int;
begin
  select count(*) into v_part_before from participation;
  v_today_before := get_today_total();
  /* ---------- 방과 학생 ---------- */
  v := host_create_room();
  v_code := v ->> 'code'; v_host := (v ->> 'hostToken')::uuid;

  v := play_join(v_code, '가', 'red');      ia := (v ->> 'playerId')::uuid; ta := (v ->> 'playerToken')::uuid;
  v := play_join(v_code, '나', 'cheong');   ib := (v ->> 'playerId')::uuid; tb := (v ->> 'playerToken')::uuid;
  v := play_join(v_code, '다', 'hwang');    ic := (v ->> 'playerId')::uuid; tc := (v ->> 'playerToken')::uuid;

  assert (get_snapshot(v_code, null) ->> 'count')::int = 3, '학생 3명이 들어와야 한다';
  assert (get_snapshot(v_code, null) ->> 'phase') = 'lobby', '아직 대기실이어야 한다';

  /* ---------- 이름 중복 ---------- */
  v := play_join(v_code, '가', 'red');
  assert (select name from players where id = (v ->> 'playerId')::uuid) = '가2', '같은 이름이면 숫자를 붙인다';
  delete from players where id = (v ->> 'playerId')::uuid;

  /* ---------- 한 판 ---------- */
  perform host_set_level(v_code, v_host, 'elem');
  perform host_start(v_code, v_host);
  assert (get_snapshot(v_code, null) ->> 'phase') = 'question', '게임이 시작돼야 한다';

  for i in 0..9 loop
    select rs.round -> i ->> 'type', rs.round -> i ->> 'answer'
      into v_type, v_right from room_secrets rs where rs.code = v_code;
    v_wrong := case when v_right = 'O' then 'X' else 'O' end;

    assert (get_snapshot(v_code, null) ->> 'qIndex')::int = i, i || '번 문제여야 한다';

    -- 문제를 내보낼 때 정답·해설·힌트가 섞여 나가면 안 된다
    v_q := get_snapshot(v_code, null) -> 'question';
    assert v_q ? 'q', '문제 문장은 들어 있다';
    assert not (v_q ? 'answer'), '마감 전에는 정답이 나가면 안 된다';
    assert not (v_q ? 'explain'), '마감 전에는 해설이 나가면 안 된다';
    assert not (v_q ? 'hint'), '힌트는 문제에 담기지 않는다';

    -- 가: 늘 정답 + 결정 / 나: 늘 오답 / 다: 앞 5문제만 정답
    c := t_center(v_type, v_right);  perform t_walk(ta, c[1], c[2]);
    assert (t_lock(ta, 2) ->> 'ok')::boolean, '정답 자리에서는 결정할 수 있다';
    c := t_center(v_type, v_wrong);  perform t_walk(tb, c[1], c[2]);
    c := t_center(v_type, case when i < 5 then v_right else v_wrong end);
    perform t_walk(tc, c[1], c[2]);

    -- 마감 전에는 채점할 수 없다
    begin
      perform grade_question(v_code);
      raise exception '마감 전에 채점이 되면 안 된다';
    exception when sqlstate 'P0001' then null;
    end;

    perform t_expire(v_code);
    perform grade_question(v_code);
    assert (get_snapshot(v_code, null) ->> 'phase') = 'reveal', '채점 뒤에는 정답 공개';

    -- 두 번 불러도 점수가 더 오르지 않는다
    perform grade_question(v_code);
    assert (select score from players where id = ia) = (i + 1) * 10, '가는 ' || ((i+1) * 10) || '점이어야 한다';

    -- 이제는 정답과 해설이 나간다
    v_q := get_snapshot(v_code, null) -> 'question';
    assert v_q ? 'answer' and v_q ? 'explain', '정답 공개 뒤에는 정답과 해설이 나간다';

    perform host_next(v_code, v_host);
  end loop;

  /* ---------- 최종 ---------- */
  v_snap := get_snapshot(v_code, null);
  assert v_snap ->> 'phase' = 'final', '10문제를 다 풀면 최종 결과';
  assert (v_snap ->> 'questions')::int = 10, '10문제를 풀었다';

  v_rank := v_snap -> 'ranking';
  assert jsonb_array_length(v_rank) = 3, '3명의 순위가 나온다';
  assert v_rank -> 0 ->> 'name' = '가'   and (v_rank -> 0 ->> 'score')::int = 100 and v_rank -> 0 ->> 'title' = '왕',  '1등 가 100점 왕';
  assert v_rank -> 1 ->> 'name' = '다'   and (v_rank -> 1 ->> 'score')::int = 50  and v_rank -> 1 ->> 'title' = '평민', '2등 다 50점 평민';
  assert v_rank -> 2 ->> 'name' = '나'   and (v_rank -> 2 ->> 'score')::int = 0  and v_rank -> 2 ->> 'title' = '천민', '3등 나 0점 천민';
  -- 22초 중 2초에 결정했으므로 한 문제당 약 0.91, 10문제면 9점대
  assert (v_rank -> 0 ->> 'bonus')::numeric between 9 and 9.2,
         '결정을 누른 가의 빠르기 보너스: ' || (v_rank -> 0 ->> 'bonus');
  assert (v_rank -> 1 ->> 'bonus')::numeric = 0, '결정을 안 누르면 보너스가 없다';

  -- 참여 기록이 한 줄 남았다(이름 없이)
  assert (select count(*) from participation) = v_part_before + 1, '참여 기록이 한 줄 늘어난다';
  assert (select count(*) from participation
           where level = 'elem' and players = 3 and questions = 10
             and id = (select max(id) from participation)) = 1, '방금 판의 내용이 맞다';
  assert (select to_jsonb(p) from participation p order by id desc limit 1) ?& array['level','players','avg_score']
         and not ((select to_jsonb(p) from participation p order by id desc limit 1) ?| array['name','names','player_name']),
         '참여 기록에 이름이 들어가지 않는다';
  assert get_today_total() = v_today_before + 3, '오늘 참여 인원 합계에 3명이 더해진다';

  raise notice '한 판 진행 테스트 통과 (방 %)', v_code;

  /* ---------- 진행자 화면: 문제별 학생 답 ---------- */
  v := host_review(v_code, v_host);
  assert jsonb_array_length(v) = 10, '채점한 10문제가 모두 나온다';
  assert (v -> 0 ->> 'n')::int = 1 and v -> 0 ? 'q' and v -> 0 ? 'answerLabel', '번호·문제·정답이 있다';
  assert jsonb_array_length(v -> 0 -> 'answers') = 3, '세 학생의 답이 있다';
  assert v -> 0 -> 'answers' -> 0 ->> 'name' = '가' and v -> 0 -> 'answers' -> 2 ->> 'name' = '나', '순위 순서로 나온다';
  assert (v -> 0 -> 'answers' -> 0 ->> 'correct')::boolean
     and v -> 0 -> 'answers' -> 0 ->> 'mine' = v -> 0 ->> 'answerLabel', '가는 정답을 냈고 그 글자가 정답과 같다';
  assert not (v -> 0 -> 'answers' -> 2 ->> 'correct')::boolean
     and v -> 0 -> 'answers' -> 2 ->> 'mine' <> v -> 0 ->> 'answerLabel', '나는 다른 답을 냈다';
  assert (v -> 9 -> 'answers' -> 1 ->> 'name') = '다' and not (v -> 9 -> 'answers' -> 1 ->> 'correct')::boolean, '다는 10번을 틀렸다';
  begin
    perform host_review(v_code, gen_random_uuid());
    raise exception '진행자 열쇠 없이 학생 답을 보면 안 된다';
  exception when sqlstate 'P0001' then
    if sqlerrm like '진행자 열쇠 없이%' then raise; end if;
  end;
  raise notice '문제별 학생 답 테스트 통과';
  delete from rooms where code = v_code;
end $$;

/* ---------- 문제별 학생 답: 객관식·주관식, 아무것도 안 낸 학생, 채점 전 문제 ---------- */
do $$
declare v jsonb; v_code text; v_host uuid; ta uuid; tb uuid; v_q jsonb; c double precision[]; lv text;
begin
  foreach lv in array array['mid', 'high'] loop
    v := host_create_room(); v_code := v ->> 'code'; v_host := (v ->> 'hostToken')::uuid;
    v := play_join(v_code, '하나', 'red');  ta := (v ->> 'playerToken')::uuid;
    v := play_join(v_code, '두리', 'red');  tb := (v ->> 'playerToken')::uuid;
    perform host_set_level(v_code, v_host, lv);
    perform host_start(v_code, v_host);
    assert jsonb_array_length(host_review(v_code, v_host)) = 0, '채점 전 문제는 나오지 않는다(정답이 새지 않게)';

    select rs.round -> 0 into v_q from room_secrets rs where rs.code = v_code;
    if v_q ->> 'type' = 'sa' then
      perform play_answer(ta, v_q ->> 'answer', true);           -- 하나: 정답을 씀, 두리: 아무것도 안 씀
    else
      c := t_center(v_q ->> 'type', v_q ->> 'answer');            -- 하나: 정답 자리, 두리: 시작 자리(아무 구역도 아님)
      perform t_walk(ta, c[1], c[2]);
    end if;
    perform t_expire(v_code);
    perform grade_question(v_code);
    perform host_end(v_code, v_host);

    v := host_review(v_code, v_host);
    assert jsonb_array_length(v) = 1, lv || ': 채점한 1문제만 나온다';
    assert v -> 0 -> 'answers' -> 0 ->> 'name' = '하나'
       and v -> 0 -> 'answers' -> 0 ->> 'mine' = v -> 0 ->> 'answerLabel', lv || ': 정답 글자가 그대로 나온다';
    assert v -> 0 -> 'answers' -> 1 ->> 'name' = '두리'
       and v -> 0 -> 'answers' -> 1 ->> 'mine' is null
       and not (v -> 0 -> 'answers' -> 1 ->> 'correct')::boolean,
       lv || ': 아무것도 안 낸 학생은 답이 비어 있고 틀린 것으로 나온다';
    delete from rooms where code = v_code;
  end loop;
  raise notice '문제별 학생 답(객관식·주관식) 테스트 통과';
end $$;
