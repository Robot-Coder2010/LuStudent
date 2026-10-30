-- Apply after update-16-photo-email-templates.sql.
-- Adds configurable weekly Student Leadership assignment and follow-up emails.

create table if not exists public.leadership_role_email_settings (
  id int primary key default 1 check (id = 1),
  enabled boolean not null default true,
  initial_day int check (initial_day between 0 and 6),
  initial_time time not null default '08:30',
  initial_subject text not null default 'Your Student Leadership roles for this week',
  initial_body text not null default E'Hi {{member_name}},\n\nYour Student Leadership role{{role_count}} for the week of {{week_start}}:\n\n{{roles}}\n\nThank you for serving!',
  followup_enabled boolean not null default true,
  followup_day int not null default 2 check (followup_day between 0 and 6),
  followup_time time not null default '08:30',
  followup_subject text not null default 'A reminder about your Student Leadership roles',
  followup_body text not null default E'Hi {{member_name}},\n\nThis is a reminder of your Student Leadership role{{role_count}} for the week of {{week_start}}:\n\n{{roles}}\n\nThank you for serving!',
  updated_at timestamptz not null default now(),
  check (length(trim(initial_subject)) between 1 and 200),
  check (length(trim(initial_body)) between 1 and 10000),
  check (length(trim(followup_subject)) between 1 and 200),
  check (length(trim(followup_body)) between 1 and 10000)
);

insert into public.leadership_role_email_settings (id)
values (1) on conflict (id) do nothing;

alter table public.leadership_role_email_settings enable row level security;
drop policy if exists "leadership role email settings admin" on public.leadership_role_email_settings;
create policy "leadership role email settings admin" on public.leadership_role_email_settings
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());
grant select, insert, update on public.leadership_role_email_settings to authenticated;

create table if not exists public.leadership_role_email_deliveries (
  id bigint generated always as identity primary key,
  week_start date not null,
  delivery_type text not null check (delivery_type in ('initial', 'followup')),
  member_email text not null,
  member_name text not null,
  roles text[] not null,
  scheduled_for timestamptz not null,
  status text not null default 'pending'
    check (status in ('pending', 'sending', 'sent', 'failed', 'cancelled')),
  request_id bigint,
  attempts int not null default 0,
  next_attempt_at timestamptz not null default now(),
  requested_at timestamptz,
  sent_at timestamptz,
  last_error text,
  unique (week_start, delivery_type, member_email)
);
create index if not exists leadership_role_email_deliveries_queue
  on public.leadership_role_email_deliveries (status, scheduled_for, next_attempt_at);
alter table public.leadership_role_email_deliveries enable row level security;

create or replace function public.leadership_role_email_assignments(p_week_start date)
returns table (assigned_email text, assigned_name text, assigned_roles text[])
language plpgsql stable security definer set search_path = public as $$
declare
  rotation_day int;
  first_rotation date;
  week_index int;
  role_position int := 0;
  role_row record;
  pinned_email text;
  candidates text[];
  candidate_names text[];
  candidate_count int;
  start_index int;
  candidate_index int;
  candidate_offset int;
  chosen_email text;
  chosen_name text;
  result_emails text[] := '{}'::text[];
  result_names text[] := '{}'::text[];
  result_roles jsonb[] := '{}'::jsonb[];
  result_index int;
  output_index int;
begin
  select rotation_weekday into rotation_day
    from public.leadership_hub_settings where id = 1;
  if rotation_day is null then raise exception 'Student Leadership rotation settings are missing.'; end if;

  first_rotation := date '2024-01-07' + rotation_day;
  week_index := case when p_week_start < first_rotation then 0
    else floor((p_week_start - first_rotation)::numeric / 7)::int end;

  for role_row in
    select id, name from public.leadership_chart_roles order by sort_order, name
  loop
    role_position := role_position + 1;
    chosen_email := null;
    chosen_name := null;
    select lower(member_email) into pinned_email
      from public.leadership_role_overrides
     where week_start = p_week_start and role_id = role_row.id;
    if pinned_email is not null then
      select lower(email), display_name into chosen_email, chosen_name
        from public.leadership_chart_members
       where lower(email) = pinned_email;
    end if;

    if chosen_email is null then
      select array_agg(lower(member.email) order by member.sort_order, member.display_name),
             array_agg(member.display_name order by member.sort_order, member.display_name)
        into candidates, candidate_names
        from public.leadership_chart_members member
        join public.leadership_member_roles assignment on assignment.member_email = member.email
       where member.in_cycle
         and assignment.role_id = role_row.id
         and not exists (
           select 1 from public.leadership_rotation_exclusions exclusion
            where exclusion.week_start = p_week_start
              and lower(exclusion.member_email) = lower(member.email)
         );
      candidate_count := coalesce(cardinality(candidates), 0);
      if candidate_count = 0 then continue; end if;
      start_index := mod(week_index + role_position - 1, candidate_count) + 1;
      for candidate_offset in 0..candidate_count - 1 loop
        candidate_index := mod(start_index - 1 + candidate_offset, candidate_count) + 1;
        if not (candidates[candidate_index] = any(result_emails)) then
          chosen_email := candidates[candidate_index];
          chosen_name := candidate_names[candidate_index];
          exit;
        end if;
      end loop;
      if chosen_email is null then
        chosen_email := candidates[start_index];
        chosen_name := candidate_names[start_index];
      end if;
    end if;

    result_index := array_position(result_emails, chosen_email);
    if result_index is null then
      result_emails := array_append(result_emails, chosen_email);
      result_names := array_append(result_names, chosen_name);
      result_roles := array_append(result_roles, jsonb_build_array(role_row.name));
    else
      result_roles[result_index] := result_roles[result_index] || jsonb_build_array(role_row.name);
    end if;
  end loop;

  for output_index in 1..coalesce(cardinality(result_emails), 0) loop
    assigned_email := result_emails[output_index];
    assigned_name := result_names[output_index];
    select array_agg(role_name) into assigned_roles
      from jsonb_array_elements_text(result_roles[output_index]) as role_names(role_name);
    return next;
  end loop;
end $$;
revoke all on function public.leadership_role_email_assignments(date) from public, anon, authenticated;

create or replace function public.process_leadership_role_emails()
returns void
language plpgsql security definer set search_path = public, net as $$
declare
  cfg public.leadership_role_email_settings;
  mail_cfg public.notify_config;
  rotation_day int;
  send_day int;
  local_now timestamp;
  local_date date;
  rotation_week_start date;
  target_week_start date;
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
  role_list text;
  member_role_word text;
begin
  select * into cfg from public.leadership_role_email_settings where id = 1;
  if not found then return; end if;
  select rotation_weekday into rotation_day
    from public.leadership_hub_settings where id = 1;
  if cfg.enabled and rotation_day is not null then
    select * into mail_cfg from public.notify_config where id = 1;
    if found and coalesce(mail_cfg.webhook_url, '') <> '' and coalesce(mail_cfg.secret, '') <> '' then
      local_now := now() at time zone 'America/New_York';
      local_date := local_now::date;
      send_day := coalesce(cfg.initial_day, rotation_day);

      if extract(dow from local_now)::int = send_day
         and local_now::time >= cfg.initial_time then
        rotation_week_start := (now() at time zone 'UTC')::date
          - mod(extract(dow from (now() at time zone 'UTC'))::int - rotation_day + 7, 7);
        target_week_start := rotation_week_start
          + case when send_day < rotation_day then 7 else 0 end;
        initial_at := (local_date + cfg.initial_time) at time zone 'America/New_York';
        followup_offset := mod(cfg.followup_day - send_day + 7, 7);
        if followup_offset = 0 then followup_offset := 7; end if;
        followup_at := (local_date + followup_offset + cfg.followup_time) at time zone 'America/New_York';

        for assignment in
          select * from public.leadership_role_email_assignments(target_week_start)
        loop
          insert into public.leadership_role_email_deliveries
            (week_start, delivery_type, member_email, member_name, roles, scheduled_for)
          values
            (target_week_start, 'initial', assignment.assigned_email, assignment.assigned_name,
             assignment.assigned_roles, initial_at)
          on conflict (week_start, delivery_type, member_email) do nothing;

          insert into public.leadership_role_email_deliveries
            (week_start, delivery_type, member_email, member_name, roles, scheduled_for)
          values
            (target_week_start, 'followup', assignment.assigned_email, assignment.assigned_name,
             assignment.assigned_roles, followup_at)
          on conflict (week_start, delivery_type, member_email) do nothing;
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
    role_list := array_to_string(array(
      select '• ' || role_names.role_name from unnest(delivery.roles) as role_names(role_name)
    ), E'\n');
    member_role_word := case when cardinality(delivery.roles) = 1 then '' else 's' end;
    if delivery.delivery_type = 'initial' then
      resolved_subject := cfg.initial_subject;
      resolved_body := cfg.initial_body;
    else
      resolved_subject := cfg.followup_subject;
      resolved_body := cfg.followup_body;
    end if;
    resolved_subject := replace(resolved_subject, '{{member_name}}', delivery.member_name);
    resolved_subject := replace(resolved_subject, '{{roles}}', role_list);
    resolved_subject := replace(resolved_subject, '{{role_count}}', member_role_word);
    resolved_subject := replace(resolved_subject, '{{week_start}}', to_char(delivery.week_start, 'FMMonth FMDD, YYYY'));
    resolved_body := replace(resolved_body, '{{member_name}}', delivery.member_name);
    resolved_body := replace(resolved_body, '{{roles}}', role_list);
    resolved_body := replace(resolved_body, '{{role_count}}', member_role_word);
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

select cron.schedule(
  'process-leadership-role-emails',
  '*/5 * * * *',
  'select public.process_leadership_role_emails()'
);

notify pgrst, 'reload schema';
