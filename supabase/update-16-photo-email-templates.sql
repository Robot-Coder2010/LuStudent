-- Apply after update-15-portal-banner-dismissals.sql.
-- Adds editable subject/body templates for photo-submission alert emails.

alter table public.notify_config
  add column if not exists photo_email_subject text not null
    default '{{photo_count}} waiting for approval',
  add column if not exists photo_email_body text not null
    default E'{{photo_count}} waiting for approval:\n\n{{photo_list}}\n\nReview them here: {{review_url}}';

alter table public.notify_config
  drop constraint if exists notify_config_photo_email_subject_check,
  drop constraint if exists notify_config_photo_email_body_check;
alter table public.notify_config
  add constraint notify_config_photo_email_subject_check
    check (length(trim(photo_email_subject)) between 1 and 200),
  add constraint notify_config_photo_email_body_check
    check (length(trim(photo_email_body)) between 1 and 10000);

create or replace function public.notify_new_photos(force_test boolean default false)
returns text
language plpgsql security definer set search_path = public as $$
declare
  cfg public.notify_config;
  n int;
  recipients text[];
  lines text;
  photo_count text;
  subj text;
  txt text;
  review_url text;
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
  if force_test then n := 2; end if;
  photo_count := n || case when n = 1 then ' new photo' else ' new photos' end;

  if force_test then
    lines := '• Sample Student — Sample Theme' || E'\n' || '• Another Student — Another Theme';
  else
    select string_agg('• ' || s.submitted_by || ' — ' || t.title, E'\n' order by s.created_at)
      into lines
      from (
        select * from public.submissions
         where status = 'pending' and notified_at is null
         order by created_at limit 30
      ) s
      join public.themes t on t.id = s.theme_id;
    if n > 30 then
      lines := coalesce(lines, '') || E'\n…and ' || (n - 30) || ' more';
    end if;
  end if;

  review_url := coalesce(nullif(cfg.site_url, ''), '') || '/admin.html';
  subj := replace(coalesce(cfg.photo_email_subject, '{{photo_count}} waiting for approval'),
                  '{{photo_count}}', photo_count);
  subj := replace(subj, '{{count}}', n::text);
  subj := replace(subj, '{{photo_list}}', coalesce(lines, ''));
  subj := replace(subj, '{{review_url}}', review_url);
  txt := replace(coalesce(cfg.photo_email_body, ''), '{{photo_count}}', photo_count);
  txt := replace(txt, '{{count}}', n::text);
  txt := replace(txt, '{{photo_list}}', coalesce(lines, ''));
  txt := replace(txt, '{{review_url}}', review_url);
  if force_test then
    subj := '[TEST] ' || subj;
    txt := 'Test email sent only to you.' || E'\n\n' || txt;
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
  return case when force_test then 'Test email queued to your account only.' else 'Alert queued for ' || n || ' photo(s).' end;
end $$;

create or replace function public.send_test_alert()
returns text
language plpgsql security definer set search_path = public, net as $$
declare
  cfg public.notify_config;
  status_result jsonb;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if lower(coalesce(auth.jwt()->>'email', '')) not like '%@latterup.org' then
    raise exception 'A valid @latterup.org address is required to send a test email.';
  end if;
  select * into cfg from public.notify_config where id = 1;
  if coalesce(cfg.webhook_url, '') = '' then
    raise exception 'Save the Apps Script web app URL before sending a test.';
  end if;
  status_result := public.check_email_alert_status();
  if coalesce((status_result->>'pending')::boolean, false) then
    raise exception 'The previous email request is still processing. Try the test again in a few seconds.';
  end if;
  return public.notify_new_photos(true);
end $$;

revoke all on function public.send_test_alert() from public, anon;
grant execute on function public.send_test_alert() to authenticated;

notify pgrst, 'reload schema';
