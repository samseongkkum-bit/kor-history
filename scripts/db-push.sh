#!/usr/bin/env bash
# Supabase 프로젝트에 표와 함수를 올린다.
#   .env.local 의 SUPABASE_DB_URL 이 있으면 psql 로 바로 올리고,
#   없으면 supabase/all.sql 을 만들어 두고 붙여넣는 방법을 알려 준다.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env.local ] && set -a && . ./.env.local && set +a || true
case "${SUPABASE_DB_URL:-}" in *xxxxx*|*"...."*|*"비밀번호"*) SUPABASE_DB_URL="" ;; esac
if [ -n "${SUPABASE_DB_URL:-}" ] && ! PGCONNECT_TIMEOUT=8 psql -d "$SUPABASE_DB_URL" -At -c "select 1" >/dev/null 2>&1; then
  echo "SUPABASE_DB_URL 로 연결되지 않았어요(직접 연결 주소는 IPv6 전용입니다)."
  SUPABASE_DB_URL=""
fi

node scripts/make-seed.mjs
node scripts/build-sql.mjs

if [ -z "${SUPABASE_DB_URL:-}" ]; then
  cat <<'MSG'

SUPABASE_DB_URL 이 없어서 직접 올리지 못했어요. 둘 중 하나로 하시면 됩니다.

  [방법 1] 붙여넣기 (비밀번호 필요 없음)
    1. Supabase 대시보드 → 왼쪽 메뉴 SQL Editor → New query
    2. 이 폴더의 supabase/all.sql 을 열어 전체 복사 → 붙여넣기 → Run
    3. "Success" 가 나오면 끝입니다.

  [방법 2] 연결 문자열 넣기
    Supabase 대시보드 → Project Settings → Database → Connection string → URI 를 복사해
    .env.local 의 SUPABASE_DB_URL 에 넣고 다시 `npm run db:push` 하세요.

MSG
  exit 0
fi

echo "== Supabase 프로젝트에 올립니다"
for f in supabase/migrations/*.sql; do
  echo "-- $(basename "$f")"
  psql -q -d "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f "$f" 2>&1 | grep -v "^NOTICE" || true
done
echo "완료"
