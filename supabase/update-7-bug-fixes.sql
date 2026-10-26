-- Apply after setup.sql, update-5a-leadership-team.sql, update-5b-email-alerts.sql,
-- and update-6-students-list.sql.
-- Adds announcement/video scheduling and the opt-in anonymous photo page.

alter table public.settings
  add column if not exists public_photo_page boolean not null default false;

alter table public.announcements
  add column if not exists publish_at timestamptz;
update public.announcements set publish_at = coalesce(publish_at, created_at, now());
alter table public.announcements alter column publish_at set default now();
alter table public.announcements alter column publish_at set not null;

alter table public.videos
  add column if not exists publish_at timestamptz;
update public.videos set publish_at = coalesce(publish_at, created_at, now());
alter table public.videos alter column publish_at set default now();
alter table public.videos alter column publish_at set not null;

create or replace function public.public_photo_page_enabled() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select s.public_photo_page from public.settings s where s.id = 1), false)
$$;
grant execute on function public.public_photo_page_enabled() to anon, authenticated;

drop function if exists public.public_config();
create or replace function public.public_config() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'enabled', coalesce(s.public_photo_page, false),
    'max', coalesce(s.max_photos_per_theme, 5)
  )
  from public.settings s
  where s.id = 1
$$;
grant execute on function public.public_config() to anon, authenticated;

drop policy if exists "themes read" on public.themes;
create policy "themes read" on public.themes for select using (
  public.is_admin()
  or (public.is_lu() and starts_at <= now())
  or (
    starts_at <= now()
    and public.public_photo_page_enabled()
  )
);

drop policy if exists "public approved photos read" on public.submissions;
create policy "public approved photos read" on public.submissions for select using (
  status = 'approved'
  and exists (
    select 1 from public.themes t
    where t.id = theme_id and t.ends_at <= now()
  )
  and public.public_photo_page_enabled()
);

drop policy if exists "public photo submissions" on public.submissions;
drop policy if exists "anonymous photo submissions" on public.submissions;
create policy "anonymous photo submissions" on public.submissions for insert to authenticated with check (
  auth.jwt()->>'is_anonymous' = 'true'
  and user_id = auth.uid()
  and status = 'pending'
  and length(btrim(submitted_by)) between 1 and 60
  and image_path like (auth.uid()::text || '/%')
  and exists (
    select 1 from public.themes t
    where t.id = theme_id
      and now() >= t.starts_at
      and now() < t.ends_at
  )
  and public.public_photo_page_enabled()
);

drop policy if exists "public photo uploads" on storage.objects;
drop policy if exists "anonymous photo uploads" on storage.objects;
create policy "anonymous photo uploads" on storage.objects for insert to authenticated with check (
  bucket_id = 'photos'
  and auth.jwt()->>'is_anonymous' = 'true'
  and (storage.foldername(name))[1] = auth.uid()::text
  and public.public_photo_page_enabled()
);

drop policy if exists "public approved photo files" on storage.objects;
create policy "public approved photo files" on storage.objects for select to authenticated using (
  bucket_id = 'photos'
  and exists (
    select 1 from public.submissions p
    join public.themes t on t.id = p.theme_id
    where p.image_path = name
      and p.status = 'approved'
      and t.ends_at <= now()
  )
  and public.public_photo_page_enabled()
);

create or replace function public.submissions_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  cap int;
  public_enabled boolean;
begin
  if public.is_admin() then return new; end if;

  if auth.jwt()->>'is_anonymous' = 'true' then
    select s.public_photo_page, s.max_photos_per_theme
      into public_enabled, cap
      from public.settings s where s.id = 1;
    if not coalesce(public_enabled, false) then
      raise exception 'Public photo submissions are closed.';
    end if;
    if length(btrim(new.submitted_by)) not between 1 and 60
       or new.image_path not like (auth.uid()::text || '/%') then
      raise exception 'A name and a valid visitor photo upload are required.';
    end if;
    perform pg_advisory_xact_lock(hashtextextended(new.theme_id::text || ':' || auth.uid()::text, 0));
    if (select count(*) from public.submissions
          where theme_id = new.theme_id and user_id = auth.uid()) >= cap then
      raise exception 'You can submit up to % photos per visitor session for this theme.', cap;
    end if;
    new.user_id := auth.uid();
    new.status := 'pending';
    new.submitted_by := btrim(new.submitted_by);
    return new;
  end if;

  new.user_id := auth.uid();
  new.status := 'pending';
  new.submitted_by := coalesce(
    nullif(auth.jwt()->'user_metadata'->>'full_name',''),
    nullif(auth.jwt()->'user_metadata'->>'name',''),
    split_part(auth.jwt()->>'email','@',1));
  select max_photos_per_theme into cap from public.settings where id = 1;
  perform pg_advisory_xact_lock(hashtextextended(new.theme_id::text || ':' || auth.uid()::text, 0));
  if (select count(*) from public.submissions
        where theme_id = new.theme_id and user_id = new.user_id) >= cap then
    raise exception 'You can submit up to % photos per theme.', cap;
  end if;
  return new;
end $$;

alter table public.notify_config
  add column if not exists last_batch_created_before timestamptz,
  add column if not exists last_request_test boolean not null default false;

create or replace function public.notify_new_photos(force_test boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare
  cfg public.notify_config;
  n int;
  recipients text[];
  lines text;
  subj text;
  txt text;
  req bigint;
  response_status int;
  response_content text;
  response_found boolean := false;
begin
  select * into cfg from public.notify_config where id = 1;

  if cfg.last_request_id is not null then
    select r.status_code, r.content
      into response_status, response_content
      from net._http_response r where r.id = cfg.last_request_id;
    response_found := found;

    if not response_found then
      return 'The previous email request is still processing.';
    end if;

    if not cfg.last_request_test
       and response_status between 200 and 299
       and response_content ~ '"ok"[[:space:]]*:[[:space:]]*true' then
      update public.submissions
         set notified_at = now()
       where status = 'pending'
         and notified_at is null
         and created_at <= cfg.last_batch_created_before;
    end if;

    update public.notify_config
       set last_status = response_status,
           last_request_id = null,
           last_batch_created_before = null,
           last_request_test = false
     where id = 1;
  end if;

  if coalesce(cfg.webhook_url, '') = '' or (not cfg.enabled and not force_test) then
    return 'Email alerts are off or not set up yet.';
  end if;

  select array_agg(distinct lower(email)) into recipients
    from (select email from public.leadership union select email from public.admins) r;
  if recipients is null then return 'There is nobody to email yet.'; end if;

  select count(*) into n
    from public.submissions
   where status = 'pending' and notified_at is null;
  if n = 0 and not force_test then return 'Nothing new.'; end if;

  if force_test then
    subj := 'Test email from the Latter UP portal';
    txt := 'This is a test. Email alerts for new photos are working.';
  else
    select string_agg('• ' || s.submitted_by || ' — ' || t.title, E'\n' order by s.created_at)
      into lines
      from (
        select * from public.submissions
         where status = 'pending' and notified_at is null
         order by created_at limit 30
      ) s
      join public.themes t on t.id = s.theme_id;
    subj := n || ' new photo' || case when n = 1 then '' else 's' end || ' waiting for approval';
    txt := n || ' new photo' || case when n = 1 then ' is' else 's are' end
      || E' waiting for approval:\n\n' || coalesce(lines, '')
      || case when n > 30 then E'\n…and ' || (n - 30) || ' more' else '' end
      || E'\n\nReview them here: ' || coalesce(nullif(cfg.site_url, ''), '') || '/admin.html';
  end if;

  select net.http_post(
    url := cfg.webhook_url,
    body := jsonb_build_object('secret', cfg.secret, 'to', to_jsonb(recipients), 'subject', subj, 'text', txt),
    headers := '{"Content-Type": "application/json"}'::jsonb
  ) into req;

  if req is null then return 'The email request could not be queued; pending photos will be retried.'; end if;

  update public.notify_config
     set last_request_id = req,
         last_sent_at = now(),
         last_batch_created_before = case when force_test then null else now() end,
         last_request_test = force_test
   where id = 1;
  return case when force_test then 'Test email queued.' else 'Alert queued for ' || n || ' photo(s).' end;
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
           lower(coalesce(u.raw_user_meta_data->>'must_change_password', 'false')) = 'true',
           exists (select 1 from public.admins a where lower(a.email) = lower(u.email)),
           exists (select 1 from public.leadership l where lower(l.email) = lower(u.email))
      from auth.users u
     order by lower(u.email);
end $$;
revoke all on function public.list_students() from public, anon;
grant execute on function public.list_students() to authenticated;

notify pgrst, 'reload schema';
