# Latter UP Student Portal
Static site (Netlify) + Supabase (login, database, file storage).
Content is edited at `/admin.html` — no code changes needed. For a new database, run `supabase/setup.sql`, then `supabase/update-2-names.sql`, `supabase/update-4-portal-customization.sql`, `supabase/update-5a-leadership-team.sql`, `supabase/update-5b-email-alerts.sql`, `supabase/update-6-students-list.sql`, `supabase/update-7-bug-fixes.sql`, `supabase/update-8-security-and-data-fixes.sql`, and `supabase/update-9-google-drive-videos.sql` in order. Existing databases should apply any missing updates in order. The latest updates add scheduled publishing rules, public portal settings, Google Drive video embeds, and other RLS fixes.

For an existing database that already ran `setup.sql`, you can run `supabase/existing-project-all-updates.sql` once instead of running the individual update scripts. It combines updates 2 and 4 through 9 in order, and is not for a new project. Before running it, deploy the `change-own-password` Edge Function as described below. The bundle does not deploy Edge Functions or change Supabase Auth settings.

Before applying `supabase/update-8-security-and-data-fixes.sql`, deploy the `change-own-password` Edge Function from `supabase/functions/`. Update 8 migrates forced-password-change flags into protected app metadata; flagged users cannot access the site until that function is deployed and available. If update 8 was run before deploying the function, restore access with:

```sql
update auth.users
   set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) - 'must_change_password'
 where lower(coalesce(raw_app_meta_data->>'must_change_password', 'false')) = 'true';
```

Deploy both Supabase Edge Functions in `supabase/functions/`: `import-students` and `change-own-password`. For the public photo page, Supabase must allow new accounts and **Anonymous Sign-Ins** must be enabled; Supabase treats anonymous visitors as new auth users, so disabling sign-ups globally also blocks visitor sessions. The database trigger restricts email/password accounts to `@latterup.org` addresses, and email confirmations should remain enabled to prevent unverified email accounts from signing in. The photo page uses a persistent anonymous session and the photo cap is per visitor session. CAPTCHA is not currently wired into the page; do not enable Supabase CAPTCHA for anonymous sign-ins unless a CAPTCHA token flow has also been added. If you do not want anonymous visitor accounts, keep the public photo page disabled and leave anonymous sign-ins off.

Update 8 adds the `videos_youtube_id_format` constraint as `NOT VALID` so old invalid rows don't block the migration. Before validating it, find and correct or remove any existing invalid IDs:

```sql
select id, youtube_id from public.videos
 where youtube_id is not null and youtube_id !~ '^[A-Za-z0-9_-]{11}$';
alter table public.videos validate constraint videos_youtube_id_format;
```

Student accounts are created from Admin → Import students. The random starting-password option is selected by default; it is safer than sharing one password across many accounts. The first-password-change flag is stored in protected app metadata and enforced by database access policies, then cleared by the `change-own-password` Edge Function.
Only edit config.js if the Supabase project changes (anon key is public by design; never use the service_role key).

For local testing, serve the folder over HTTP instead of opening `index.html` directly from disk. From the project folder in PowerShell, run `py -m http.server 8000` (or `python -m http.server 8000`), then visit `http://localhost:8000`. Browsers do not reliably share authentication storage between pages opened with `file://`.

On `localhost` or `127.0.0.1`, open the profile menu and choose **Use local preview** to show sample announcements, video thumbnails, photo galleries, and the read-only admin preview. Choose **Exit local preview** to return to the normal signed-out or signed-in site view. Preview mode and its admin screen use sample data only and never grant Supabase permissions or write to Supabase. Sample files are kept in `PLACEHOLDER/`. The Netlify build in `netlify-build.cjs` excludes that folder and removes the preview loader tags from deployed HTML. Netlify publishes the generated `dist/` folder; don't override the publish directory if deploying from the repository. The regular site does not depend on any files in `PLACEHOLDER/`.


Portal customization: run `supabase/update-4-portal-customization.sql` in Supabase SQL Editor (safe to rerun). It adds the `portal_banner`, `portal_tiles`, and `portal_home_sections` columns and refreshes the Supabase schema cache. Then deploy the site files and open Admin → Portal Layout to edit the announcement banner and tiles, or Admin → Home page editor to show, hide, and reorder home page sections. The home page tile grid requires `portal-card-grid` in `index.html`, which is included in this version. These settings are stored in Supabase and persist when website source files are replaced.
