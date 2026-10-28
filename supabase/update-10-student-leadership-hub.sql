-- Apply after the existing Supabase setup and updates.
-- Adds the Student Leadership hub, private chat reports, points and prize claims.

create table if not exists public.leadership_hub_settings (
  id int primary key default 1 check (id = 1),
  rotation_weekday int not null default 1 check (rotation_weekday between 0 and 6),
  approval_points int not null default 1 check (approval_points between 0 and 10000),
  visibility text not null default 'leaders_admins' check (visibility in ('off', 'admins', 'leaders_admins'))
);
alter table public.leadership_hub_settings
  add column if not exists visibility text not null default 'leaders_admins';
alter table public.leadership_hub_settings
  drop constraint if exists leadership_hub_settings_visibility_check;
alter table public.leadership_hub_settings
  add constraint leadership_hub_settings_visibility_check check (visibility in ('off', 'admins', 'leaders_admins'));
insert into public.leadership_hub_settings (id) values (1) on conflict (id) do nothing;

create table if not exists public.leadership_chart_members (
  email text primary key references public.leadership(email) on delete cascade,
  display_name text not null,
  in_cycle boolean not null default true,
  sort_order int not null default 0
);

insert into public.leadership_chart_members (email, display_name, sort_order)
select l.email, initcap(replace(split_part(l.email, '@', 1), '.', ' ')),
       row_number() over (order by l.email)
  from public.leadership l
on conflict (email) do nothing;

create table if not exists public.leadership_chart_roles (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (length(trim(name)) between 1 and 80),
  sort_order int not null default 0
);
insert into public.leadership_chart_roles (name, sort_order) values
  ('Opening Prayer', 1),
  ('Spiritual Thought', 2),
  ('Do you know them?', 3),
  ('Closing Prayer', 4)
on conflict (name) do update set sort_order = excluded.sort_order;

create table if not exists public.leadership_member_roles (
  member_email text not null references public.leadership_chart_members(email) on delete cascade,
  role_id uuid not null references public.leadership_chart_roles(id) on delete cascade,
  primary key (member_email, role_id)
);

create or replace function public.sync_leadership_chart_member()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    delete from public.leadership_chart_members where email = old.email;
    return old;
  end if;
  insert into public.leadership_chart_members (email, display_name)
  values (new.email, initcap(replace(split_part(new.email, '@', 1), '.', ' ')))
  on conflict (email) do nothing;
  insert into public.leadership_member_roles (member_email, role_id)
  select new.email, id from public.leadership_chart_roles
  where name in ('Opening Prayer', 'Spiritual Thought', 'Do you know them?', 'Closing Prayer')
  on conflict (member_email, role_id) do nothing;
  return new;
end $$;

drop trigger if exists leadership_chart_member_sync on public.leadership;
create trigger leadership_chart_member_sync
after insert or delete on public.leadership
for each row execute function public.sync_leadership_chart_member();

insert into public.leadership_member_roles (member_email, role_id)
select members.email, roles.id
  from public.leadership_chart_members members
  cross join public.leadership_chart_roles roles
 where roles.name in ('Opening Prayer', 'Spiritual Thought', 'Do you know them?', 'Closing Prayer')
on conflict (member_email, role_id) do nothing;

create table if not exists public.leadership_chat_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references auth.users(id) on delete cascade,
  reporter_email text not null,
  chatted_with text not null check (length(trim(chatted_with)) between 1 and 120),
  screenshot_path text not null unique,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  points_awarded int not null default 0 check (points_awarded >= 0),
  created_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  check ((status = 'approved' and reviewed_at is not null) or status <> 'approved')
);
create index if not exists leadership_chat_reports_queue on public.leadership_chat_reports (status, created_at);
create index if not exists leadership_chat_reports_reporter on public.leadership_chat_reports (reporter_id, status);

create or replace function public.set_leadership_reporter_email()
returns trigger language plpgsql security definer set search_path = public, auth as $$
begin
  select lower(email) into new.reporter_email from auth.users where id = new.reporter_id;
  if new.reporter_email is null then raise exception 'Could not verify the report author.'; end if;
  return new;
end $$;
drop trigger if exists leadership_reporter_email on public.leadership_chat_reports;
create trigger leadership_reporter_email
before insert on public.leadership_chat_reports
for each row execute function public.set_leadership_reporter_email();

create table if not exists public.leadership_prizes (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 120),
  description text not null default '',
  points_cost int not null check (points_cost between 1 and 100000),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.leadership_prize_claims (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  user_email text not null,
  prize_id uuid references public.leadership_prizes(id) on delete set null,
  prize_name text not null,
  points_cost int not null check (points_cost > 0),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  check ((status in ('approved', 'rejected') and reviewed_at is not null) or status = 'pending')
);
create index if not exists leadership_prize_claims_queue on public.leadership_prize_claims (status, created_at);
create index if not exists leadership_prize_claims_user on public.leadership_prize_claims (user_id, status);

create or replace function public.set_leadership_claim_user_email()
returns trigger language plpgsql security definer set search_path = public, auth as $$
begin
  select lower(email) into new.user_email from auth.users where id = new.user_id;
  if new.user_email is null then raise exception 'Could not verify the prize-claim author.'; end if;
  return new;
end $$;
drop trigger if exists leadership_claim_user_email on public.leadership_prize_claims;
create trigger leadership_claim_user_email
before insert on public.leadership_prize_claims
for each row execute function public.set_leadership_claim_user_email();

create or replace function public.can_view_leadership_hub()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select case coalesce((select visibility from public.leadership_hub_settings where id = 1), 'leaders_admins')
    when 'admins' then public.is_admin()
    when 'leaders_admins' then public.is_admin() or public.is_leader()
    else false
  end
$$;
grant execute on function public.can_view_leadership_hub() to authenticated;

alter table public.leadership_hub_settings enable row level security;
alter table public.leadership_chart_members enable row level security;
alter table public.leadership_chart_roles enable row level security;
alter table public.leadership_member_roles enable row level security;
alter table public.leadership_chat_reports enable row level security;
alter table public.leadership_prizes enable row level security;
alter table public.leadership_prize_claims enable row level security;

drop policy if exists "leadership hub settings read" on public.leadership_hub_settings;
create policy "leadership hub settings read" on public.leadership_hub_settings
  for select to authenticated using (public.is_leader() or public.is_admin());
drop policy if exists "leadership hub settings admin" on public.leadership_hub_settings;
create policy "leadership hub settings admin" on public.leadership_hub_settings
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "leadership chart members read" on public.leadership_chart_members;
create policy "leadership chart members read" on public.leadership_chart_members
  for select to authenticated using (public.is_admin() or public.can_view_leadership_hub());
drop policy if exists "leadership chart members admin" on public.leadership_chart_members;
create policy "leadership chart members admin" on public.leadership_chart_members
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "leadership chart roles read" on public.leadership_chart_roles;
create policy "leadership chart roles read" on public.leadership_chart_roles
  for select to authenticated using (public.is_admin() or public.can_view_leadership_hub());
drop policy if exists "leadership chart roles admin" on public.leadership_chart_roles;
create policy "leadership chart roles admin" on public.leadership_chart_roles
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "leadership member roles read" on public.leadership_member_roles;
create policy "leadership member roles read" on public.leadership_member_roles
  for select to authenticated using (public.is_admin() or public.can_view_leadership_hub());
drop policy if exists "leadership member roles admin" on public.leadership_member_roles;
create policy "leadership member roles admin" on public.leadership_member_roles
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "leadership chat reports insert" on public.leadership_chat_reports;
create policy "leadership chat reports insert" on public.leadership_chat_reports
  for insert to authenticated with check (
    public.can_view_leadership_hub()
    and reporter_id = auth.uid()
    and screenshot_path like (auth.uid()::text || '/%')
    and status = 'pending'
    and points_awarded = 0
    and reviewed_by is null
    and reviewed_at is null
  );
drop policy if exists "leadership chat reports read" on public.leadership_chat_reports;
create policy "leadership chat reports read" on public.leadership_chat_reports
  for select to authenticated using (public.is_admin() or (
    public.can_view_leadership_hub() and reporter_id = auth.uid()
  ));

drop policy if exists "leadership prizes read" on public.leadership_prizes;
create policy "leadership prizes read" on public.leadership_prizes
  for select to authenticated using (public.is_admin() or (public.can_view_leadership_hub() and active));
drop policy if exists "leadership prizes admin" on public.leadership_prizes;
create policy "leadership prizes admin" on public.leadership_prizes
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "leadership prize claims read" on public.leadership_prize_claims;
create policy "leadership prize claims read" on public.leadership_prize_claims
  for select to authenticated using (public.is_admin() or (
    public.can_view_leadership_hub() and user_id = auth.uid()
  ));

grant select, update on public.leadership_hub_settings to authenticated;
grant select, insert, update, delete on public.leadership_chart_members to authenticated;
grant select, insert, update, delete on public.leadership_chart_roles to authenticated;
grant select, insert, delete on public.leadership_member_roles to authenticated;
grant select, insert on public.leadership_chat_reports to authenticated;
grant select, insert, update, delete on public.leadership_prizes to authenticated;
grant select on public.leadership_prize_claims to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('leadership-reports', 'leadership-reports', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 10485760,
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

drop policy if exists "leadership report screenshot upload" on storage.objects;
create policy "leadership report screenshot upload" on storage.objects for insert to authenticated
  with check (
    bucket_id = 'leadership-reports'
    and public.can_view_leadership_hub()
    and (storage.foldername(name))[1] = auth.uid()::text
  );
drop policy if exists "leadership report screenshot read" on storage.objects;
create policy "leadership report screenshot read" on storage.objects for select to authenticated
  using (
    bucket_id = 'leadership-reports'
    and (
      public.is_admin()
      or (public.can_view_leadership_hub() and (storage.foldername(name))[1] = auth.uid()::text)
    )
  );
drop policy if exists "leadership report screenshot admin delete" on storage.objects;
create policy "leadership report screenshot admin delete" on storage.objects for delete to authenticated
  using (bucket_id = 'leadership-reports' and public.is_admin());

create or replace function public.set_leadership_member_roles(p_email text, p_role_ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if not exists (select 1 from public.leadership_chart_members where email = lower(trim(p_email))) then
    raise exception 'That person is not on Student Leadership.';
  end if;
  delete from public.leadership_member_roles where member_email = lower(trim(p_email));
  insert into public.leadership_member_roles (member_email, role_id)
  select lower(trim(p_email)), distinct_roles.role_id
    from (select distinct unnest(coalesce(p_role_ids, '{}'::uuid[])) as role_id) distinct_roles;
end $$;
grant execute on function public.set_leadership_member_roles(text, uuid[]) to authenticated;

create or replace function public.review_leadership_chat_report(p_report_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
declare
  award int;
  changed_id uuid;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if p_decision not in ('approved', 'rejected') then raise exception 'Decision must be approved or rejected.'; end if;
  select approval_points into award from public.leadership_hub_settings where id = 1;
  update public.leadership_chat_reports
     set status = p_decision,
         points_awarded = case when p_decision = 'approved' then coalesce(award, 1) else 0 end,
         reviewed_by = auth.uid(),
         reviewed_at = now()
   where id = p_report_id and status = 'pending'
  returning id into changed_id;
  if changed_id is null then raise exception 'This report is no longer waiting for review.'; end if;
end $$;
grant execute on function public.review_leadership_chat_report(uuid, text) to authenticated;

create or replace function public.claim_leadership_prize(p_prize_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  caller uuid := auth.uid();
  prize public.leadership_prizes;
  earned int;
  reserved int;
  claim_id uuid;
begin
  if caller is null or not public.can_view_leadership_hub() then
    raise exception 'Student Leadership access is disabled or not available for this account.';
  end if;
  perform 1 from auth.users where id = caller for update;
  select * into prize from public.leadership_prizes where id = p_prize_id and active for share;
  if not found then raise exception 'This prize is not available.'; end if;
  select coalesce(sum(points_awarded), 0) into earned
    from public.leadership_chat_reports where reporter_id = caller and status = 'approved';
  select coalesce(sum(points_cost), 0) into reserved
    from public.leadership_prize_claims where user_id = caller and status in ('pending', 'approved');
  if earned - reserved < prize.points_cost then raise exception 'You do not have enough available points for this prize.'; end if;
  insert into public.leadership_prize_claims (user_id, prize_id, prize_name, points_cost)
  values (caller, prize.id, prize.name, prize.points_cost)
  returning id into claim_id;
  return claim_id;
end $$;
grant execute on function public.claim_leadership_prize(uuid) to authenticated;

create or replace function public.review_leadership_prize_claim(p_claim_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
declare
  changed_id uuid;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if p_decision not in ('approved', 'rejected') then raise exception 'Decision must be approved or rejected.'; end if;
  update public.leadership_prize_claims
     set status = p_decision, reviewed_by = auth.uid(), reviewed_at = now()
   where id = p_claim_id and status = 'pending'
  returning id into changed_id;
  if changed_id is null then raise exception 'This prize claim is no longer waiting for review.'; end if;
end $$;
grant execute on function public.review_leadership_prize_claim(uuid, text) to authenticated;

notify pgrst, 'reload schema';
