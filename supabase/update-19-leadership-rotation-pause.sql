-- Apply after update-18-role-specific-email-templates.sql.
-- Allows admins to pause SL role rotation until the Thursday before a meeting.

alter table public.leadership_hub_settings
  add column if not exists rotation_paused boolean not null default false,
  add column if not exists rotation_pause_reason text,
  add column if not exists next_meeting_date date;

alter table public.leadership_hub_settings
  drop constraint if exists leadership_hub_settings_rotation_pause_details_check;
alter table public.leadership_hub_settings
  add constraint leadership_hub_settings_rotation_pause_details_check
  check (
    not rotation_paused
    or (
      next_meeting_date is not null
      and length(trim(coalesce(rotation_pause_reason, ''))) between 1 and 500
    )
  );

create or replace function public.leadership_rotation_week_start(p_date date, p_weekday int)
returns date language sql immutable strict as $$
  select p_date - mod(extract(dow from p_date)::int - p_weekday + 7, 7)
$$;
revoke all on function public.leadership_rotation_week_start(date, int) from public, anon, authenticated;

create or replace function public.leadership_rotation_week_is_editable(p_week_start date)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  settings public.leadership_hub_settings;
  today_eastern date := (now() at time zone 'America/New_York')::date;
  resume_date date;
  current_week_start date;
  meeting_week_start date;
begin
  select * into settings from public.leadership_hub_settings where id = 1;
  if not found then return false; end if;

  current_week_start := public.leadership_rotation_week_start(
    (now() at time zone 'UTC')::date, settings.rotation_weekday
  );
  if p_week_start = current_week_start then return true; end if;
  if not settings.rotation_paused or settings.next_meeting_date is null then return false; end if;

  resume_date := settings.next_meeting_date
    - coalesce(nullif(mod(extract(dow from settings.next_meeting_date)::int - 4 + 7, 7), 0), 7);
  meeting_week_start := public.leadership_rotation_week_start(
    settings.next_meeting_date, settings.rotation_weekday
  );
  return today_eastern >= resume_date
    and today_eastern <= settings.next_meeting_date
    and p_week_start = meeting_week_start;
end $$;
revoke all on function public.leadership_rotation_week_is_editable(date) from public, anon, authenticated;

create or replace function public.request_leadership_rotation_skip(p_week_start date, p_reason text)
returns uuid language plpgsql security definer set search_path = public, auth as $$
declare
  caller uuid := auth.uid();
  caller_email text := lower(coalesce(auth.jwt()->>'email', ''));
  request_id uuid;
begin
  if caller is null or not public.can_view_leadership_hub()
     or (not public.is_admin() and not public.is_leader()) then
    raise exception 'Student Leadership access is required.';
  end if;
  if length(trim(coalesce(p_reason, ''))) not between 1 and 500 then
    raise exception 'Please provide a reason of 1 to 500 characters.';
  end if;
  if not public.leadership_rotation_week_is_editable(p_week_start) then
    raise exception 'Requests can only be made for the current rotation week or the upcoming paused rotation.';
  end if;
  if not exists (
    select 1 from public.leadership_chart_members member
    join public.leadership_member_roles assignment on assignment.member_email = member.email
    where lower(member.email) = caller_email and member.in_cycle
  ) then
    raise exception 'You are not currently eligible for the Student Leadership rotation.';
  end if;
  insert into public.leadership_rotation_skip_requests (week_start, member_email, requested_by, reason)
  values (p_week_start, caller_email, caller, trim(p_reason))
  returning id into request_id;
  return request_id;
exception
  when unique_violation then
    raise exception 'A rotation request already exists for you this week.';
end $$;
revoke all on function public.request_leadership_rotation_skip(date, text) from public, anon;
grant execute on function public.request_leadership_rotation_skip(date, text) to authenticated;

create or replace function public.set_leadership_rotation_exclusion(
  p_week_start date,
  p_member_email text,
  p_excluded boolean
)
returns void language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if not public.leadership_rotation_week_is_editable(p_week_start) then
    raise exception 'This action only applies to the current rotation week or the upcoming paused rotation.';
  end if;
  if not exists (
    select 1 from public.leadership_chart_members
     where lower(email) = lower(trim(p_member_email))
  ) then
    raise exception 'That person is not on the Student Leadership chart.';
  end if;
  if p_excluded then
    insert into public.leadership_rotation_exclusions (week_start, member_email, created_by)
    values (p_week_start, lower(trim(p_member_email)), auth.uid())
    on conflict (week_start, member_email) do nothing;
  else
    delete from public.leadership_rotation_exclusions
     where week_start = p_week_start and member_email = lower(trim(p_member_email));
  end if;
end $$;
revoke all on function public.set_leadership_rotation_exclusion(date, text, boolean) from public, anon;
grant execute on function public.set_leadership_rotation_exclusion(date, text, boolean) to authenticated;

create or replace function public.set_leadership_role_override(
  p_week_start date,
  p_role_id uuid,
  p_member_email text
)
returns void
language plpgsql security definer set search_path = public, auth as $$
declare
  normalized_email text := lower(trim(coalesce(p_member_email, '')));
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if not public.leadership_rotation_week_is_editable(p_week_start) then
    raise exception 'Manual role assignments only apply to the current rotation week or the upcoming paused rotation.';
  end if;
  if not exists (select 1 from public.leadership_chart_roles where id = p_role_id) then
    raise exception 'That Student Leadership role no longer exists.';
  end if;

  if normalized_email = '' then
    delete from public.leadership_role_overrides
     where week_start = p_week_start and role_id = p_role_id;
    return;
  end if;
  if not exists (select 1 from public.leadership_chart_members where email = normalized_email) then
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
    resolved_body := replace(resolved_body, '{{member_name}}', delivery.member_name);
    resolved_body := replace(resolved_body, '{{role_name}}', delivery.role_name);
    resolved_body := replace(resolved_body, '{{week_start}}', to_char(delivery.week_start, 'FMMonth FMDD, YYYY'));

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

notify pgrst, 'reload schema';
