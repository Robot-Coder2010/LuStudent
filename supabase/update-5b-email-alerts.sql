-- Run AFTER update-5a (paste the code itself, not the file name).
-- Emails the Leadership team + Admins when new photos are waiting for approval.
-- One email at most every 5 minutes, no matter how many photos came in.
-- If the two "create extension" lines fail, switch on "pg_net" and "pg_cron" in
-- Dashboard -> Database -> Extensions, then run this file again.

create extension if not exists pg_net;
create extension if not exists pg_cron;

create table if not exists public.notify_config (
  id int primary key default 1 check (id = 1),
  enabled boolean not null default false,
  webhook_url text,            -- Google Apps Script web app address
  secret text,                 -- shared secret code checked by the script
  site_url text,               -- e.g. https://your-site.netlify.app (for the link in the email)
  last_request_id bigint,
  last_sent_at timestamptz,
  last_status int
);
insert into public.notify_config (id) values (1) on conflict do nothing;
alter table public.notify_config enable row level security;
drop policy if exists "notify admin" on public.notify_config;
create policy "notify admin" on public.notify_config for all
  using (public.is_admin()) with check (public.is_admin());

alter table public.submissions add column if not exists notified_at timestamptz;
update public.submissions set notified_at = now() where notified_at is null;  -- don't announce old photos

create or replace function public.notify_new_photos(force_test boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare
  cfg public.notify_config;
  n int; recipients text[]; lines text; subj text; txt text; req bigint;
begin
  select * into cfg from public.notify_config where id = 1;

  if cfg.last_request_id is not null then      -- remember how the previous email request went
    update public.notify_config
       set last_status = (select status_code from net._http_response where id = cfg.last_request_id)
     where id = 1;
  end if;

  if coalesce(cfg.webhook_url, '') = '' or (not cfg.enabled and not force_test) then
    return 'Email alerts are off or not set up yet.';
  end if;

  select array_agg(distinct lower(email)) into recipients
    from (select email from public.leadership union select email from public.admins) r;
  if recipients is null then return 'There is nobody to email yet.'; end if;

  select count(*) into n from public.submissions where status = 'pending' and notified_at is null;
  if n = 0 and not force_test then return 'Nothing new.'; end if;

  select string_agg('• ' || s.submitted_by || ' — ' || t.title, E'\n' order by s.created_at) into lines
    from (select * from public.submissions
           where status = 'pending' and notified_at is null order by created_at limit 30) s
    join public.themes t on t.id = s.theme_id;

  if force_test then
    subj := 'Test email from the Latter UP portal';
    txt  := 'This is a test. Email alerts for new photos are working.';
  else
    subj := n || ' new photo' || case when n = 1 then '' else 's' end || ' waiting for approval';
    txt  := n || ' new photo' || case when n = 1 then ' is' else 's are' end
            || E' waiting for approval:\n\n' || coalesce(lines, '')
            || case when n > 30 then E'\n…and ' || (n - 30) || ' more' else '' end
            || E'\n\nReview them here: ' || coalesce(nullif(cfg.site_url, ''), '') || '/admin.html';
  end if;

  select net.http_post(
           url := cfg.webhook_url,
           body := jsonb_build_object('secret', cfg.secret, 'to', to_jsonb(recipients), 'subject', subj, 'text', txt),
           headers := '{"Content-Type": "application/json"}'::jsonb
         ) into req;

  update public.notify_config set last_request_id = req, last_sent_at = now() where id = 1;
  if not force_test then
    update public.submissions set notified_at = now() where status = 'pending' and notified_at is null;
  end if;
  return case when force_test then 'Test email requested.' else 'Alert sent for ' || n || ' photo(s).' end;
end $$;

revoke all on function public.notify_new_photos(boolean) from public, anon, authenticated;

create or replace function public.send_test_alert() returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  return public.notify_new_photos(true);
end $$;
grant execute on function public.send_test_alert() to authenticated;

select cron.schedule('notify-new-photos', '*/5 * * * *', 'select public.notify_new_photos()');
