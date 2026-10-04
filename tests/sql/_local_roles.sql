-- 로컬 Postgres 에서 테스트할 때만 쓴다. Supabase 에는 이 역할들이 이미 있고,
-- 아래와 같은 기본 권한이 걸려 있다(표 접근은 RLS 가 막는다).
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to anon, authenticated;
grant usage, select on all sequences in schema public to anon, authenticated;
