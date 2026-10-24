-- 진행자가 [정답 확인]을 누르면 남은 시간을 끊고 바로 채점한다.
-- 마감 시각을 지금으로 당긴 뒤 평소의 grade_question 을 부르므로, 채점 규칙은 시간이 다 됐을 때와 똑같다.
create or replace function host_reveal_now(p_code text, p_token uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform hq_check_host(p_code, p_token);
  update rooms set ends_at = now()
   where code = p_code and phase = 'question' and ends_at > now();
  return grade_question(p_code);
end $$;

revoke execute on function host_reveal_now(text, uuid) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function host_reveal_now(text, uuid) to anon, authenticated;
  end if;
end $$;
