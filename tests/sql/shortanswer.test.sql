-- 고등부(주관식) 테스트: 써 낸 답으로 채점하고, 띄어쓰기·다른 이름도 맞다고 쳐 준다.
\set ON_ERROR_STOP on
\pset pager off
\set QUIET on
set client_min_messages = notice;

-- 마감 시각을 앞당겨 제한 시간이 막 지난 상태로 만든다(game.test.sql 과 같은 것)
create or replace function t_expire(p_code text) returns void language plpgsql as $$
declare v_delta interval;
begin
  select (r.ends_at - now()) + interval '10 milliseconds' into v_delta from rooms r where r.code = p_code;
  update rooms  set started_at = started_at - v_delta, ends_at = ends_at - v_delta where code = p_code;
  update players set locked_at = locked_at - v_delta where room_code = p_code and locked_at is not null;
end $$;

do $$
begin
  /* ---------- 답 다듬기 ---------- */
  assert hq_norm(' 동학  농민 운동 ') = '동학농민운동', '띄어쓰기는 보지 않는다';
  assert hq_norm('3.1 운동') = hq_norm('3·1 운동'), '가운뎃점과 마침표는 같게 본다';
  assert hq_norm('1592') = hq_norm('1592년'), '연도 뒤의 "년"은 없어도 된다';
  assert hq_norm('『목민심서』') = '목민심서', '책 괄호는 보지 않는다';
  assert hq_norm('우산국(울릉도)') = '우산국울릉도', '괄호는 빼고 안의 글자는 남긴다';
  assert hq_norm('[경국대전]') = '경국대전', '대괄호도 보지 않는다';
  assert hq_sa_correct('광개토왕', '광개토대왕', '["광개토왕"]'), '함께 인정하는 이름도 맞다';
  assert not hq_sa_correct('세종대왕', '광개토대왕', '["광개토왕"]'), '다른 답은 틀리다';
  assert not hq_sa_correct('  ', '광개토대왕', null), '빈 답은 틀리다';
  assert not hq_sa_correct('년', '1592년', null), '"년"만 쓰면 틀리다';
  assert hq_seconds('sa') = 40, '주관식은 40초';
  assert hq_answer_label('sa', '고조선', null) = '고조선', '정답 표시는 낱말 그대로';

  /* ---------- 문제 ---------- */
  assert (select count(*) from questions where level = 'high') >= 100, '고등부 문제가 100개 넘게 있다';
  assert not exists (select 1 from questions where level = 'high' and type <> 'sa'), '고등부는 모두 주관식';
  assert not exists (select 1 from questions where level = 'high' and q like '%아닌 것은%'),
         '보기가 있어야 풀 수 있는 "아닌 것은?" 문제는 뺐다';
  -- 고등부 문제는 모두 중등부 객관식 문제에서 왔고, 정답은 그 문제의 정답 보기와 같다
  assert not exists (
    select 1 from questions h
     where h.level = 'high'
       and not exists (select 1 from questions m
                        where m.level = 'mid' and m.type = 'mc' and m.q = h.q
                          and m.choices ->> m.answer::int = h.answer)
  ), '고등부 문제는 중등부 객관식 문제와 정답이 같다';
end $$;

do $$
declare
  v jsonb; v_code text; v_host uuid;
  ta uuid; tb uuid; tc uuid; td uuid; ia uuid; ib uuid; ic uuid; id_ uuid;
  v_q jsonb; v_ans text; v_alt text; v_snap jsonb; v_round jsonb;
begin
  v := host_create_room();
  v_code := v ->> 'code'; v_host := (v ->> 'hostToken')::uuid;
  v := play_join(v_code, '가', null); ia := (v ->> 'playerId')::uuid; ta := (v ->> 'playerToken')::uuid;
  v := play_join(v_code, '나', null); ib := (v ->> 'playerId')::uuid; tb := (v ->> 'playerToken')::uuid;
  v := play_join(v_code, '다', null); ic := (v ->> 'playerId')::uuid; tc := (v ->> 'playerToken')::uuid;
  v := play_join(v_code, '라', null); id_ := (v ->> 'playerId')::uuid; td := (v ->> 'playerToken')::uuid;

  perform host_set_level(v_code, v_host, 'high');
  v_snap := host_start(v_code, v_host);
  assert v_snap -> 'levelInfo' ->> 'name' = '고등부', '고등부로 시작한다';

  v_q := v_snap -> 'question';
  assert v_q ->> 'type' = 'sa', '주관식 문제가 나온다';
  assert not (v_q ? 'choices'), '주관식에는 보기가 없다';
  assert not (v_q ? 'answer') and not (v_q ? 'accept'), '마감 전에는 정답이 나가면 안 된다';
  assert extract(epoch from ((v_snap ->> 'endsAt')::timestamptz - (v_snap ->> 'startAt')::timestamptz)) = 40,
         '제한 시간 40초';

  select rs.round into v_round from room_secrets rs where rs.code = v_code;
  v_ans := v_round -> 0 ->> 'answer';

  -- 가: 정답을 띄어쓰기 없이 써서 냄 / 나: 오답을 써 두기만 함 / 다: 정답을 써 두기만 함 / 라: 안 씀
  v := play_answer(ta, replace(v_ans, ' ', ''), true);
  assert (v ->> 'ok')::boolean, '답을 낼 수 있다';
  assert not (play_answer(ta, '바꿀래요', false) ->> 'ok')::boolean, '낸 답은 바꿀 수 없다';
  assert (play_answer(tb, '처음 쓴 답', false) ->> 'ok')::boolean, '써 둘 수 있다';
  assert (play_answer(tb, '틀린 답', false) ->> 'ok')::boolean, '써 둔 답은 고칠 수 있다';
  assert (play_answer(tc, '  ' || v_ans || '  ', false) ->> 'ok')::boolean, '써 둘 수 있다';
  assert not (play_answer(td, '   ', true) ->> 'ok')::boolean, '빈 답은 낼 수 없다';
  assert (play_answer(td, repeat('가', 100), false) ->> 'ok')::boolean, '긴 답도 받는다';
  assert char_length((select typed from players where id = id_)) = 30, '답은 30자까지만 남긴다';
  perform play_answer(td, '', false);
  assert (select typed from players where id = id_) is null, '지우면 빈 답';
  assert not (play_lock(ta) ->> 'ok')::boolean, '주관식에는 자리 결정이 없다';

  -- 내 답은 나에게만 보인다
  assert get_snapshot(v_code, tb) -> 'you' ->> 'typed' = '틀린 답', '새로고침해도 써 둔 답이 남는다';
  assert (get_snapshot(v_code, tb) -> 'you' ->> 'locked')::boolean = false, '나는 아직 내지 않았다';
  assert (get_snapshot(v_code, ta) -> 'you' ->> 'locked')::boolean, '가는 냈다';
  assert not (get_snapshot(v_code, null)::text like '%틀린 답%'), '다른 사람 답은 진행자 상황에도 안 나간다';

  -- 마감 전 채점 불가, 마감 뒤 채점
  begin
    perform grade_question(v_code);
    raise exception '마감 전에 채점이 되면 안 된다';
  exception when sqlstate 'P0001' then null;
  end;
  perform t_expire(v_code);
  assert not (play_answer(tc, '늦은 답', false) ->> 'ok')::boolean, '마감 뒤에는 답을 못 고친다';
  perform grade_question(v_code);

  assert (select score from players where id = ia) = 10, '정답을 낸 가는 10점';
  assert (select score from players where id = ib) = 0,  '오답을 써 둔 나는 0점';
  assert (select score from players where id = ic) = 10, '정답을 써 두기만 한 다도 10점';
  assert (select score from players where id = id_) = 0, '안 쓴 라는 0점';
  assert (select bonus from players where id = ia) > (select bonus from players where id = ic),
         '먼저 낸 사람이 빠르기 보너스를 받는다';

  v_snap := get_snapshot(v_code, tb);
  assert v_snap -> 'question' ->> 'answerLabel' = v_ans, '정답 공개: 정답 낱말';
  assert v_snap -> 'you' ->> 'picked' = '틀린 답' and not (v_snap -> 'you' ->> 'correct')::boolean, '나의 답과 결과';
  assert get_snapshot(v_code, td) -> 'you' -> 'picked' is null, '안 쓴 사람은 답이 없다';

  -- 다음 문제로 가면 써 둔 답을 비운다
  perform host_next(v_code, v_host);
  assert not exists (select 1 from players where room_code = v_code and typed is not null), '다음 문제에서는 답을 비운다';

  -- 함께 인정하는 이름으로도 맞는다(고등부 문제 중 다른 이름이 있는 문제를 하나 골라 그 문제로 바꿔 끼운다)
  select jsonb_build_object('src', idx, 'type', type, 'q', q, 'choices', null, 'answer', answer,
                            'accept', accept, 'hint', hint, 'explain', explain), accept ->> 0
    into v_q, v_alt
    from questions where level = 'high' and answer = '광개토대왕';
  update room_secrets set round = jsonb_set(round, '{1}', v_q) where code = v_code;
  assert (play_answer(ta, v_alt, true) ->> 'ok')::boolean, '다른 이름으로 낸다';
  assert (play_answer(tb, '광개토 대 왕', false) ->> 'ok')::boolean, '띄어쓰기를 다르게 써 둔다';
  perform t_expire(v_code);
  perform grade_question(v_code);
  assert (select score from players where id = ia) = 20, '함께 인정하는 이름도 정답 (' || v_alt || ')';
  assert (select score from players where id = ib) = 10, '띄어쓰기가 달라도 정답';

  raise notice '주관식 테스트 통과 (방 %)', v_code;
  delete from rooms where code = v_code;
end $$;
