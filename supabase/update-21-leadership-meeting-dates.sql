-- Apply after update-20-leadership-role-test-email.sql.
-- Adds the next meeting date to SL role emails and default role templates.

update public.leadership_role_email_templates
   set initial_body = rtrim(initial_body) || E'\n\nOur next meeting is on {{meeting_date}}.',
       updated_at = now()
 where initial_body not like '%{{meeting_date}}%';

update public.leadership_role_email_templates
   set followup_body = rtrim(followup_body) || E'\n\nOur next meeting is on {{meeting_date}}.',
       updated_at = now()
 where followup_body not like '%{{meeting_date}}%';

create or replace function public.create_leadership_role_email_template()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.leadership_role_email_templates
    (role_id, initial_subject, initial_body, followup_subject, followup_body)
  values
    (new.id,
     '{{role_name}} — your Student Leadership assignment',
     E'Hi {{member_name}},\n\nYou are assigned to {{role_name}} for the week of {{week_start}}.\n\nOur next meeting is on {{meeting_date}}.\n\nThank you for serving!',
     'Reminder: {{role_name}} this week',
     E'Hi {{member_name}},\n\nThis is a reminder that you are assigned to {{role_name}} for the week of {{week_start}}.\n\nOur next meeting is on {{meeting_date}}.\n\nThank you for serving!')
  on conflict (role_id) do nothing;
  return new;
end $$;
revoke all on function public.create_leadership_role_email_template() from public, anon, authenticated;

create or replace function public.process_leadership_role_emails()
returns void
language plpgsql security definer set search_path = public, net as $$
declare
  cfg public.leadership_role_email_settings;
  hub_settings public.leadership_hub_settings;
  mail_cfg public.notify_config;
  role_template public.leadership_role_email_templates;
  rotation_day int;
  send_day int;
  local_now timestamp;
  local_date date;
  rotation_week_start date;
  target_week_start date;
  pause_resume_date date;
  initial_at timestamptz;
  followup_at timestamptz;
  followup_offset int;
  assignment record;
  delivery record;
  request_id bigint;
  response_status int;
  response_content text;
  resolved_subject text;
  resolved_body text;
  assigned_role_name text;
  meeting_date_text text;
  pause_active boolean;
begin
  select * into cfg from public.leadership_role_email_settings where id = 1;
  if not found then return; end if;
  select * into hub_settings from public.leadership_hub_settings where id = 1;
  if not found then return; end if;
  rotation_day := hub_settings.rotation_weekday;
  local_now := now() at time zone 'America/New_York';
  local_date := local_now::date;
  if hub_settings.rotation_paused
     and hub_settings.next_meeting_date < local_date then
    update public.leadership_hub_settings
       set rotation_paused = false
     where id = 1;
    hub_settings.rotation_paused := false;
  end if;
  pause_resume_date := case when hub_settings.next_meeting_date is null then null
    else hub_settings.next_meeting_date
      - coalesce(nullif(mod(extract(dow from hub_settings.next_meeting_date)::int - 4 + 7, 7), 0), 7)
    end;
  pause_active := hub_settings.rotation_paused
    and (pause_resume_date is null or local_date < pause_resume_date);

  if pause_active then
    update public.leadership_role_email_deliveries
       set status = 'cancelled'
     where status = 'pending';
  elsif cfg.enabled and rotation_day is not null then
    select * into mail_cfg from public.notify_config where id = 1;
    if found and coalesce(mail_cfg.webhook_url, '') <> '' and coalesce(mail_cfg.secret, '') <> '' then
      if hub_settings.rotation_paused and local_date = pause_resume_date then
        send_day := 4;
      else
        send_day := coalesce(cfg.initial_day, rotation_day);
      end if;

      if extract(dow from local_now)::int = send_day
         and local_now::time >= cfg.initial_time then
        if hub_settings.rotation_paused and local_date = pause_resume_date then
          target_week_start := public.leadership_rotation_week_start(
            hub_settings.next_meeting_date, rotation_day
          );
        else
          rotation_week_start := (now() at time zone 'UTC')::date
            - mod(extract(dow from (now() at time zone 'UTC'))::int - rotation_day + 7, 7);
          target_week_start := rotation_week_start
            + case when send_day < rotation_day then 7 else 0 end;
        end if;
        initial_at := (local_date + cfg.initial_time) at time zone 'America/New_York';
        followup_offset := mod(cfg.followup_day - send_day + 7, 7);
        if followup_offset = 0 then followup_offset := 7; end if;
        followup_at := (local_date + followup_offset + cfg.followup_time) at time zone 'America/New_York';

        for assignment in
          select * from public.leadership_role_email_assignments(target_week_start)
        loop
          foreach assigned_role_name in array assignment.assigned_roles
          loop
            insert into public.leadership_role_email_deliveries
              (week_start, delivery_type, member_email, member_name, roles, role_id, role_name, scheduled_for)
            select target_week_start, 'initial', assignment.assigned_email, assignment.assigned_name,
                   array[chart_role.name], chart_role.id, chart_role.name, initial_at
              from public.leadership_chart_roles chart_role where chart_role.name = assigned_role_name
            on conflict (week_start, delivery_type, member_email, role_id) do nothing;

            insert into public.leadership_role_email_deliveries
              (week_start, delivery_type, member_email, member_name, roles, role_id, role_name, scheduled_for)
            select target_week_start, 'followup', assignment.assigned_email, assignment.assigned_name,
                   array[chart_role.name], chart_role.id, chart_role.name, followup_at
              from public.leadership_chart_roles chart_role where chart_role.name = assigned_role_name
            on conflict (week_start, delivery_type, member_email, role_id) do nothing;
          end loop;
        end loop;
      end if;
    end if;
  end if;

  for delivery in
    select * from public.leadership_role_email_deliveries
     where status = 'sending' and request_id is not null
  loop
    select status_code, content into response_status, response_content
      from net._http_response where id = delivery.request_id;
    if found then
      if response_status between 200 and 299
         and response_content ~ '"ok"[[:space:]]*:[[:space:]]*true' then
        update public.leadership_role_email_deliveries
           set status = 'sent', sent_at = now(), request_id = null, last_error = null
         where id = delivery.id;
      else
        update public.leadership_role_email_deliveries
           set status = case when attempts >= 3 then 'failed' else 'pending' end,
               request_id = null,
               next_attempt_at = now() + interval '5 minutes',
               last_error = left(coalesce(response_content, 'Email service rejected the request.'), 2000)
         where id = delivery.id;
      end if;
    elsif delivery.requested_at < now() - interval '15 minutes' then
      update public.leadership_role_email_deliveries
         set status = case when attempts >= 3 then 'failed' else 'pending' end,
             request_id = null,
             next_attempt_at = now() + interval '5 minutes',
             last_error = 'No response was received from the email service.'
       where id = delivery.id;
    end if;
  end loop;

  if not cfg.enabled then
    update public.leadership_role_email_deliveries
       set status = 'cancelled'
     where status = 'pending';
    return;
  end if;
  select * into mail_cfg from public.notify_config where id = 1;
  if not found or coalesce(mail_cfg.webhook_url, '') = '' or coalesce(mail_cfg.secret, '') = '' then return; end if;

  for delivery in
    select * from public.leadership_role_email_deliveries
     where status = 'pending'
       and scheduled_for <= now()
       and next_attempt_at <= now()
       and attempts < 3
       and (delivery_type <> 'followup' or cfg.followup_enabled)
     order by scheduled_for, id
  loop
    select * into role_template
      from public.leadership_role_email_templates
     where role_id = delivery.role_id;
    if not found then
      update public.leadership_role_email_deliveries
         set status = 'failed', last_error = 'No email template exists for this role.'
       where id = delivery.id;
      continue;
    end if;

    meeting_date_text := coalesce(
      to_char(hub_settings.next_meeting_date, 'FMMonth FMDD, YYYY'),
      'a date to be announced'
    );
    if delivery.delivery_type = 'initial' then
      resolved_subject := role_template.initial_subject;
      resolved_body := role_template.initial_body;
    else
      resolved_subject := role_template.followup_subject;
      resolved_body := role_template.followup_body;
    end if;
    resolved_subject := replace(resolved_subject, '{{member_name}}', delivery.member_name);
    resolved_subject := replace(resolved_subject, '{{role_name}}', delivery.role_name);
    resolved_subject := replace(resolved_subject, '{{week_start}}', to_char(delivery.week_start, 'FMMonth FMDD, YYYY'));
    resolved_subject := replace(resolved_subject, '{{meeting_date}}', meeting_date_text);
    resolved_body := replace(resolved_body, '{{member_name}}', delivery.member_name);
    resolved_body := replace(resolved_body, '{{role_name}}', delivery.role_name);
    resolved_body := replace(resolved_body, '{{week_start}}', to_char(delivery.week_start, 'FMMonth FMDD, YYYY'));
    resolved_body := replace(resolved_body, '{{meeting_date}}', meeting_date_text);

    select net.http_post(
      url := mail_cfg.webhook_url,
      body := jsonb_build_object(
        'secret', mail_cfg.secret,
        'to', jsonb_build_array(delivery.member_email),
        'subject', resolved_subject,
        'text', resolved_body
      ),
      headers := '{"Content-Type": "application/json"}'::jsonb
    ) into request_id;

    if request_id is null then
      update public.leadership_role_email_deliveries
         set attempts = attempts + 1,
             status = case when attempts + 1 >= 3 then 'failed' else 'pending' end,
             next_attempt_at = now() + interval '5 minutes',
             last_error = 'The email request could not be queued.'
       where id = delivery.id;
    else
      update public.leadership_role_email_deliveries
         set status = 'sending',
             request_id = request_id,
             requested_at = now(),
             attempts = attempts + 1,
             last_error = null
       where id = delivery.id;
    end if;
  end loop;
end $$;
revoke all on function public.process_leadership_role_emails() from public, anon, authenticated;

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
  hub_settings public.leadership_hub_settings;
  role_name text;
  recipient_email text := lower(trim(coalesce(auth.jwt()->>'email', '')));
  recipient_name text := coalesce(
    nullif(auth.jwt()->'user_metadata'->>'full_name', ''),
    nullif(auth.jwt()->'user_metadata'->>'name', ''),
    split_part(lower(trim(coalesce(auth.jwt()->>'email', ''))), '@', 1)
  );
  meeting_date_text text;
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

  select * into hub_settings from public.leadership_hub_settings where id = 1;
  if not found then raise exception 'Student Leadership settings are missing.'; end if;
  meeting_date_text := coalesce(
    to_char(hub_settings.next_meeting_date, 'FMMonth FMDD, YYYY'),
    'a date to be announced'
  );

  select * into mail_cfg from public.notify_config where id = 1;
  if not found or coalesce(mail_cfg.webhook_url, '') = '' or coalesce(mail_cfg.secret, '') = '' then
    raise exception 'Configure the Apps Script URL and secret in Admin → Email alerts first.';
  end if;

  resolved_subject := replace(resolved_subject, '{{member_name}}', recipient_name);
  resolved_subject := replace(resolved_subject, '{{role_name}}', role_name);
  resolved_subject := replace(resolved_subject, '{{week_start}}', to_char(current_date, 'FMMonth FMDD, YYYY'));
  resolved_subject := replace(resolved_subject, '{{meeting_date}}', meeting_date_text);
  resolved_body := replace(resolved_body, '{{member_name}}', recipient_name);
  resolved_body := replace(resolved_body, '{{role_name}}', role_name);
  resolved_body := replace(resolved_body, '{{week_start}}', to_char(current_date, 'FMMonth FMDD, YYYY'));
  resolved_body := replace(resolved_body, '{{meeting_date}}', meeting_date_text);

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
