-- Apply after update-19-leadership-rotation-pause.sql.
-- Lets an admin preview an individual role email, sent only to their own account.

create or replace function public.send_leadership_role_test_email(
  p_role_id uuid,
  p_delivery_type text,
  p_subject text,
  p_body text
)
returns bigint
language plpgsql security definer set search_path = public, auth, net as $$
declare
  mail_cfg public.notify_config;
  role_name text;
  recipient_email text := lower(trim(coalesce(auth.jwt()->>'email', '')));
  recipient_name text := coalesce(
    nullif(auth.jwt()->'user_metadata'->>'full_name', ''),
    nullif(auth.jwt()->'user_metadata'->>'name', ''),
    split_part(lower(trim(coalesce(auth.jwt()->>'email', ''))), '@', 1)
  );
  resolved_subject text := trim(coalesce(p_subject, ''));
  resolved_body text := trim(coalesce(p_body, ''));
  request_id bigint;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if recipient_email = '' then raise exception 'Your signed-in account does not have an email address.'; end if;
  if p_delivery_type is null or p_delivery_type not in ('initial', 'followup') then
    raise exception 'Choose an initial or follow-up email template.';
  end if;
  if length(resolved_subject) not between 1 and 200
     or length(resolved_body) not between 1 and 10000 then
    raise exception 'The email subject or message is empty or too long.';
  end if;

  select name into role_name
    from public.leadership_chart_roles
   where id = p_role_id;
  if not found then raise exception 'That Student Leadership role no longer exists.'; end if;

  select * into mail_cfg from public.notify_config where id = 1;
  if not found or coalesce(mail_cfg.webhook_url, '') = '' or coalesce(mail_cfg.secret, '') = '' then
    raise exception 'Configure the Apps Script URL and secret in Admin → Email alerts first.';
  end if;

  resolved_subject := replace(resolved_subject, '{{member_name}}', recipient_name);
  resolved_subject := replace(resolved_subject, '{{role_name}}', role_name);
  resolved_subject := replace(resolved_subject, '{{week_start}}', to_char(current_date, 'FMMonth FMDD, YYYY'));
  resolved_body := replace(resolved_body, '{{member_name}}', recipient_name);
  resolved_body := replace(resolved_body, '{{role_name}}', role_name);
  resolved_body := replace(resolved_body, '{{week_start}}', to_char(current_date, 'FMMonth FMDD, YYYY'));

  select net.http_post(
    url := mail_cfg.webhook_url,
    body := jsonb_build_object(
      'secret', mail_cfg.secret,
      'to', jsonb_build_array(recipient_email),
      'subject', resolved_subject,
      'text', resolved_body
    ),
    headers := '{"Content-Type": "application/json"}'::jsonb
  ) into request_id;

  if request_id is null then raise exception 'The test email could not be queued.'; end if;
  return request_id;
end $$;
revoke all on function public.send_leadership_role_test_email(uuid, text, text, text) from public, anon;
grant execute on function public.send_leadership_role_test_email(uuid, text, text, text) to authenticated;

notify pgrst, 'reload schema';
