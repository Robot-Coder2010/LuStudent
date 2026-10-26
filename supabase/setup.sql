-- =====================================================================
-- Latter UP Student Portal — database setup
-- Run once in the Supabase SQL editor (or via migration) on a NEW project.
-- Safe to read top to bottom; each section is labeled.
-- =====================================================================

-- ---------- 1. Helper functions: who is a student, who is an admin ----------

create table public.admins (
  email text primary key            -- Google email of each admin, lowercase
);
alter table public.admins enable row level security;
-- (no policies on purpose: nobody can read/write this table directly;
--  admins are managed from the SQL editor, and checked via is_admin())

create or replace function public.is_lu() returns boolean
language sql stable as $$
  select lower(coalesce(auth.jwt()->>'email','')) like '%@latterup.org'
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.admins
    where lower(email) = lower(coalesce(auth.jwt()->>'email',''))
  )
$$;

grant execute on function public.is_lu()    to anon, authenticated;
grant execute on function public.is_admin() to anon, authenticated;

-- First admin. Add more later:  insert into public.admins values ('name@latterup.org');
insert into public.admins (email) values ('studentleadership@latterup.org');

-- ---------- 2. Only @latterup.org (or listed admins) can ever create an account ----------

create or replace function public.enforce_lu_domain() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if lower(new.email) not like '%@latterup.org'
     and not exists (select 1 from public.admins a where lower(a.email) = lower(new.email)) then
    raise exception 'Please sign in with your @latterup.org account.';
  end if;
  return new;
end $$;

create trigger enforce_lu_domain
  before insert on auth.users
  for each row execute function public.enforce_lu_domain();

-- ---------- 3. Site settings (editable from the admin page) ----------

create table public.settings (
  id int primary key default 1 check (id = 1),     -- exactly one row
  timezone text not null default 'America/Denver', -- when themes "change over"
  theme_length_days int not null default 14 check (theme_length_days between 1 and 90),
  max_photos_per_theme int not null default 5 check (max_photos_per_theme between 1 and 50)
);
insert into public.settings default values;

-- ---------- 4. Content tables ----------

create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  date date not null default current_date,
  text text,
  pdf_path text,                      -- file in the 'media' bucket
  created_at timestamptz not null default now()
);

create table public.videos (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  date date not null default current_date,
  description text,
  youtube_id text,                    -- just the ID, e.g. kzTHriM0EUo
  video_path text,                    -- OR a file in the 'media' bucket
  created_at timestamptz not null default now(),
  check (youtube_id is not null or video_path is not null)
);

create table public.faq (
  id uuid primary key default gen_random_uuid(),
  question text not null,
  answer text not null,
  sort_order int not null default 0
);

-- ---------- 5. Photo challenge ----------

create table public.themes (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  video_path text,                    -- optional finished reel (media bucket)
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index on public.themes (starts_at);

create table public.submissions (
  id uuid primary key default gen_random_uuid(),
  theme_id uuid not null references public.themes(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null, -- null = added by an admin
  submitted_by text not null,         -- name shown with the photo
  caption text,
  image_path text not null,           -- file in the 'photos' bucket
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now()
);
create index on public.submissions (theme_id, status);
create index on public.submissions (user_id);

-- Suggested dates for the NEXT theme, based on the settings above.
-- Starts when the last theme ends (or now, if none); lasts theme_length_days.
-- Uses the configured timezone so daylight-saving changes don't shift the time of day.
create or replace function public.next_theme_window()
returns table (starts_at timestamptz, ends_at timestamptz)
language plpgsql stable as $$
declare
  s public.settings;
  st timestamptz;
begin
  select * into s from public.settings where id = 1;
  select coalesce(max(t.ends_at), now()) into st from public.themes t;
  return query select
    st,
    ((st at time zone s.timezone) + make_interval(days => s.theme_length_days)) at time zone s.timezone;
end $$;
grant execute on function public.next_theme_window() to authenticated;

-- Students can't choose their own name/status/owner, and are capped per theme.
create or replace function public.submissions_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  cap int;
begin
  if not public.is_admin() then
    new.user_id := auth.uid();
    new.status := 'pending';
    new.submitted_by := coalesce(
      nullif(auth.jwt()->'user_metadata'->>'full_name',''),
      nullif(auth.jwt()->'user_metadata'->>'name',''),
      split_part(auth.jwt()->>'email','@',1));
    select max_photos_per_theme into cap from public.settings where id = 1;
    if (select count(*) from public.submissions
          where theme_id = new.theme_id and user_id = new.user_id) >= cap then
      raise exception 'You can submit up to % photos per theme.', cap;
    end if;
  end if;
  return new;
end $$;

create trigger submissions_guard
  before insert on public.submissions
  for each row execute function public.submissions_guard();

-- ---------- 6. Row Level Security (the actual lock on the data) ----------

alter table public.settings      enable row level security;
alter table public.announcements enable row level security;
alter table public.videos        enable row level security;
alter table public.faq           enable row level security;
alter table public.themes        enable row level security;
alter table public.submissions   enable row level security;

-- FAQ is public; everything else needs an @latterup.org sign-in.
create policy "faq public read"      on public.faq for select using (true);
create policy "faq admin write"      on public.faq for all using (is_admin()) with check (is_admin());

create policy "settings read"        on public.settings for select using (is_lu());
create policy "settings admin write" on public.settings for all using (is_admin()) with check (is_admin());

create policy "announcements read"   on public.announcements for select using (is_lu());
create policy "announcements admin"  on public.announcements for all using (is_admin()) with check (is_admin());

create policy "videos read"          on public.videos for select using (is_lu());
create policy "videos admin"         on public.videos for all using (is_admin()) with check (is_admin());

-- Students only see themes that have started (no spoilers about upcoming themes).
create policy "themes read"          on public.themes for select
  using (is_admin() or (is_lu() and starts_at <= now()));
create policy "themes admin"         on public.themes for all using (is_admin()) with check (is_admin());

-- Photos: students may add to the CURRENT theme only (name/status/cap are enforced by the trigger).
create policy "photos insert" on public.submissions for insert with check (
  is_lu() and user_id = auth.uid() and
  exists (select 1 from public.themes t
          where t.id = theme_id and now() >= t.starts_at and now() < t.ends_at));

-- Students see their own photos any time, and everyone's APPROVED photos only after the theme ends.
create policy "photos read" on public.submissions for select using (
  is_admin() or user_id = auth.uid() or
  (is_lu() and status = 'approved' and
   exists (select 1 from public.themes t where t.id = theme_id and t.ends_at <= now())));

-- Students can remove their own photo while the theme is still running (to swap one out).
create policy "photos delete own" on public.submissions for delete using (
  user_id = auth.uid() and
  exists (select 1 from public.themes t
          where t.id = theme_id and now() >= t.starts_at and now() < t.ends_at));

create policy "photos admin" on public.submissions for all using (is_admin()) with check (is_admin());

-- ---------- 7. File storage (both buckets are private; the site uses signed links) ----------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('photos', 'photos', false, 10485760,
     array['image/jpeg','image/png','image/webp']),
  ('media',  'media',  false, 52428800,
     array['video/mp4','video/webm','application/pdf','image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

-- photos: upload into your own folder (<your user id>/filename); view only what the
-- submissions rules above let you see (checked by looking up the matching submission row).
create policy "photos upload own folder" on storage.objects for insert to authenticated with check (
  bucket_id = 'photos' and public.is_lu() and (storage.foldername(name))[1] = auth.uid()::text);
create policy "photos view allowed" on storage.objects for select to authenticated using (
  bucket_id = 'photos' and (
    public.is_admin() or (storage.foldername(name))[1] = auth.uid()::text or
    exists (select 1 from public.submissions s where s.image_path = name)));
create policy "photos delete own folder" on storage.objects for delete to authenticated using (
  bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "photos admin" on storage.objects for all to authenticated
  using (bucket_id = 'photos' and public.is_admin()) with check (bucket_id = 'photos' and public.is_admin());

-- media (videos, PDFs): any @latterup.org student can view; only admins can upload/change.
create policy "media view" on storage.objects for select to authenticated using (
  bucket_id = 'media' and public.is_lu());
create policy "media admin" on storage.objects for all to authenticated
  using (bucket_id = 'media' and public.is_admin()) with check (bucket_id = 'media' and public.is_admin());

-- ---------- 8. Starter content carried over from the old data files ----------

insert into public.faq (question, answer, sort_order) values
($q$What is Latter UP?$q$,
 $q$Latter UP is an online, LDS-based co-op that brings students together for classes, community, and gospel learning in a virtual setting.$q$, 1),
($q$How do I join my class's google meet?$q$,
 $q$Click the Google Chat button above, or go directly to <a href="https://mail.google.com/chat" target="_blank" rel="noopener">mail.google.com/chat</a>. Make sure you're signed in with your LU account. Open the class you want and press the join meet button. You can only get on the class during class times and when a teacher is also on the meet.$q$, 2),
($q$Where do I find my assignments?$q$,
 $q$All assignments, materials, and due dates are posted in Google Classroom under each specific class. Use the Google Classroom button above to jump straight there.$q$, 3),
($q$I can't access Google Classroom — what do I do?$q$,
 $q$First, make sure you're logged in and opening the classroom with your LU account. If you're still having trouble, message us on Google Chat or send an email to tech support <a href="mailto:techsupport@latterup.org">techsupport@latterup.org</a> and we'll get you sorted out.$q$, 4),
($q$How do I contact a teacher?$q$,
 $q$Teachers can be messaged directly through Google Chat with a parent included in the chat. The teacher's email is their first and last name @latterup.org. <br> <br> For example: if your teacher was Bob Ross, the email would be: BobRoss@latterup.org$q$, 5),
($q$Who do I contact for technical issues?$q$,
 $q$For any tech trouble (login issues, video/audio problems, etc.), email <a href="mailto:techsupport@latterup.org">techsupport@latterup.org</a> and include a short description of the issue. They can get you all sorted.$q$, 6);

insert into public.announcements (title, date, text) values
($q$Weekly Activity - Touch a Temple$q$, '2026-09-02', $q$Come to the ________ temple with us and the _________ family!$q$),
($q$Weekly Activity — Back to School Kickoff$q$, '2026-08-26', $q$This week's activity is a welcome to LU hosted by the board.$q$);

insert into public.videos (title, date, description, youtube_id) values
($q$September Video$q$, '2026-08-15', $q$This is our latest video$q$, 'kzTHriM0EUo');
