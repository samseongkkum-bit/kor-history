#!/usr/bin/env bash
# Supabase 함수 테스트를 돌린다.
#   · 기본: 로컬 Postgres 에 hq_test 데이터베이스를 새로 만들어서 돌린다.
#   · SUPABASE_DB_URL 이 있으면 그 데이터베이스에 대고 돌린다(실제 프로젝트 확인용).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env.local ] && set -a && . ./.env.local && set +a || true

# 예시 그대로이거나 연결되지 않는 값은 없는 것으로 치고 로컬로 돌린다
case "${SUPABASE_DB_URL:-}" in *xxxxx*|*"...."*|*"비밀번호"*) SUPABASE_DB_URL="" ;; esac
if [ -n "${SUPABASE_DB_URL:-}" ] && ! PGCONNECT_TIMEOUT=8 psql -d "$SUPABASE_DB_URL" -At -c "select 1" >/dev/null 2>&1; then
  echo "SUPABASE_DB_URL 로 연결되지 않아 로컬 Postgres 로 돌립니다."
  echo "  (Supabase 대시보드 → Connect → Session pooler 의 URI 를 넣어 주세요. 직접 연결 주소는 IPv6 전용입니다.)"
  SUPABASE_DB_URL=""
fi

if [ -n "${SUPABASE_DB_URL:-}" ]; then
  DB="$SUPABASE_DB_URL"
  echo "== Supabase 프로젝트에 대고 테스트합니다"
else
  DB="hq_test"
  echo "== 로컬 Postgres(hq_test)로 테스트합니다"
  dropdb --if-exists hq_test
  createdb hq_test
  psql -q -d "$DB" -v ON_ERROR_STOP=1 -c "do \$\$ begin
      if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
      if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
    end \$\$;"
fi

for f in supabase/migrations/*.sql; do
  echo "-- 적용: $(basename "$f")"
  psql -q -d "$DB" -v ON_ERROR_STOP=1 -f "$f" 2>&1 | grep -v "^NOTICE" || true
done

[ -z "${SUPABASE_DB_URL:-}" ] && psql -q -d "$DB" -v ON_ERROR_STOP=1 -f tests/sql/_local_roles.sql

fail=0
for f in tests/sql/*.test.sql; do
  echo "-- 테스트: $(basename "$f")"
  if ! psql -d "$DB" -v ON_ERROR_STOP=1 -f "$f" 2>&1 | grep -v -E "^(Pager|SET|DO|RESET|DELETE|UPDATE|INSERT)" | sed 's/^/   /'; then
    fail=1
  fi
done

if [ "$fail" = "0" ]; then echo "모든 SQL 테스트 통과"; else echo "SQL 테스트 실패"; exit 1; fi
