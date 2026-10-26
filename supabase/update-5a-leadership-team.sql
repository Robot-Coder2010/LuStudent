-- Run once in the Supabase SQL Editor (paste the code itself, not the file name).
-- Adds a "Leadership team" role between students and admins.
--   Leadership CAN: add announcements, videos and photo themes; approve/reject photos.
--   Leadership CANNOT: edit or delete anything, import photos, change settings,
--                      manage students/admins, or edit the site layout. (Admins keep full control.)

create table if not exists public.leadership (email text primary key);   -- lowercase @latterup.org emails
alter table public.leadership enable row level security;
drop policy if exists "leadership admin manage" on public.leadership;
create policy "leadership admin manage" on public.leadership for all
  using (public.is_admin()) with check (public.is_admin());

create or replace function public.is_leader() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.leadership
                 where lower(email) = lower(coalesce(auth.jwt()->>'email', '')))
$$;

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select case when public.is_admin() then 'admin'
              when public.is_leader() then 'leader'
              else 'student' end
$$;

grant execute on function public.is_leader() to anon, authenticated;
grant execute on function public.my_role()   to anon, authenticated;

-- Announcements: leaders can see everything (including scheduled) and add new ones.
drop policy if exists "announcements leader read" on public.announcements;
create policy "announcements leader read" on public.announcements for select using (public.is_leader());
drop policy if exists "announcements leader add" on public.announcements;
create policy "announcements leader add" on public.announcements for insert with check (public.is_leader());

-- Videos: same.
drop policy if exists "videos leader read" on public.videos;
create policy "videos leader read" on public.videos for select using (public.is_leader());
drop policy if exists "videos leader add" on public.videos;
create policy "videos leader add" on public.videos for insert with check (public.is_leader());

-- Photo themes: leaders can see all (including upcoming) and add new ones. No edit, no delete.
drop policy if exists "themes leader read" on public.themes;
create policy "themes leader read" on public.themes for select using (public.is_leader());
drop policy if exists "themes leader add" on public.themes;
create policy "themes leader add" on public.themes for insert with check (public.is_leader());

-- Photos: leaders can see every photo and change its status (approve/reject) — nothing else.
drop policy if exists "photos leader read" on public.submissions;
create policy "photos leader read" on public.submissions for select using (public.is_leader());
drop policy if exists "photos leader review" on public.submissions;
create policy "photos leader review" on public.submissions for update
  using (public.is_leader()) with check (public.is_leader());

create or replace function public.submissions_leader_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_admin() or not public.is_leader() then return new; end if;
  if new.theme_id    is distinct from old.theme_id
  or new.user_id     is distinct from old.user_id
  or new.submitted_by is distinct from old.submitted_by
  or new.caption     is distinct from old.caption
  or new.image_path  is distinct from old.image_path then
    raise exception 'Leadership can only approve or reject photos.';
  end if;
  return new;
end $$;

drop trigger if exists submissions_leader_guard on public.submissions;
create trigger submissions_leader_guard before update on public.submissions
  for each row execute function public.submissions_leader_guard();

-- Files: leaders can upload flyers/videos for the announcements and videos they add (no replace/delete).
drop policy if exists "media leader upload" on storage.objects;
create policy "media leader upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and public.is_leader());
