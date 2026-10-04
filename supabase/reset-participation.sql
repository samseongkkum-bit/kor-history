-- 참여 기록을 모두 지웁니다.
-- 부스를 시작하기 전에 시험 삼아 돌려 본 기록을 없앨 때 쓰세요.
-- Supabase 대시보드 → SQL Editor 에 붙여넣고 Run 하면 됩니다.
delete from participation;

-- 특정 날짜만 지우려면 위 줄 대신 아래를 쓰세요.
-- delete from participation where day = '2026-10-05';
