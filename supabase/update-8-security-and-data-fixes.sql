-- Apply after update-7-bug-fixes.sql.
-- Closes the remaining RLS, scheduled-content, YouTube, and metadata gaps.
-- Deploy the change-own-password Edge Function before running this migration.
-- If this migration was run first, restore access with:
-- update auth.users
--    set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) - 'must_change_password'
--  where lower(coalesce(raw_app_meta_data->>'must_change_password', 'false')) = 'true';

drop policy if exists "admins admin manage" on public.admins;
create policy "admins admin manage" on public.admins for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create or replace function public.is_lu() returns boolean
language sql stable as $$
  select lower(coalesce(auth.jwt()->>'email','')) like '%@latterup.org'
    and coalesce(auth.jwt()->'app_metadata'->>'must_change_password', 'false') <> 'true'
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(auth.jwt()->'app_metadata'->>'must_change_password', 'false') <> 'true'
    and exists (
      select 1 from public.admins
      where lower(email) = lower(coalesce(auth.jwt()->>'email',''))
    )
$$;
grant execute on function public.is_lu() to anon, authenticated;
grant execute on function public.is_admin() to anon, authenticated;

create or replace function public.is_leader() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(auth.jwt()->'app_metadata'->>'must_change_password', 'false') <> 'true'
    and exists (
      select 1 from public.leadership
      where lower(email) = lower(coalesce(auth.jwt()->>'email', ''))
    )
$$;
grant execute on function public.is_leader() to anon, authenticated;

drop policy if exists "announcements read" on public.announcements;
drop policy if exists "announcements leader read" on public.announcements;
create policy "announcements read" on public.announcements for select to authenticated
  using (public.is_lu() and publish_at <= now());
create policy "announcements leader read" on public.announcements for select to authenticated
  using (public.is_leader());

drop policy if exists "videos read" on public.videos;
drop policy if exists "videos leader read" on public.videos;
create policy "videos read" on public.videos for select to authenticated
  using (public.is_lu() and publish_at <= now());
create policy "videos leader read" on public.videos for select to authenticated
  using (public.is_leader());

drop policy if exists "media view" on storage.objects;
create policy "media view" on storage.objects for select to authenticated using (
  bucket_id = 'media'
  and (
    public.is_admin()
    or public.is_leader()
    or exists (
      select 1 from public.announcements a
      where a.pdf_path = name and a.publish_at <= now() and public.is_lu()
    )
    or exists (
      select 1 from public.videos v
      where v.video_path = name and v.publish_at <= now() and public.is_lu()
    )
    or exists (
      select 1 from public.themes t
      where t.video_path = name and t.ends_at <= now() and public.is_lu()
    )
  )
);

drop policy if exists "photos insert" on public.submissions;
create policy "photos insert" on public.submissions for insert to authenticated with check (
  public.is_lu()
  and user_id = auth.uid()
  and image_path like (auth.uid()::text || '/%')
  and exists (
    select 1 from public.themes t
    where t.id = theme_id and now() >= t.starts_at and now() < t.ends_at
  )
);

drop policy if exists "photos read" on public.submissions;
create policy "photos read" on public.submissions for select using (
  public.is_admin()
  or (public.is_lu() and user_id = auth.uid())
  or (auth.jwt()->>'is_anonymous' = 'true' and user_id = auth.uid())
  or (
    public.is_lu()
    and status = 'approved'
    and exists (select 1 from public.themes t where t.id = theme_id and t.ends_at <= now())
  )
);

drop policy if exists "photos view allowed" on storage.objects;
create policy "photos view allowed" on storage.objects for select to authenticated using (
  bucket_id = 'photos'
  and (
    public.is_admin()
    or (public.is_lu() and (storage.foldername(name))[1] = auth.uid()::text)
    or (
      auth.jwt()->>'is_anonymous' = 'true'
      and public.public_photo_page_enabled()
      and (storage.foldername(name))[1] = 'public'
      and (storage.foldername(name))[2] = auth.uid()::text
    )
    or exists (select 1 from public.submissions s where s.image_path = name)
  )
);

drop policy if exists "photos delete own folder" on storage.objects;
create policy "photos delete own folder" on storage.objects for delete to authenticated using (
  bucket_id = 'photos'
  and (
    public.is_admin()
    or (
      public.is_lu()
      and (storage.foldername(name))[1] = auth.uid()::text
      and exists (
        select 1 from public.themes t
        where t.id::text = (storage.foldername(name))[2]
          and now() >= t.starts_at and now() < t.ends_at
      )
    )
    or (
      (
        public.is_lu()
        or (
          auth.jwt()->>'is_anonymous' = 'true'
          and public.public_photo_page_enabled()
        )
      )
      and (storage.foldername(name))[1] = auth.uid()::text
      and array_length(storage.foldername(name), 1) = 1
    )
    or (
      auth.jwt()->>'is_anonymous' = 'true'
      and public.public_photo_page_enabled()
      and (storage.foldername(name))[1] = 'public'
      and (storage.foldername(name))[2] = auth.uid()::text
      and exists (
        select 1 from public.themes t
        where t.id::text = (storage.foldername(name))[3]
          and now() >= t.starts_at and now() < t.ends_at
      )
    )
  )
);

create or replace function public.can_upload_photo(theme_path text, public_mode boolean)
returns boolean
language plpgsql security definer set search_path = public, storage as $$
declare
  cap int;
  submissions_count int;
  folder_prefix text;
begin
  if auth.uid() is null or theme_path is null then return false; end if;
  if public_mode then
    if coalesce(auth.jwt()->>'is_anonymous', 'false') <> 'true' or not public.public_photo_page_enabled() then return false; end if;
    folder_prefix := 'public/' || auth.uid()::text || '/' || theme_path || '/';
  else
    if not public.is_lu() or auth.jwt()->>'is_anonymous' = 'true' then return false; end if;
    folder_prefix := auth.uid()::text || '/' || theme_path || '/';
  end if;

  if not exists (
    select 1 from public.themes t
    where t.id::text = theme_path and now() >= t.starts_at and now() < t.ends_at
  ) then return false; end if;

  perform pg_advisory_xact_lock(hashtextextended(folder_prefix, 0));
  select s.max_photos_per_theme into cap from public.settings s where s.id = 1;
  select count(*) into submissions_count
    from public.submissions s
   where s.user_id = auth.uid() and s.theme_id::text = theme_path;
  return coalesce(submissions_count, 0) < coalesce(cap, 0);
end $$;
revoke all on function public.can_upload_photo(text, boolean) from public, anon, authenticated;
grant execute on function public.can_upload_photo(text, boolean) to authenticated;

drop policy if exists "anonymous photo submissions" on public.submissions;
create policy "anonymous photo submissions" on public.submissions for insert to authenticated with check (
  auth.jwt()->>'is_anonymous' = 'true'
  and user_id = auth.uid()
  and status = 'pending'
  and length(btrim(submitted_by)) between 1 and 60
  and image_path like ('public/' || auth.uid()::text || '/%')
  and exists (
    select 1 from public.themes t
    where t.id = theme_id and now() >= t.starts_at and now() < t.ends_at
  )
  and public.public_photo_page_enabled()
);

drop policy if exists "anonymous photo uploads" on storage.objects;
create policy "anonymous photo uploads" on storage.objects for insert to authenticated with check (
  bucket_id = 'photos'
  and auth.jwt()->>'is_anonymous' = 'true'
  and (storage.foldername(name))[1] = 'public'
  and (storage.foldername(name))[2] = auth.uid()::text
  and public.can_upload_photo((storage.foldername(name))[3], true)
);

drop policy if exists "photos upload own folder" on storage.objects;
create policy "photos upload own folder" on storage.objects for insert to authenticated with check (
  bucket_id = 'photos'
  and public.is_lu()
  and (storage.foldername(name))[1] = auth.uid()::text
  and public.can_upload_photo((storage.foldername(name))[2], false)
);

create or replace function public.submissions_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  cap int;
  public_enabled boolean;
  display_name text;
begin
  if public.is_admin() and new.user_id is null then
    new.submitted_by := regexp_replace(btrim(new.submitted_by), '[[:cntrl:]]+', ' ', 'g');
    return new;
  end if;

  if auth.jwt()->>'is_anonymous' = 'true' then
    select s.public_photo_page, s.max_photos_per_theme
      into public_enabled, cap
      from public.settings s where s.id = 1;
    if not coalesce(public_enabled, false) then
      raise exception 'Public photo submissions are closed.';
    end if;
    if length(btrim(new.submitted_by)) not between 1 and 60
       or new.image_path not like ('public/' || auth.uid()::text || '/%') then
      raise exception 'A name and a valid visitor photo upload are required.';
    end if;
    perform pg_advisory_xact_lock(hashtextextended(new.theme_id::text || ':' || auth.uid()::text, 0));
    if (select count(*) from public.submissions
          where theme_id = new.theme_id and user_id = auth.uid()) >= cap then
      raise exception 'You can submit up to % photos per visitor session for this theme.', cap;
    end if;
    new.user_id := auth.uid();
    new.status := 'pending';
    new.submitted_by := regexp_replace(btrim(new.submitted_by), '[[:cntrl:]]+', ' ', 'g');
    return new;
  end if;

  new.user_id := auth.uid();
  new.status := 'pending';
  display_name := coalesce(
    nullif(auth.jwt()->'app_metadata'->>'full_name',''),
    split_part(auth.jwt()->>'email','@',1));
  new.submitted_by := regexp_replace(btrim(display_name), '[[:cntrl:]]+', ' ', 'g');
  select max_photos_per_theme into cap from public.settings where id = 1;
  perform pg_advisory_xact_lock(hashtextextended(new.theme_id::text || ':' || auth.uid()::text, 0));
  if (select count(*) from public.submissions
        where theme_id = new.theme_id and user_id = new.user_id) >= cap then
    raise exception 'You can submit up to % photos per theme.', cap;
  end if;
  return new;
end $$;

create or replace function public.next_theme_window()
returns table (starts_at timestamptz, ends_at timestamptz)
language plpgsql stable as $$
declare
  s public.settings;
  st timestamptz;
begin
  select * into s from public.settings where id = 1;
  select greatest(coalesce(max(t.ends_at), now()), now()) into st from public.themes t;
  return query select
    st,
    ((st at time zone s.timezone) + make_interval(days => s.theme_length_days)) at time zone s.timezone;
end $$;
grant execute on function public.next_theme_window() to authenticated;

do $$
begin
  if exists (
    select 1 from public.settings s
    where not exists (select 1 from pg_timezone_names z where z.name = s.timezone)
  ) then
    raise notice 'An invalid settings.timezone was replaced with the setup default America/Denver.';
    update public.settings s
       set timezone = 'America/Denver'
     where not exists (select 1 from pg_timezone_names z where z.name = s.timezone);
  end if;
end $$;

create or replace function public.validate_settings_timezone() returns trigger
language plpgsql set search_path = public as $$
begin
  if not exists (select 1 from pg_timezone_names where name = new.timezone) then
    raise exception 'Unknown time zone: %', new.timezone;
  end if;
  return new;
end $$;
drop trigger if exists validate_settings_timezone on public.settings;
create trigger validate_settings_timezone before insert or update of timezone on public.settings
  for each row execute function public.validate_settings_timezone();

create or replace function public.portal_public_config() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'portal_banner', s.portal_banner,
    'portal_tiles', s.portal_tiles,
    'portal_home_sections', s.portal_home_sections
  )
  from public.settings s where s.id = 1
$$;
grant execute on function public.portal_public_config() to anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.videos'::regclass and conname = 'videos_youtube_id_format'
  ) then
    alter table public.videos add constraint videos_youtube_id_format
      check (youtube_id is null or youtube_id ~ '^[A-Za-z0-9_-]{11}$') not valid;
  end if;
end $$;

create or replace function public.list_students()
returns table (email text, full_name text, created_at timestamptz, last_sign_in_at timestamptz,
               must_change_password boolean, admin_role boolean, leader_role boolean)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  return query
    select u.email::text,
           coalesce(u.raw_app_meta_data->>'full_name', '')::text,
           u.created_at,
           u.last_sign_in_at,
           lower(coalesce(u.raw_app_meta_data->>'must_change_password',
                          u.raw_user_meta_data->>'must_change_password', 'false')) = 'true',
           exists (select 1 from public.admins a where lower(a.email) = lower(u.email)),
           exists (select 1 from public.leadership l where lower(l.email) = lower(u.email))
      from auth.users u
     order by lower(u.email);
end $$;
revoke all on function public.list_students() from public, anon;
grant execute on function public.list_students() to authenticated;

update auth.users
   set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb)
       || jsonb_build_object('must_change_password', true)
 where lower(coalesce(raw_user_meta_data->>'must_change_password', 'false')) = 'true'
   and lower(coalesce(raw_app_meta_data->>'must_change_password', 'false')) <> 'true';

notify pgrst, 'reload schema';
