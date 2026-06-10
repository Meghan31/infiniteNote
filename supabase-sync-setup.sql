-- InfiniteNote cloud sync — run ONCE in Supabase Studio → SQL Editor.
-- Project: https://tdgpyymwjfkqmfjetgot.supabase.co
--
-- Creates:
--   1. a public "notes" storage bucket (one PDF per notebook, overwritten on sync)
--   2. storage policies so the app (publishable/anon key) can upload, overwrite + delete
--   3. a synced_notebooks table recording each notebook's latest sync

-- 1. Bucket ------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('notes', 'notes', true)
on conflict (id) do nothing;

-- 2. Storage policies ---------------------------------------------------
create policy "notes anon insert" on storage.objects
  for insert to anon
  with check (bucket_id = 'notes');

create policy "notes anon update" on storage.objects
  for update to anon
  using (bucket_id = 'notes')
  with check (bucket_id = 'notes');

create policy "notes anon select" on storage.objects
  for select to anon
  using (bucket_id = 'notes');

-- Required for unsync: without this, RLS hides the object and the delete
-- returns 404, which the app tolerates — so the PDF silently stays in cloud.
create policy "notes anon delete" on storage.objects
  for delete to anon
  using (bucket_id = 'notes');

-- 3. Sync records --------------------------------------------------------
create table if not exists public.synced_notebooks (
  id         text primary key,                 -- notebook id from the app
  title      text not null,
  author     text,
  page_count integer not null default 0,
  pdf_path   text not null,                    -- path inside the notes bucket
  synced_at  timestamptz not null default now()
);

alter table public.synced_notebooks enable row level security;

create policy "synced_notebooks anon all" on public.synced_notebooks
  for all to anon
  using (true)
  with check (true);
