-- Solo Todo — 신규 Supabase 셋업 SQL
-- Supabase Dashboard → Database → SQL Editor 에 붙여넣고 실행.
-- 여러 번 실행해도 안전 (idempotent).
--
-- 무료 플랜 1 프로젝트를 다른 앱과 공유할 수 있도록 별도 schema 'solo_todo' 에 격리.
-- ⚠️ 실행 후 Settings → API → Exposed schemas 에 'solo_todo' 를 반드시 추가하십시오.

-- 1) schema
create schema if not exists solo_todo;

-- 2) role 권한 (PostgREST + Realtime 이 쓰는 role 들)
grant usage on schema solo_todo to anon, authenticated, service_role;
alter default privileges in schema solo_todo
  grant all on tables to anon, authenticated, service_role;
alter default privileges in schema solo_todo
  grant all on sequences to anon, authenticated, service_role;

-- 3) todos 테이블
create table if not exists solo_todo.todos (
  id                text primary key,
  user_id           uuid references auth.users(id) on delete cascade not null,
  title             text not null,
  category          text not null,
  due_at            timestamptz,
  done_at           timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  calendar_event_id text,
  -- v1.1 — 트리 / 메모 모델 컬럼
  parent_id         text,                                       -- 부모 todo id, null = root
  type              text not null default 'task',               -- 'task' | 'note'
  sort_order        integer not null default 0                  -- 같은 parent 내 사용자 정의 순서
);

-- ─────────────────────────────────────────────────────────────────────
-- v1.0 → v1.1 컬럼 보강 (활성 ALTER — 항상 실행)
--
-- ⚠️ 중요: `create table if not exists` 는 테이블이 이미 있으면 통째로 건너뛰므로,
-- v1.0 시점에 만든 todos 테이블에는 위 create 문의 신규 컬럼이 추가되지 않는다.
-- 따라서 아래 ALTER 를 **주석 없이 항상 실행**해 누락 컬럼을 보강한다 (idempotent).
alter table solo_todo.todos add column if not exists parent_id  text;
alter table solo_todo.todos add column if not exists type       text not null default 'task';
alter table solo_todo.todos add column if not exists sort_order integer not null default 0;
-- ─────────────────────────────────────────────────────────────────────

-- 이미 만든 테이블에도 grant (default privileges 는 이후 생성 객체에만 적용)
grant all on solo_todo.todos to anon, authenticated, service_role;

-- 4) RLS — 본인 row 만. drop-then-create 로 재실행 안전.
alter table solo_todo.todos enable row level security;
drop policy if exists "user_read_own"   on solo_todo.todos;
drop policy if exists "user_insert_own" on solo_todo.todos;
drop policy if exists "user_update_own" on solo_todo.todos;
drop policy if exists "user_delete_own" on solo_todo.todos;
create policy "user_read_own"   on solo_todo.todos for select using (auth.uid() = user_id);
create policy "user_insert_own" on solo_todo.todos for insert with check (auth.uid() = user_id);
create policy "user_update_own" on solo_todo.todos for update using (auth.uid() = user_id);
create policy "user_delete_own" on solo_todo.todos for delete using (auth.uid() = user_id);

-- 5) 동기화 정렬용 인덱스
create index if not exists todos_user_updated
  on solo_todo.todos (user_id, updated_at desc);

-- 6) Realtime publication 에 추가. 이미 멤버면 42710 에러나므로 조건부.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'solo_todo' and tablename = 'todos'
  ) then
    alter publication supabase_realtime add table solo_todo.todos;
  end if;
end $$;

-- ====================================================================
-- v1.2 — 카테고리 fully 동적 + Todo description
-- ====================================================================

-- 7) categories 테이블 (v1.2 신규)
create table if not exists solo_todo.categories (
  id              text primary key,
  user_id         uuid references auth.users(id) on delete cascade not null,
  label           text not null,
  icon_code_point integer not null,
  -- color_value: 0xFFRRGGBB (부호없는 32비트, 최대 ~42억) 이라 int4 초과 → bigint.
  color_value     bigint not null,
  sort_order      integer not null default 0,
  is_builtin      boolean not null default false,
  created_at      timestamptz not null default now()
);

grant all on solo_todo.categories to anon, authenticated, service_role;

-- 8) categories RLS — 본인 row 만 (todos 와 동일 패턴)
alter table solo_todo.categories enable row level security;
drop policy if exists "user_read_own_cat"   on solo_todo.categories;
drop policy if exists "user_insert_own_cat" on solo_todo.categories;
drop policy if exists "user_update_own_cat" on solo_todo.categories;
drop policy if exists "user_delete_own_cat" on solo_todo.categories;
create policy "user_read_own_cat"   on solo_todo.categories for select using (auth.uid() = user_id);
create policy "user_insert_own_cat" on solo_todo.categories for insert with check (auth.uid() = user_id);
create policy "user_update_own_cat" on solo_todo.categories for update using (auth.uid() = user_id);
create policy "user_delete_own_cat" on solo_todo.categories for delete using (auth.uid() = user_id);

-- 9) categories 정렬용 인덱스
create index if not exists categories_user_sort
  on solo_todo.categories (user_id, sort_order asc, created_at asc);

-- 10) categories Realtime publication
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'solo_todo' and tablename = 'categories'
  ) then
    alter publication supabase_realtime add table solo_todo.categories;
  end if;
end $$;

-- 11) todos.description 컬럼 (v1.2 신규)
alter table solo_todo.todos add column if not exists description text;

-- 12) todos 날짜·기간 모델 컬럼 (fast-tasks — Task 4/5/1)
alter table solo_todo.todos add column if not exists end_at      timestamptz;
alter table solo_todo.todos add column if not exists is_all_day  boolean not null default false;
alter table solo_todo.todos add column if not exists time_anchor text not null default 'start';

-- ====================================================================
-- 카테고리 상위 '그룹' 계층
-- 구조: 그룹 > 카테고리 > todo 트리. 그룹 없는 카테고리는 '미분류'(group_id null).
-- ====================================================================

-- 13) groups 테이블 (신규). categories 와 동일 컬럼 구성 (icon 없음).
create table if not exists solo_todo.groups (
  id          text primary key,
  user_id     uuid references auth.users(id) on delete cascade not null,
  label       text not null,
  -- color_value: 0xFFRRGGBB (부호없는 32비트) 이라 int4 초과 → bigint.
  color_value bigint not null,
  sort_order  integer not null default 0,
  is_builtin  boolean not null default false,
  created_at  timestamptz not null default now()
);

grant all on solo_todo.groups to anon, authenticated, service_role;

-- 14) groups RLS — 본인 row 만 (categories 와 동일 패턴)
alter table solo_todo.groups enable row level security;
drop policy if exists "user_read_own_grp"   on solo_todo.groups;
drop policy if exists "user_insert_own_grp" on solo_todo.groups;
drop policy if exists "user_update_own_grp" on solo_todo.groups;
drop policy if exists "user_delete_own_grp" on solo_todo.groups;
create policy "user_read_own_grp"   on solo_todo.groups for select using (auth.uid() = user_id);
create policy "user_insert_own_grp" on solo_todo.groups for insert with check (auth.uid() = user_id);
create policy "user_update_own_grp" on solo_todo.groups for update using (auth.uid() = user_id);
create policy "user_delete_own_grp" on solo_todo.groups for delete using (auth.uid() = user_id);

-- 15) groups 정렬용 인덱스
create index if not exists groups_user_sort
  on solo_todo.groups (user_id, sort_order asc, created_at asc);

-- 16) groups Realtime publication
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'solo_todo' and tablename = 'groups'
  ) then
    alter publication supabase_realtime add table solo_todo.groups;
  end if;
end $$;

-- 17) categories.group_id 컬럼 (신규). null = '미분류'. FK 제약 두지 않음
-- (동기화 중 일시적 dangling 허용 + 앱이 미지 group_id 를 미분류로 fallback).
alter table solo_todo.categories add column if not exists group_id text;

-- 18) color_value 를 bigint 로 (기존 int4 프로젝트 마이그레이션). 색상값
-- 0xFFRRGGBB 는 부호없는 32비트(최대 ~42억)라 int4(약 21억)를 초과 → 22003
-- (integer out of range) 으로 카테고리/그룹 업로드가 거부되던 버그 수정.
alter table solo_todo.categories alter column color_value type bigint;
alter table solo_todo.groups     alter column color_value type bigint;

-- 19) todos 날짜 반복 컬럼 (date-repeat — v7)
-- series_id: 반복 시리즈 id (마스터=자기 id / 인스턴스=마스터 id / null=일반).
-- recurrence_rule / recurrence_end_at: 마스터에만. is_series_master: 숨김 템플릿 플래그.
alter table solo_todo.todos add column if not exists series_id         text;
alter table solo_todo.todos add column if not exists recurrence_rule   text;
alter table solo_todo.todos add column if not exists recurrence_end_at timestamptz;
alter table solo_todo.todos add column if not exists is_series_master  boolean not null default false;
create index if not exists todos_series_idx on solo_todo.todos (user_id, series_id);

-- 20) categories / groups 보관(archive) 컬럼 (v1.6)
-- archived=true 면 앱의 활성 화면에서 숨김 (데이터 보존). 그룹 보관은 소속
-- 카테고리도 cascade 보관 (앱 로직). 기본 false 라 기존 row 는 활성 그대로.
alter table solo_todo.categories add column if not exists archived boolean not null default false;
alter table solo_todo.groups     add column if not exists archived boolean not null default false;

-- ─────────────────────────────────────────────────────────────────────
-- v1.1 → v1.2 마이그레이션 (기존 환경 — schema.sql 이미 실행된 프로젝트)
--
-- 이미 v1.1 시점에 위 create table / ALTER 까지 실행한 프로젝트는 categories
-- 테이블과 todos.description 컬럼이 빠진 상태이므로 아래 SQL 을 한 번 실행하면
-- 됩니다. 위 7~11 섹션이 idempotent (`if not exists` / `add column if not exists`)
-- 이므로 schema.sql 전체를 재실행해도 같은 결과입니다.
--
-- (별도 실행이 필요한 경우 위 7~11 섹션을 그대로 복사·실행. 단, RLS drop-then-
--  create 가 안전하게 재실행 됩니다.)
-- ─────────────────────────────────────────────────────────────────────
-- ====================================================================
-- PostgREST 스키마 캐시 갱신 — 컬럼/테이블 추가 후 반드시 실행.
-- PGRST204 "Could not find the '...' column in the schema cache" 방지.
-- ====================================================================
notify pgrst, 'reload schema';
