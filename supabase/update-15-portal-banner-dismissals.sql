-- Apply after update-14-leadership-bonus-points.sql.
-- Stores one-day banner dismissals per signed-in profile.

create table if not exists public.portal_banner_dismissals (
  user_id uuid primary key references auth.users(id) on delete cascade,
  fingerprint text not null,
  dismissed_until timestamptz not null
);

alter table public.portal_banner_dismissals enable row level security;

drop policy if exists "portal banner dismissals own profile" on public.portal_banner_dismissals;
create policy "portal banner dismissals own profile" on public.portal_banner_dismissals
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

grant select, insert, update on public.portal_banner_dismissals to authenticated;

notify pgrst, 'reload schema';
