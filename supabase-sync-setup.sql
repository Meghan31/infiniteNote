-- InfiniteNote cloud sync — SECURED setup (v2).
-- Run ONCE in Supabase Studio → SQL Editor. Idempotent: safe to re-run, and
-- safe whether this is a fresh project or one that ran the old v1 script.
--
-- Project: https://tdgpyymwjfkqmfjetgot.supabase.co
--
-- ⚠️ REQUIRED DASHBOARD STEPS (cannot be done in SQL) — single-account model:
--   1. Authentication → Sign In / Up → DISABLE "Allow new users to sign up"
--      and DISABLE "Allow anonymous sign-ins".
--   2. Authentication → Users → "Add user" → create the ONE owner account
--      (email + strong password) and copy its credentials into the app's
--      git-ignored infinite-note/Core/Sync/SyncSecrets.swift.
--   3. If an anonymous user exists from earlier testing, delete it in
--      Authentication → Users (its synced_notebooks rows cascade-delete).
--
-- Security model (replaces v1, which let ANYONE with the publishable key
-- read, overwrite, or delete every synced notebook):
--   • sign-ups are disabled, so the single owner account is the only
--     account that can ever exist — the project is closed to strangers
--   • the `notes` bucket is PRIVATE; objects live at <user-id>/<notebook-id>.pdf
--   • every storage object and synced_notebooks row is scoped to auth.uid()
--     (defense in depth on top of the closed sign-ups)
--   • the publishable key shipped in the app grants nothing on its own,
--     so it does NOT need to be rotated
--
-- ⚠️ v1 data: old rows have no owner and are removed by this script. Old
-- storage objects (top-level <notebook-id>.pdf) can't be deleted via SQL —
-- see step 3b; they become unreadable either way. Notebooks live on-device —
-- tapping Sync again re-uploads everything.

-- 1. Bucket — create if missing, and make it PRIVATE ------------------------
insert into storage.buckets (id, name, public)
values ('notes', 'notes', false)
on conflict (id) do update set public = false;

-- 2. Drop the wide-open v1 policies ------------------------------------------
drop policy if exists "notes anon insert" on storage.objects;
drop policy if exists "notes anon update" on storage.objects;
drop policy if exists "notes anon select" on storage.objects;
drop policy if exists "notes anon delete" on storage.objects;

-- 3. Sync records -------------------------------------------------------------
-- Fresh installs get the secured shape directly.
create table if not exists public.synced_notebooks (
  user_id    uuid not null default auth.uid()
               references auth.users (id) on delete cascade,
  id         text not null,                 -- notebook id from the app
  title      text not null,
  author     text,
  page_count integer not null default 0,
  pdf_path   text not null,                 -- <user-id>/<notebook-id>.pdf
  synced_at  timestamptz not null default now(),
  primary key (user_id, id)
);

-- 3a. Upgrade a v1 table in place: wipe unowned rows, add user scoping,
--     and move the primary key to (user_id, id).
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name   = 'synced_notebooks'
      and column_name  = 'user_id'
  ) then
    delete from public.synced_notebooks;    -- v1 rows have no owner
    alter table public.synced_notebooks
      add column user_id uuid not null default auth.uid()
        references auth.users (id) on delete cascade;
    alter table public.synced_notebooks
      drop constraint if exists synced_notebooks_pkey;
    alter table public.synced_notebooks
      add primary key (user_id, id);
  end if;
end $$;

-- 3b. Old v1 storage objects (top-level <notebook-id>.pdf files) CANNOT be
-- deleted here — Supabase blocks direct SQL deletes on storage tables
-- (storage.protect_delete trigger: "Use the Storage API instead").
-- They're harmless once this script runs: the bucket is private and none of
-- the policies below match top-level paths, so nobody can read them.
-- To reclaim the space (optional): Dashboard → Storage → notes → select the
-- loose top-level .pdf files → Delete (the dashboard uses the Storage API).

alter table public.synced_notebooks enable row level security;

drop policy if exists "synced_notebooks anon all" on public.synced_notebooks;

-- 4. Owner-scoped table policies ----------------------------------------------
-- The owner account carries the `authenticated` role, so these cover it.
-- (`(select auth.uid())` instead of bare `auth.uid()` lets Postgres cache the
-- value per statement — the planner initplan optimization.)

drop policy if exists "synced_notebooks owner select" on public.synced_notebooks;
create policy "synced_notebooks owner select" on public.synced_notebooks
  for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "synced_notebooks owner insert" on public.synced_notebooks;
create policy "synced_notebooks owner insert" on public.synced_notebooks
  for insert to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists "synced_notebooks owner update" on public.synced_notebooks;
create policy "synced_notebooks owner update" on public.synced_notebooks
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists "synced_notebooks owner delete" on public.synced_notebooks;
create policy "synced_notebooks owner delete" on public.synced_notebooks
  for delete to authenticated
  using (user_id = (select auth.uid()));

-- 5. Owner-scoped storage policies ---------------------------------------------
-- Objects live at <user-id>/<notebook-id>.pdf; the first path segment must be
-- the caller's own user id.

drop policy if exists "notes owner select" on storage.objects;
create policy "notes owner select" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'notes'
    and (storage.foldername(name))[1] = (select auth.uid()::text)
  );

drop policy if exists "notes owner insert" on storage.objects;
create policy "notes owner insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'notes'
    and (storage.foldername(name))[1] = (select auth.uid()::text)
  );

drop policy if exists "notes owner update" on storage.objects;
create policy "notes owner update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'notes'
    and (storage.foldername(name))[1] = (select auth.uid()::text)
  )
  with check (
    bucket_id = 'notes'
    and (storage.foldername(name))[1] = (select auth.uid()::text)
  );

drop policy if exists "notes owner delete" on storage.objects;
create policy "notes owner delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'notes'
    and (storage.foldername(name))[1] = (select auth.uid()::text)
  );
