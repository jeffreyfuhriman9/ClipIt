-- ClipIt Supabase schema
-- Run this in the Supabase SQL Editor (Dashboard → SQL → New query)

create table if not exists public.sessions (
  id uuid primary key,
  user_id uuid references auth.users not null,
  name text not null,
  session_number int not null,
  mode text not null,
  started_at timestamptz not null,
  ended_at timestamptz,
  is_saved boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.clips (
  id uuid primary key,
  session_id uuid references public.sessions(id) on delete cascade not null,
  user_id uuid references auth.users not null,
  triggered_at timestamptz not null,
  offset_in_session double precision not null,
  duration double precision not null,
  highlight_index int,
  custom_title text,
  custom_name text,
  is_secondary_angle boolean not null default false,
  storage_path text,
  is_uploaded boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.sessions enable row level security;
alter table public.clips enable row level security;

create policy "Users manage own sessions"
  on public.sessions
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "Users manage own clips"
  on public.clips
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

insert into storage.buckets (id, name, public)
values ('clips', 'clips', false)
on conflict (id) do nothing;

create policy "Users upload own clips"
  on storage.objects
  for insert
  with check (
    bucket_id = 'clips'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

create policy "Users read own clips"
  on storage.objects
  for select
  using (
    bucket_id = 'clips'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

create policy "Users update own clips"
  on storage.objects
  for update
  using (
    bucket_id = 'clips'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

create policy "Users delete own clips"
  on storage.objects
  for delete
  using (
    bucket_id = 'clips'
    and auth.uid()::text = (storage.foldername(name))[1]
  );
