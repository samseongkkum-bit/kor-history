-- 진행자 화면 최종 결과에서 "문제별로 학생들이 낸 답"을 보여 주려고 쓴다.
-- 채점이 끝난 문제만 돌려준다(아직 안 끝난 문제의 정답이 새지 않게). 진행자 열쇠가 있어야 부를 수 있다.
--
-- 돌려주는 모양:
--   [{ "n": 1, "q": "문제", "type": "ox|mc|sa", "answerLabel": "정답 글자",
--      "answers": [{ "name": "민수", "mine": "내가 낸 답 글자" | null, "correct": true }, ...] }, ...]
--   answers 는 최종 순위 순서. 그 문제를 풀 때 방에 없던 학생(중간에 들어온 학생)은 빠진다.
create or replace function host_review(p_code text, p_token uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_round jsonb; v_graded int;
begin
  perform hq_check_host(p_code, p_token);
  select rs.round, r.graded_index into v_round, v_graded
    from rooms r join room_secrets rs on rs.code = r.code where r.code = p_code;
  if v_round is null then return '[]'::jsonb; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'n', i + 1,
             'q', x ->> 'q',
             'type', x ->> 'type',
             'answerLabel', hq_answer_label(x ->> 'type', x ->> 'answer', x -> 'choices'),
             'answers', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'name', p.name,
                        'mine', case when a.picked is null then null
                                     else hq_answer_label(x ->> 'type', a.picked, x -> 'choices') end,
                        'correct', a.correct
                      ) order by p.score desc, p.bonus desc, p.name)
                 from answers a join players p on p.id = a.player_id
                where a.room_code = p_code and a.q_index = i
             ), '[]'::jsonb)
           ) order by i)
      from jsonb_array_elements(v_round) with ordinality as e(x, k), lateral (select (k - 1)::int as i) ii
     where i <= v_graded
  ), '[]'::jsonb);
end $$;

revoke execute on function host_review(text, uuid) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function host_review(text, uuid) to anon, authenticated;
  end if;
end $$;
