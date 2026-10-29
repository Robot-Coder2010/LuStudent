-- Apply after update-13-announcement-ownership.sql.
-- Adds admin-awarded bonus points to the Student Leadership prize balance.

create table if not exists public.leadership_bonus_points (
  id uuid primary key default gen_random_uuid(),
  member_email text not null,
  points int not null check (points between 1 and 10000),
  reason text not null check (length(trim(reason)) between 1 and 300),
  granted_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists leadership_bonus_points_member
  on public.leadership_bonus_points (member_email, created_at desc);
alter table public.leadership_bonus_points enable row level security;
drop policy if exists "leadership bonus points read" on public.leadership_bonus_points;
create policy "leadership bonus points read" on public.leadership_bonus_points
  for select to authenticated
  using (public.is_admin() or lower(member_email) = lower(coalesce(auth.jwt()->>'email', '')));
grant select on public.leadership_bonus_points to authenticated;

create or replace function public.grant_leadership_bonus_points(
  p_member_email text,
  p_points int,
  p_reason text
)
returns uuid
language plpgsql security definer set search_path = public, auth as $$
declare
  normalized_email text := lower(trim(coalesce(p_member_email, '')));
  bonus_id uuid;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if normalized_email !~ '^[^@]+@latterup[.]org$' then
    raise exception 'Use a valid @latterup.org Student Leadership email.';
  end if;
  if not exists (select 1 from public.leadership where lower(email) = normalized_email) then
    raise exception 'That email is not on the Student Leadership roster.';
  end if;
  if p_points is null or p_points not between 1 and 10000 then
    raise exception 'Bonus points must be a whole number from 1 to 10000.';
  end if;
  if length(trim(coalesce(p_reason, ''))) not between 1 and 300 then
    raise exception 'Enter a reason of 1 to 300 characters.';
  end if;

  insert into public.leadership_bonus_points (member_email, points, reason, granted_by)
  values (normalized_email, p_points, trim(p_reason), auth.uid())
  returning id into bonus_id;
  return bonus_id;
end $$;
revoke all on function public.grant_leadership_bonus_points(text, int, text) from public, anon;
grant execute on function public.grant_leadership_bonus_points(text, int, text) to authenticated;

create or replace function public.claim_leadership_prize(p_prize_id uuid)
returns uuid language plpgsql security definer set search_path = public, auth as $$
declare
  caller uuid := auth.uid();
  caller_email text := lower(coalesce(auth.jwt()->>'email', ''));
  prize public.leadership_prizes;
  earned bigint;
  reserved bigint;
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
  earned := earned + coalesce((
    select sum(points) from public.leadership_bonus_points
     where lower(member_email) = caller_email
  ), 0);
  select coalesce(sum(points_cost), 0) into reserved
    from public.leadership_prize_claims where user_id = caller and status in ('pending', 'approved');
  if earned - reserved < prize.points_cost then raise exception 'You do not have enough available points for this prize.'; end if;
  insert into public.leadership_prize_claims (user_id, prize_id, prize_name, points_cost)
  values (caller, prize.id, prize.name, prize.points_cost)
  returning id into claim_id;
  return claim_id;
end $$;
grant execute on function public.claim_leadership_prize(uuid) to authenticated;

notify pgrst, 'reload schema';
