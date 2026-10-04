-- 마당 좌표와 출제 로직. public/shared/map.js · consts.js 와 같은 값을 쓴다.
-- 채점이 화면과 어긋나지 않도록 구역 판정은 여기(서버)에서만 한다.

-- 마당: x 40~920, y 96~576 / 캐릭터가 설 수 있는 범위는 안쪽으로 조금 좁다
create or replace function hq_clamp_x(x double precision) returns double precision
language sql immutable as $$ select greatest(60::double precision, least(900::double precision, coalesce(x, 480))) $$;

create or replace function hq_clamp_y(y double precision) returns double precision
language sql immutable as $$ select greatest(136::double precision, least(546::double precision, coalesce(y, 540))) $$;

-- 서 있는 돗자리. 없으면 null.
-- O/X : O(90,170,340,300)  X(530,170,340,300)
-- 객관식: (90,150) (530,150) (90,320) (530,320) 각 340x140
create or replace function hq_zone_at(p_type text, x double precision, y double precision)
returns text language sql immutable as $$
  select case
    when x is null or y is null then null
    when p_type = 'ox' then
      case
        when x between 90  and 430 and y between 170 and 470 then 'O'
        when x between 530 and 870 and y between 170 and 470 then 'X'
      end
    else
      case
        when x between 90  and 430 and y between 150 and 290 then '0'
        when x between 530 and 870 and y between 150 and 290 then '1'
        when x between 90  and 430 and y between 320 and 460 then '2'
        when x between 530 and 870 and y between 320 and 460 then '3'
      end
  end
$$;

-- 문제당 제한 시간: O/X 12초, 객관식 20초
create or replace function hq_seconds(p_type text) returns int
language sql immutable as $$ select case when p_type = 'mc' then 20 else 12 end $$;

-- 칭호(10점 만점)
create or replace function hq_title(p_score int) returns text
language sql immutable as $$
  select case
    when p_score >= 10 then '왕'
    when p_score >= 9  then '조선의 학자'
    when p_score >= 7  then '귀족'
    when p_score >= 5  then '평민'
    when p_score >= 3  then '양민'
    else '천민'
  end
$$;

create or replace function hq_title_say(p_score int) returns text
language sql immutable as $$
  select case
    when p_score >= 10 then '모두 맞혔어요! 오늘 부스의 임금님이에요.'
    when p_score >= 9  then '거의 다 맞혔어요! 집현전 학자도 놀랄 실력이에요.'
    when p_score >= 7  then '대단해요! 역사 이야기를 많이 알고 있네요.'
    when p_score >= 5  then '절반 넘게 맞혔어요! 우리 역사와 꽤 친해졌어요.'
    when p_score >= 3  then '조금씩 알아가고 있어요. 해설을 다시 읽어 보면 더 잘할 수 있어요.'
    else '이제 막 역사 여행을 시작했어요. 다시 풀면 금방 올라갈 수 있어요!'
  end
$$;

-- 정답을 사람이 읽는 말로
create or replace function hq_answer_label(p_type text, p_answer text, p_choices jsonb)
returns text language sql immutable as $$
  select case
    when p_type = 'ox' then case when p_answer = 'O' then '○ (맞아요)' else '× (아니에요)' end
    else (array['①','②','③','④'])[p_answer::int + 1] || ' ' || (p_choices ->> p_answer::int)
  end
$$;

-- 한 판에 쓸 10문제를 뽑는다.
-- 30문제를 한 바퀴 다 돌 때까지 같은 문제가 다시 나오지 않고, 객관식은 보기 순서도 섞는다.
-- (단일 파일 버전의 buildRound 와 같은 규칙)
create or replace function hq_build_round(p_level text, p_used jsonb)
returns jsonb language plpgsql as $$
declare
  v_used  int[];
  v_fresh int[];
  v_fill  int[];
  v_ids   int[];
  v_need  int;
  v_new_used int[];
  v_round jsonb := '[]'::jsonb;
  v_order int[];
  v_choices jsonb;
  v_answer text;
  r questions%rowtype;
  i int;
begin
  select coalesce(array_agg(value::int), '{}'::int[]) into v_used
    from jsonb_array_elements_text(coalesce(p_used -> p_level, '[]'::jsonb));

  select coalesce(array_agg(idx order by random()), '{}'::int[]) into v_fresh
    from questions where level = p_level and not (idx = any(v_used));

  if coalesce(array_length(v_fresh, 1), 0) >= 10 then
    v_ids := v_fresh[1:10];
    v_new_used := v_used || v_ids;
  else
    v_need := 10 - coalesce(array_length(v_fresh, 1), 0);
    select coalesce(array_agg(idx order by random()), '{}'::int[]) into v_fill
      from questions where level = p_level and not (idx = any(v_fresh));
    v_fill := v_fill[1:v_need];
    select coalesce(array_agg(x order by random()), '{}'::int[]) into v_ids
      from unnest(v_fresh || v_fill) x;
    v_new_used := v_fill;
  end if;

  foreach i in array v_ids loop
    select * into r from questions where level = p_level and idx = i;
    if r.type = 'mc' then
      select array_agg(k order by random()) into v_order from generate_series(0, 3) k;
      select jsonb_agg(r.choices -> v_order[n] order by n) into v_choices from generate_series(1, 4) n;
      select (n - 1)::text into v_answer from generate_series(1, 4) n where v_order[n] = r.answer::int;
    else
      v_choices := null;
      v_answer  := r.answer;
    end if;
    v_round := v_round || jsonb_build_object(
      'src', i, 'type', r.type, 'q', r.q, 'choices', v_choices,
      'answer', v_answer, 'hint', r.hint, 'explain', r.explain);
  end loop;

  return jsonb_build_object(
    'round', v_round,
    'used',  jsonb_set(coalesce(p_used, '{}'::jsonb), array[p_level], to_jsonb(v_new_used))
  );
end $$;
