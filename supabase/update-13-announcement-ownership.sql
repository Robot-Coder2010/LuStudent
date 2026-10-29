-- Apply after update-12-leadership-role-overrides-and-photo-alerts.sql.
-- Lets Student Leadership members edit and delete only announcements they created.

alter table public.announcements
  add column if not exists created_by uuid references auth.users(id) on delete set null;

create table if not exists public.announcement_media_owners (
  path text primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  announcement_id uuid not null,
  created_at timestamptz not null default now()
);
alter table public.announcement_media_owners enable row level security;
revoke all on public.announcement_media_owners from public, anon, authenticated;

create or replace function public.can_delete_announcement_media(p_path text)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select public.is_leader() and exists (
    select 1 from public.announcement_media_owners
     where path = p_path and owner_id = auth.uid()
  )
$$;
revoke all on function public.can_delete_announcement_media(text) from public, anon;
grant execute on function public.can_delete_announcement_media(text) to authenticated;

create or replace function public.track_announcement_owner()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := auth.uid();
    if new.pdf_path is not null then
      insert into public.announcement_media_owners (path, owner_id, announcement_id)
      values (new.pdf_path, new.created_by, new.id)
      on conflict (path) do nothing;
    end if;
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if not public.is_admin() then
      if not public.is_leader() or old.created_by is distinct from auth.uid() then
        raise exception 'You can only edit announcements you created.';
      end if;
    end if;
    new.created_by := old.created_by;

    if old.pdf_path is distinct from new.pdf_path then
      if old.pdf_path is not null and old.created_by is not null then
        insert into public.announcement_media_owners (path, owner_id, announcement_id)
        values (old.pdf_path, old.created_by, old.id)
        on conflict (path) do nothing;
      end if;
      if new.pdf_path is not null and new.created_by is not null then
        insert into public.announcement_media_owners (path, owner_id, announcement_id)
        values (new.pdf_path, new.created_by, new.id)
        on conflict (path) do nothing;
      end if;
    end if;
    return new;
  end if;

  if not public.is_admin()
     and (not public.is_leader() or old.created_by is distinct from auth.uid()) then
    raise exception 'You can only delete announcements you created.';
  end if;
  if old.pdf_path is not null and old.created_by is not null then
    insert into public.announcement_media_owners (path, owner_id, announcement_id)
    values (old.pdf_path, old.created_by, old.id)
    on conflict (path) do nothing;
  end if;
  return old;
end $$;

drop trigger if exists announcements_owner_tracking on public.announcements;
create trigger announcements_owner_tracking
before insert or update or delete on public.announcements
for each row execute function public.track_announcement_owner();

drop policy if exists "announcements leader edit own" on public.announcements;
create policy "announcements leader edit own" on public.announcements
  for update to authenticated
  using (public.is_leader() and created_by = auth.uid())
  with check (public.is_leader() and created_by = auth.uid());
drop policy if exists "announcements leader delete own" on public.announcements;
create policy "announcements leader delete own" on public.announcements
  for delete to authenticated
  using (public.is_leader() and created_by = auth.uid());

drop policy if exists "media leader delete own announcement files" on storage.objects;
create policy "media leader delete own announcement files" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'media'
    and public.is_leader()
    and (
      public.can_delete_announcement_media(name)
      or name like (auth.uid()::text || '/%')
    )
  );

notify pgrst, 'reload schema';
