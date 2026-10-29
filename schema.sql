-- ============================================================
-- 팀 출퇴근 기록 - Supabase 설정
-- Supabase 대시보드 > SQL Editor 에서 이 파일 전체를 붙여 넣고 Run 을 한 번 누르세요.
-- 다시 실행해도 기존 기록은 지워지지 않습니다.
-- 모든 출근·퇴근 시각은 데이터베이스(서버)의 시계(now())로 기록합니다.
-- ============================================================

-- 1) 표(테이블) -------------------------------------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  email       text not null,
  name        text not null check (char_length(name) between 1 and 20),
  role        text not null default 'member' check (role in ('admin', 'member')),
  work_start  text check (work_start ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  work_end    text check (work_end   ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists public.attendance (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles (id),
  work_date  date not null,
  check_in   timestamptz not null,
  check_out  timestamptz,
  unique (user_id, work_date)
);
create index if not exists attendance_work_date_idx on public.attendance (work_date);

create table if not exists public.adjustments (
  id             bigint generated always as identity primary key,
  attendance_id  bigint not null references public.attendance (id),
  by_user        uuid not null references public.profiles (id),
  reason         text not null,
  old_in         timestamptz,
  old_out        timestamptz,
  new_in         timestamptz,
  new_out        timestamptz,
  at             timestamptz not null default now()
);

create table if not exists public.requests (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles (id),
  work_date   date not null,
  req_in      text check (req_in  ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  req_out     text check (req_out ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  reason      text not null,
  status      text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at  timestamptz not null default now(),
  decided_by  uuid references public.profiles (id),
  decided_at  timestamptz
);

create table if not exists public.settings (
  key    text primary key,
  value  text not null
);

insert into public.settings (key, value) values
  ('work_start', '09:00'),
  ('work_end',   '18:00'),
  ('signup_code', substr(md5(random()::text || clock_timestamp()::text), 1, 10))
on conflict (key) do nothing;

-- 2) 표는 브라우저에서 직접 읽거나 쓰지 못하게 잠급니다 ------------------
--    (화면은 아래 4)의 api_* 함수만 호출합니다)
alter table public.profiles    enable row level security;
alter table public.attendance  enable row level security;
alter table public.adjustments enable row level security;
alter table public.requests    enable row level security;
alter table public.settings    enable row level security;

revoke all on public.profiles, public.attendance, public.adjustments, public.requests, public.settings from anon, authenticated;

-- 3) 도우미 함수 --------------------------------------------------
create or replace function public.to_ms(t timestamptz) returns bigint
language sql immutable as $$ select (extract(epoch from t) * 1000)::bigint $$;

create or replace function public.is_hm(s text) returns boolean
language sql immutable as $$ select s ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' $$;

-- 로그인한 활성 팀원을 돌려줍니다. 아니면 오류.
create or replace function public.current_member() returns public.profiles
language plpgsql stable security definer set search_path = public as $$
declare p public.profiles;
begin
  select * into p from public.profiles where id = auth.uid() and active;
  if p.id is null then
    raise exception '로그인이 필요합니다.' using errcode = '28000';
  end if;
  return p;
end $$;

create or replace function public.current_admin() returns public.profiles
language plpgsql stable security definer set search_path = public as $$
declare p public.profiles;
begin
  p := public.current_member();
  if p.role <> 'admin' then
    raise exception '관리자만 할 수 있습니다.' using errcode = '42501';
  end if;
  return p;
end $$;

-- 기록 추가·보정 (이전 값과 사유를 adjustments 에 남깁니다). 화면에서 직접 호출하지 않습니다.
create or replace function public.apply_adjustment(
  p_user uuid, p_date date, p_in text, p_out text, p_reason text, p_by uuid
) returns void
language plpgsql security definer set search_path = public as $$
declare
  cur    public.attendance;
  nin    timestamptz;
  nout   timestamptz;
  att_id bigint;
  v_now  timestamptz := now();
begin
  p_in := nullif(btrim(coalesce(p_in, '')), '');
  p_out := nullif(btrim(coalesce(p_out, '')), '');
  p_reason := btrim(coalesce(p_reason, ''));
  if p_date is null then raise exception '날짜를 입력하세요.'; end if;
  if p_in is null and p_out is null then raise exception '출근 또는 퇴근 시각을 입력하세요.'; end if;
  if p_in is not null and not public.is_hm(p_in) then raise exception '출근 시각 형식이 올바르지 않습니다.'; end if;
  if p_out is not null and not public.is_hm(p_out) then raise exception '퇴근 시각 형식이 올바르지 않습니다.'; end if;
  if p_reason = '' then raise exception '사유를 입력하세요.'; end if;
  if not exists (select 1 from public.profiles where id = p_user) then raise exception '팀원을 찾을 수 없습니다.'; end if;

  select * into cur from public.attendance where user_id = p_user and work_date = p_date for update;

  nin  := case when p_in  is not null then ((p_date::text || ' ' || p_in )::timestamp at time zone 'Asia/Seoul') else cur.check_in  end;
  nout := case when p_out is not null then ((p_date::text || ' ' || p_out)::timestamp at time zone 'Asia/Seoul') else cur.check_out end;

  if nin is null then raise exception '새 기록에는 출근 시각이 필요합니다.'; end if;
  if nout is not null and nout < nin then raise exception '퇴근 시각이 출근 시각보다 빠릅니다.'; end if;
  if nin > v_now or (nout is not null and nout > v_now) then raise exception '미래 시각은 입력할 수 없습니다.'; end if;

  if cur.id is not null then
    update public.attendance set check_in = nin, check_out = nout where id = cur.id;
    att_id := cur.id;
  else
    insert into public.attendance (user_id, work_date, check_in, check_out)
    values (p_user, p_date, nin, nout) returning id into att_id;
  end if;

  insert into public.adjustments (attendance_id, by_user, reason, old_in, old_out, new_in, new_out)
  values (att_id, p_by, left(p_reason, 200), cur.check_in, cur.check_out, nin, nout);
end $$;

-- 4) 화면이 호출하는 함수 ---------------------------------------------
create or replace function public.api_me() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  p public.profiles;
  v_now timestamptz := now();
  v_open_date date;
  v_open_in timestamptz;
begin
  p := public.current_member();
  select a.work_date, a.check_in into v_open_date, v_open_in
    from public.attendance a
   where a.user_id = p.id and a.check_out is null
     and a.check_in <= v_now and a.check_in > v_now - interval '20 hours'
   order by a.check_in desc limit 1;
  return jsonb_build_object(
    'user', jsonb_build_object('id', p.id, 'email', p.email, 'name', p.name, 'role', p.role,
                               'workStart', p.work_start, 'workEnd', p.work_end),
    'serverNow', public.to_ms(v_now),
    'today', to_char(v_now at time zone 'Asia/Seoul', 'YYYY-MM-DD'),
    'open', case when v_open_in is null then null
                 else jsonb_build_object('date', to_char(v_open_date, 'YYYY-MM-DD'), 'in', public.to_ms(v_open_in)) end,
    'defaults', jsonb_build_object(
        'start', (select value from public.settings where key = 'work_start'),
        'end',   (select value from public.settings where key = 'work_end')),
    'teamSize', 9,
    'ipAllowed', true
  );
end $$;

create or replace function public.api_records(p_month text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  p public.profiles;
  v_now timestamptz := now();
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_from date;
  v_to date;
begin
  p := public.current_member();
  if p_month is null or p_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
    raise exception '월 형식이 올바르지 않습니다.';
  end if;
  v_from := (p_month || '-01')::date;
  v_to := (v_from + interval '1 month')::date;
  return jsonb_build_object(
    'month', p_month,
    'serverNow', public.to_ms(v_now),
    'users', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.name, 'role', u.role,
                 'workStart', u.work_start, 'workEnd', u.work_end, 'active', u.active) order by u.name)
               from public.profiles u), '[]'::jsonb),
    'days', coalesce((select jsonb_agg(jsonb_build_object('uid', a.user_id, 'date', to_char(a.work_date, 'YYYY-MM-DD'),
                 'in', public.to_ms(a.check_in), 'out', public.to_ms(a.check_out)) order by a.work_date)
               from public.attendance a where a.work_date >= v_from and a.work_date < v_to), '[]'::jsonb),
    'adj', coalesce((select jsonb_agg(jsonb_build_object('uid', a.user_id, 'date', to_char(a.work_date, 'YYYY-MM-DD'),
                 'reason', j.reason, 'at', public.to_ms(j.at)) order by j.id)
               from public.adjustments j join public.attendance a on a.id = j.attendance_id
              where a.work_date >= v_from and a.work_date < v_to), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('uid', a.user_id, 'date', to_char(a.work_date, 'YYYY-MM-DD'),
                 'in', public.to_ms(a.check_in), 'out', public.to_ms(a.check_out)))
               from public.attendance a where a.work_date in (v_today, v_today - 1)), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'uid', r.user_id, 'date', to_char(r.work_date, 'YYYY-MM-DD'),
                 'in', r.req_in, 'out', r.req_out, 'reason', r.reason, 'status', r.status, 'at', public.to_ms(r.created_at)) order by r.id desc)
               from public.requests r
              where r.user_id = p.id or (p.role = 'admin' and r.status = 'pending')), '[]'::jsonb)
  );
end $$;

create or replace function public.api_punch(p_kind text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  p public.profiles;
  v_now timestamptz := now();
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_open public.attendance;
begin
  p := public.current_member();
  if p_kind is null or p_kind not in ('in', 'out') then raise exception '요청 형식이 올바르지 않습니다.'; end if;

  select * into v_open from public.attendance
   where user_id = p.id and check_out is null
     and check_in <= v_now and check_in > v_now - interval '20 hours'
   order by check_in desc limit 1 for update;

  if p_kind = 'in' then
    if v_open.id is not null then raise exception '아직 퇴근하지 않은 기록이 있습니다.'; end if;
    if exists (select 1 from public.attendance where user_id = p.id and work_date = v_today) then
      raise exception '오늘은 이미 출근을 기록했습니다.';
    end if;
    begin
      insert into public.attendance (user_id, work_date, check_in) values (p.id, v_today, v_now);
    exception when unique_violation then
      raise exception '오늘은 이미 출근을 기록했습니다.';
    end;
    return jsonb_build_object('ok', true, 'kind', 'in', 'at', public.to_ms(v_now), 'date', to_char(v_today, 'YYYY-MM-DD'));
  end if;

  if v_open.id is null then raise exception '퇴근 처리할 출근 기록이 없습니다.'; end if;
  update public.attendance set check_out = v_now where id = v_open.id;
  return jsonb_build_object('ok', true, 'kind', 'out', 'at', public.to_ms(v_now), 'date', to_char(v_open.work_date, 'YYYY-MM-DD'));
end $$;

create or replace function public.api_update_me(p_name text, p_start text, p_end text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p public.profiles; v_name text := left(btrim(coalesce(p_name, '')), 20);
begin
  p := public.current_member();
  if v_name = '' then raise exception '이름을 입력하세요.'; end if;
  if not public.is_hm(p_start) or not public.is_hm(p_end) then raise exception '기준 출근·퇴근 시각 형식이 올바르지 않습니다.'; end if;
  update public.profiles set name = v_name, work_start = p_start, work_end = p_end where id = p.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_submit_request(p_date date, p_in text, p_out text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  p public.profiles;
  v_in text := nullif(btrim(coalesce(p_in, '')), '');
  v_out text := nullif(btrim(coalesce(p_out, '')), '');
  v_reason text := left(btrim(coalesce(p_reason, '')), 200);
begin
  p := public.current_member();
  if p_date is null then raise exception '날짜 형식이 올바르지 않습니다.'; end if;
  if p_date > (now() at time zone 'Asia/Seoul')::date then raise exception '미래 날짜는 요청할 수 없습니다.'; end if;
  if (v_in is not null and not public.is_hm(v_in)) or (v_out is not null and not public.is_hm(v_out)) then
    raise exception '시각 형식이 올바르지 않습니다.';
  end if;
  if v_in is null and v_out is null then raise exception '출근 또는 퇴근 시각을 입력하세요.'; end if;
  if v_reason = '' then raise exception '사유를 입력하세요.'; end if;
  if (select count(*) from public.requests where user_id = p.id and status = 'pending') >= 10 then
    raise exception '대기 중인 요청이 너무 많습니다. 처리된 뒤에 다시 요청하세요.';
  end if;
  insert into public.requests (user_id, work_date, req_in, req_out, reason) values (p.id, p_date, v_in, v_out, v_reason);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_decide_request(p_id bigint, p_approve boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p public.profiles; r public.requests;
begin
  p := public.current_admin();
  select * into r from public.requests where id = p_id for update;
  if r.id is null then raise exception '요청을 찾을 수 없습니다.'; end if;
  if r.status <> 'pending' then raise exception '이미 처리된 요청입니다.'; end if;
  if coalesce(p_approve, false) then
    perform public.apply_adjustment(r.user_id, r.work_date, r.req_in, r.req_out, '요청 승인: ' || r.reason, p.id);
  end if;
  update public.requests
     set status = case when coalesce(p_approve, false) then 'approved' else 'rejected' end,
         decided_by = p.id, decided_at = now()
   where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_admin_record(p_user uuid, p_date date, p_in text, p_out text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p public.profiles;
begin
  p := public.current_admin();
  perform public.apply_adjustment(p_user, p_date, p_in, p_out, p_reason, p.id);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_admin_info() returns jsonb
language plpgsql security definer set search_path = public as $$
declare p public.profiles;
begin
  p := public.current_admin();
  return jsonb_build_object(
    'signupCode', (select value from public.settings where key = 'signup_code'),
    'defaults', jsonb_build_object('start', (select value from public.settings where key = 'work_start'),
                                   'end',   (select value from public.settings where key = 'work_end')),
    'users', (select count(*) from public.profiles where active));
end $$;

create or replace function public.api_set_defaults(p_start text, p_end text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p public.profiles;
begin
  p := public.current_admin();
  if not public.is_hm(p_start) or not public.is_hm(p_end) then raise exception '시각 형식이 올바르지 않습니다.'; end if;
  update public.settings set value = p_start where key = 'work_start';
  update public.settings set value = p_end   where key = 'work_end';
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_set_active(p_user uuid, p_active boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p public.profiles;
begin
  p := public.current_admin();
  if p_user = p.id then raise exception '자기 자신은 비활성화할 수 없습니다.'; end if;
  update public.profiles set active = coalesce(p_active, false) where id = p_user;
  if not found then raise exception '팀원을 찾을 수 없습니다.'; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.api_set_signup_code(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p public.profiles; v_code text := btrim(coalesce(p_code, ''));
begin
  p := public.current_admin();
  if char_length(v_code) < 6 or char_length(v_code) > 40 then raise exception '가입 코드는 6자 이상 40자 이하로 정하세요.'; end if;
  update public.settings set value = v_code where key = 'signup_code';
  return jsonb_build_object('ok', true);
end $$;

-- 5) 가입 처리: 가입 코드 확인 + 팀원 정보 생성 (가장 먼저 가입한 사람이 관리자) --------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_code text;
  v_name text;
begin
  select value into v_code from public.settings where key = 'signup_code';
  if coalesce(new.raw_user_meta_data ->> 'signup_code', '') is distinct from v_code then
    raise exception '가입 코드가 올바르지 않습니다.';
  end if;
  v_name := left(btrim(coalesce(new.raw_user_meta_data ->> 'name', '')), 20);
  if v_name = '' then raise exception '이름을 입력하세요.'; end if;
  if (select count(*) from public.profiles) >= 30 then raise exception '가입 가능한 인원을 초과했습니다.'; end if;
  insert into public.profiles (id, email, name, role)
  values (new.id, lower(new.email), v_name,
          case when exists (select 1 from public.profiles) then 'member' else 'admin' end);
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 6) 함수 실행 권한: 로그인한 사용자는 api_* 함수만 호출할 수 있습니다 -----------------
revoke all on all functions in schema public from public, anon, authenticated;

grant execute on function
  public.api_me(), public.api_records(text), public.api_punch(text),
  public.api_update_me(text, text, text), public.api_submit_request(date, text, text, text),
  public.api_decide_request(bigint, boolean), public.api_admin_record(uuid, date, text, text, text),
  public.api_admin_info(), public.api_set_defaults(text, text), public.api_set_active(uuid, boolean),
  public.api_set_signup_code(text)
to authenticated;

grant execute on function public.handle_new_user() to supabase_auth_admin;
