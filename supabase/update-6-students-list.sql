-- Run once in the Supabase SQL Editor (paste the code itself, not the file name).
-- Lets admins (only) see the list of everyone with a login, for Admin -> Students.
create or replace function public.list_students()
returns table (email text, full_name text, created_at timestamptz, last_sign_in_at timestamptz,
               must_change_password boolean, admin_role boolean, leader_role boolean)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  return query
    select u.email::text,
           coalesce(u.raw_app_meta_data->>'full_name', '')::text,
           u.created_at,
           u.last_sign_in_at,
           coalesce((u.raw_user_meta_data->>'must_change_password')::boolean, false),
           exists (select 1 from public.admins a where lower(a.email) = lower(u.email)),
           exists (select 1 from public.leadership l where lower(l.email) = lower(u.email))
      from auth.users u
     order by lower(u.email);
end $$;
revoke all on function public.list_students() from public, anon;
grant execute on function public.list_students() to authenticated;
