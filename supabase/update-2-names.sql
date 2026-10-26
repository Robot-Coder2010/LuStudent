-- Run once in the SQL editor. Makes the name shown on photos come from a field
-- that students cannot edit themselves (app_metadata, set by the import script).
create or replace function public.submissions_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare cap int;
begin
  if not public.is_admin() then
    new.user_id := auth.uid();
    new.status := 'pending';
    new.submitted_by := coalesce(
      nullif(auth.jwt()->'app_metadata'->>'full_name',''),
      split_part(auth.jwt()->>'email','@',1));
    select max_photos_per_theme into cap from public.settings where id = 1;
    if (select count(*) from public.submissions
          where theme_id = new.theme_id and user_id = new.user_id) >= cap then
      raise exception 'You can submit up to % photos per theme.', cap;
    end if;
  end if;
  return new;
end $$;
