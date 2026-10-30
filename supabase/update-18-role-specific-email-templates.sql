-- Apply after update-17-leadership-role-emails.sql.
-- Gives each Student Leadership chart role its own initial and follow-up templates.

create table if not exists public.leadership_role_email_templates (
  role_id uuid primary key references public.leadership_chart_roles(id) on delete cascade,
  initial_subject text not null default '{{role_name}} — your Student Leadership assignment',
  initial_body text not null default E'Hi {{member_name}},\n\nYou are assigned to {{role_name}} for the week of {{week_start}}.\n\nThank you for serving!',
  followup_subject text not null default 'Reminder: {{role_name}} this week',
  followup_body text not null default E'Hi {{member_name}},\n\nThis is a reminder that you are assigned to {{role_name}} for the week of {{week_start}}.\n\nThank you for serving!',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (length(trim(initial_subject)) between 1 and 200),
  check (length(trim(initial_body)) between 1 and 10000),
  check (length(trim(followup_subject)) between 1 and 200),
  check (length(trim(followup_body)) between 1 and 10000)
);

alter table public.leadership_role_email_templates enable row level security;
drop policy if exists "leadership role email templates admin" on public.leadership_role_email_templates;
create policy "leadership role email templates admin" on public.leadership_role_email_templates
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());
grant select, insert, update on public.leadership_role_email_templates to authenticated;

insert into public.leadership_role_email_templates
  (role_id, initial_subject, initial_body, followup_subject, followup_body)
select chart_role.id,
       coalesce(nullif(settings.initial_subject, ''), '{{role_name}} — your Student Leadership assignment'),
       replace(replace(coalesce(nullif(settings.initial_body, ''), E'Hi {{member_name}},\n\nYou are assigned to {{role_name}} for the week of {{week_start}}.\n\nThank you for serving!'),
                      '{{roles}}', '{{role_name}}'),
               '{{role_count}}', ''),
       coalesce(nullif(settings.followup_subject, ''), 'Reminder: {{role_name}} this week'),
       replace(replace(coalesce(nullif(settings.followup_body, ''), E'Hi {{member_name}},\n\nThis is a reminder that you are assigned to {{role_name}} for the week of {{week_start}}.\n\nThank you for serving!'),
                      '{{roles}}', '{{role_name}}'),
               '{{role_count}}', '')
  from public.leadership_chart_roles chart_role
  left join public.leadership_role_email_settings settings on settings.id = 1
on conflict (role_id) do nothing;

create or replace function public.create_leadership_role_email_template()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.leadership_role_email_templates (role_id)
  values (new.id)
  on conflict (role_id) do nothing;
  return new;
end $$;
revoke all on function public.create_leadership_role_email_template() from public, anon, authenticated;
drop trigger if exists leadership_role_email_template_create on public.leadership_chart_roles;
create trigger leadership_role_email_template_create
after insert on public.leadership_chart_roles
for each row execute function public.create_leadership_role_email_template();

alter table public.leadership_role_email_deliveries
  add column if not exists role_id uuid references public.leadership_chart_roles(id) on delete set null,
  add column if not exists role_name text;

alter table public.leadership_role_email_deliveries
  drop constraint if exists leadership_role_email_deliveries_week_start_delivery_type_member_email_key;

update public.leadership_role_email_deliveries delivery
   set role_id = chart_role.id,
       role_name = chart_role.name
  from public.leadership_chart_roles chart_role
 where delivery.role_id is null
   and cardinality(delivery.roles) = 1
   and chart_role.name = delivery.roles[1];

update public.leadership_role_email_deliveries
   set role_name = coalesce(role_name, array_to_string(roles, ', '), 'Student Leadership role')
 where role_name is null;

do $$
declare
  delivery record;
  assigned_role_name text;
  assigned_role_id uuid;
  first_role boolean;
begin
  for delivery in
    select * from public.leadership_role_email_deliveries
     where status = 'pending' and cardinality(roles) > 1
  loop
    first_role := true;
    for assigned_role_name in select unnest(delivery.roles)
    loop
      select chart_role.id into assigned_role_id
        from public.leadership_chart_roles chart_role
       where chart_role.name = assigned_role_name;
      if assigned_role_id is null then continue; end if;
      if first_role then
        update public.leadership_role_email_deliveries
           set role_id = assigned_role_id,
               role_name = assigned_role_name,
               roles = array[assigned_role_name]
         where id = delivery.id;
        first_role := false;
      else
        insert into public.leadership_role_email_deliveries
          (week_start, delivery_type, member_email, member_name, roles, role_id, role_name,
           scheduled_for, status, attempts, next_attempt_at)
        values
          (delivery.week_start, delivery.delivery_type, delivery.member_email, delivery.member_name,
           array[assigned_role_name], assigned_role_id, assigned_role_name, delivery.scheduled_for, 'pending',
           0, now())
        on conflict do nothing;
      end if;
    end loop;
  end loop;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.leadership_role_email_deliveries'::regclass
       and conname = 'leadership_role_email_deliveries_week_type_member_role_key'
  ) then
    alter table public.leadership_role_email_deliveries
      add constraint leadership_role_email_deliveries_week_type_member_role_key
      unique (week_start, delivery_type, member_email, role_id);
  end if;
end $$;

create or replace function public.process_leadership_role_emails()
returns void
language plpgsql security definer set search_path = public, net as $$
declare
  cfg public.leadership_role_email_settings;
  mail_cfg public.notify_config;
  role_template public.leadership_role_email_templates;
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
  assigned_role_name text;
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
