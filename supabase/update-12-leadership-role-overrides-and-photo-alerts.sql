-- Apply after update-11-email-alert-diagnostics.sql.
-- Adds weekly role overrides, pre-login Student Leadership enrollment,
-- and configurable photo-alert recipients.

create table if not exists public.leadership_role_overrides (
  week_start date not null,
  role_id uuid not null references public.leadership_chart_roles(id) on delete cascade,
  member_email text not null references public.leadership_chart_members(email) on delete cascade,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (week_start, role_id),
  unique (week_start, member_email)
);
alter table public.leadership_role_overrides enable row level security;
drop policy if exists "leadership role overrides read" on public.leadership_role_overrides;
create policy "leadership role overrides read" on public.leadership_role_overrides
  for select to authenticated using (public.is_admin() or public.can_view_leadership_hub());
grant select on public.leadership_role_overrides to authenticated;

create or replace function public.set_leadership_role_override(
  p_week_start date,
  p_role_id uuid,
  p_member_email text
)
returns void
language plpgsql security definer set search_path = public, auth as $$
declare
  rotation_day int;
  expected_week_start date;
  normalized_email text := lower(trim(coalesce(p_member_email, '')));
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;

  select rotation_weekday into rotation_day from public.leadership_hub_settings where id = 1;
  expected_week_start := (now() at time zone 'UTC')::date
    - (((extract(dow from (now() at time zone 'UTC'))::integer - rotation_day + 7) % 7));
  if p_week_start <> expected_week_start then
    raise exception 'Manual role assignments only apply to the current rotation week.';
  end if;
  if not exists (select 1 from public.leadership_chart_roles where id = p_role_id) then
    raise exception 'That Student Leadership role no longer exists.';
  end if;

  if normalized_email = '' then
    delete from public.leadership_role_overrides
     where week_start = p_week_start and role_id = p_role_id;
    return;
  end if;
  if not exists (
    select 1 from public.leadership_chart_members
     where email = normalized_email
  ) then
    raise exception 'That person is not on the Student Leadership roster.';
  end if;
  if exists (
    select 1 from public.leadership_role_overrides
     where week_start = p_week_start
       and member_email = normalized_email
       and role_id <> p_role_id
  ) then
    raise exception 'That person is already manually assigned to another role this week.';
  end if;

  insert into public.leadership_role_overrides (week_start, role_id, member_email, created_by)
  values (p_week_start, p_role_id, normalized_email, auth.uid())
  on conflict (week_start, role_id) do update
    set member_email = excluded.member_email,
        created_by = excluded.created_by,
        created_at = now();
end $$;
revoke all on function public.set_leadership_role_override(date, uuid, text) from public, anon;
grant execute on function public.set_leadership_role_override(date, uuid, text) to authenticated;

alter table public.notify_config
  add column if not exists photo_alert_audience text not null default 'all';
alter table public.notify_config
  drop constraint if exists notify_config_photo_alert_audience_check;
alter table public.notify_config
  add constraint notify_config_photo_alert_audience_check
  check (photo_alert_audience in ('all', 'leaders', 'off'));

create or replace function public.notify_new_photos(force_test boolean default false)
returns text
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
begin
  select * into cfg from public.notify_config where id = 1;

  if cfg.last_request_id is not null then
    select r.status_code, r.content
      into response_status, response_content
      from net._http_response r
     where r.id = cfg.last_request_id;
    if not found then return 'The previous email request is still processing.'; end if;

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
           last_response = left(response_content, 2000),
           last_request_id = null,
           last_batch_created_before = null,
           last_request_test = false
     where id = 1;
  end if;

  if coalesce(cfg.webhook_url, '') = '' or (not cfg.enabled and not force_test) then
    return 'Email alerts are off or not set up yet.';
  end if;
  if not force_test and cfg.photo_alert_audience = 'off' then
    return 'Photo challenge email notifications are turned off.';
  end if;

  if force_test then
    recipients := array[lower(coalesce(auth.jwt()->>'email', ''))];
  elsif cfg.photo_alert_audience = 'leaders' then
    select array_agg(distinct lower(email)) into recipients
      from public.leadership
     where lower(email) like '%@latterup.org';
  else
    select array_agg(distinct lower(email)) into recipients
      from (
        select email from public.leadership
        union
        select email from public.admins
      ) r
     where lower(email) like '%@latterup.org';
  end if;
  if recipients is null or cardinality(recipients) = 0 then
    return 'There are no valid recipients to email.';
  end if;

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

create or replace function public.send_test_alert()
returns text
language plpgsql security definer set search_path = public, net as $$
declare
  cfg public.notify_config;
  recipient text := lower(coalesce(auth.jwt()->>'email', ''));
  status_result jsonb;
  req bigint;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if recipient not like '%@latterup.org' then
    raise exception 'A valid @latterup.org address is required to send a test email.';
  end if;

  status_result := public.check_email_alert_status();
  if coalesce((status_result->>'pending')::boolean, false) then
    raise exception 'The previous email request is still processing. Try the test again in a few seconds.';
  end if;
  select * into cfg from public.notify_config where id = 1;
  if coalesce(cfg.webhook_url, '') = '' then
    raise exception 'Save the Apps Script web app URL before sending a test.';
  end if;

  select net.http_post(
    url := cfg.webhook_url,
    body := jsonb_build_object(
      'secret', cfg.secret,
      'to', jsonb_build_array(recipient),
      'subject', 'Test email from the Latter UP portal',
      'text', 'This is a test. Email alerts for new photos are working.'
    ),
    headers := '{"Content-Type": "application/json"}'::jsonb
  ) into req;
  if req is null then raise exception 'The test email could not be queued.'; end if;

  update public.notify_config
     set last_request_id = req,
         last_sent_at = now(),
         last_batch_created_before = null,
         last_request_test = true
   where id = 1;
  return 'Test email queued to your account only.';
end $$;
revoke all on function public.send_test_alert() from public, anon;
grant execute on function public.send_test_alert() to authenticated;

notify pgrst, 'reload schema';
