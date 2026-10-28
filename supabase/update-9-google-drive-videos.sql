-- Add Google Drive video embeds for existing projects.
alter table public.videos
  add column if not exists google_drive_id text;

alter table public.videos drop constraint if exists videos_check;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.videos'::regclass and conname = 'videos_video_source_required'
  ) then
    alter table public.videos add constraint videos_video_source_required
      check (youtube_id is not null or google_drive_id is not null or video_path is not null) not valid;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.videos'::regclass and conname = 'videos_google_drive_id_format'
  ) then
    alter table public.videos add constraint videos_google_drive_id_format
      check (google_drive_id is null or google_drive_id ~ '^[A-Za-z0-9_-]{10,}$') not valid;
  end if;
end $$;

notify pgrst, 'reload schema';
