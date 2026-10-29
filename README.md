# Latter UP Student Portal
Static site (Netlify) + Supabase (login, database, file storage).
Content is edited at `/admin.html` — no code changes needed. For a new database, run `supabase/setup.sql`, then `supabase/update-2-names.sql`, `supabase/update-4-portal-customization.sql`, `supabase/update-5a-leadership-team.sql`, `supabase/update-5b-email-alerts.sql`, `supabase/update-6-students-list.sql`, `supabase/update-7-bug-fixes.sql`, `supabase/update-8-security-and-data-fixes.sql`, `supabase/update-9-google-drive-videos.sql`, `supabase/update-10-student-leadership-hub.sql`, `supabase/update-11-email-alert-diagnostics.sql`, `supabase/update-12-leadership-role-overrides-and-photo-alerts.sql`, `supabase/update-13-announcement-ownership.sql`, and `supabase/update-14-leadership-bonus-points.sql` in order. Existing databases should apply any missing updates in order. The latest updates add scheduled publishing rules, public portal settings, Google Drive video embeds, the Student Leadership hub, and other RLS fixes.

The sign-in page uses Google OAuth. To enable Google sign-in, create a Google OAuth client, set its authorized redirect URI to `https://<project-ref>.supabase.co/auth/v1/callback`, then enable Google under Supabase Dashboard → Authentication → Sign In / Providers and enter the client ID and secret. Add the deployed `https://<your-domain>/login.html` URL (and `http://localhost:8000/login.html` for local testing) to Supabase's allowed redirect URLs. The Google button requests `@latterup.org` accounts as a provider hint; database access policies remain the enforcement for private portal data.

The Student Leadership navigation link is available to signed-in users according to the visibility setting in Admin → Student Leadership: Off, Admins only, or Student Leadership and admins. The hub shows one weekly assignee for each chart role. Admins can add and rename roles, set their display order, configure member eligibility, shuffle members' rotation order, and temporarily remove a member from a single week's rotation. Admins can pin a member to a role for the current week without changing the rotation, and can add a member's `@latterup.org` email before the person has signed in; this adds them to the roster but does not create their Google account. A leader who is assigned this week can request the week off with a reason; the request only takes effect after an admin approves it. New roles are enabled for all current members by default. Admins can reorder their Admin tabs by dragging them, set points per approved chat report, give members documented bonus prize points, review reports and prize requests, and manage prizes. Student Leadership members can edit and delete announcements they created after `update-13-announcement-ownership.sql` is applied; older announcements have no creator recorded and remain admin-managed. Student Leadership membership is managed in Admin → Student Leadership or added by email in Admin → Students before first sign-in. Chat screenshots are stored in a private bucket; only their submitter and admins can view them. The Admin → Students page can permanently remove individual student accounts or all student accounts; Admin and Student Leadership accounts are protected, and removed students can create a new account by signing in with Google. New Google sign-ins appear in the Students list automatically and do not get redirected to the change-password page.

Removing email/password from the website login page requires no SQL. To disable password sign-in project-wide, change the Email provider in Supabase Dashboard → Authentication → Sign In / Providers; do not disable global sign-ups, because anonymous sign-ins for the public photo page depend on them.

For existing imported accounts that still have a forced-password-change flag, run this once in the Supabase SQL Editor so Google sign-in is not redirected to the password-change page:

```sql
update auth.users
   set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) - 'must_change_password',
       raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) - 'must_change_password'
 where lower(coalesce(email, '')) like '%@latterup.org'
   and (
     lower(coalesce(raw_app_meta_data->>'must_change_password', 'false')) = 'true'
     or lower(coalesce(raw_user_meta_data->>'must_change_password', 'false')) = 'true'
   );
```

For an existing database that already ran `setup.sql`, you can run `supabase/existing-project-all-updates.sql` once instead of running updates 2 and 4 through 9 individually, then run `supabase/update-10-student-leadership-hub.sql`, `supabase/update-11-email-alert-diagnostics.sql`, `supabase/update-12-leadership-role-overrides-and-photo-alerts.sql`, `supabase/update-13-announcement-ownership.sql`, and `supabase/update-14-leadership-bonus-points.sql`. The bundle is not for a new project. Before running it, deploy the `change-own-password` Edge Function as described below. The bundle does not deploy Edge Functions or change Supabase Auth settings.

The home page displays its three most recent announcements. Admins can reorder home page tiles by dragging them in Admin → Home Page; tile settings can be collapsed there. The adjustable banner can be dismissed per profile until 6 AM the next morning, and saving an updated banner makes it visible again.

The Admin → Email alerts test checks the asynchronous Apps Script response and sends test messages only to the admin who requested them. Apply `supabase/update-11-email-alert-diagnostics.sql` to enable response checking and `supabase/update-12-leadership-role-overrides-and-photo-alerts.sql` to configure photo-notification recipients. An HTTP 200 response with `ok: true` means Apps Script handed the email to Google Mail, but the message may still be in a recipient's spam folder or be subject to Google delivery limits. Choose Admins and Student Leadership, Student Leadership only, or turn off Photo Challenge notifications in Admin → Email alerts. Apply `supabase/update-13-announcement-ownership.sql` to let Student Leadership members edit and delete only announcements they created. Apply `supabase/update-14-leadership-bonus-points.sql` to let admins award additional prize points to Student Leadership members.

Before applying `supabase/update-8-security-and-data-fixes.sql`, deploy the `change-own-password` Edge Function from `supabase/functions/`. Update 8 migrates forced-password-change flags into protected app metadata; flagged users cannot access the site until that function is deployed and available. If update 8 was run before deploying the function, restore access with:

```sql
update auth.users
   set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) - 'must_change_password'
 where lower(coalesce(raw_app_meta_data->>'must_change_password', 'false')) = 'true';
```

Deploy the `change-own-password` Edge Function from `supabase/functions/`. For the public photo page, Supabase must allow new accounts and **Anonymous Sign-Ins** must be enabled; Supabase treats anonymous visitors as new auth users, so disabling sign-ups globally also blocks visitor sessions. The database trigger restricts accounts to `@latterup.org` addresses. The photo page uses a persistent anonymous session and the photo cap is per visitor session. CAPTCHA is not currently wired into the page; do not enable Supabase CAPTCHA for anonymous sign-ins unless a CAPTCHA token flow has also been added. If you do not want anonymous visitor accounts, keep the public photo page disabled and leave anonymous sign-ins off.

Update 8 adds the `videos_youtube_id_format` constraint as `NOT VALID` so old invalid rows don't block the migration. Before validating it, find and correct or remove any existing invalid IDs:

```sql
select id, youtube_id from public.videos
 where youtube_id is not null and youtube_id !~ '^[A-Za-z0-9_-]{11}$';
alter table public.videos validate constraint videos_youtube_id_format;
```

Student accounts are created automatically when they first sign in with their `@latterup.org` Google account. Supabase must allow new sign-ups for first-time sign-ins to create accounts. Admins can add existing accounts to Student Leadership from Admin → Students after the person has signed in once.
Only edit config.js if the Supabase project changes (anon key is public by design; never use the service_role key).

For local testing, serve the folder over HTTP instead of opening `index.html` directly from disk. From the project folder in PowerShell, run `py -m http.server 8000` (or `python -m http.server 8000`), then visit `http://localhost:8000`. Browsers do not reliably share authentication storage between pages opened with `file://`.

On `localhost` or `127.0.0.1`, open the profile menu and choose **Use local preview** to show sample announcements, video thumbnails, photo galleries, and the read-only admin preview. Choose **Exit local preview** to return to the normal signed-out or signed-in site view. Preview mode and its admin screen use sample data only and never grant Supabase permissions or write to Supabase. Sample files are kept in `PLACEHOLDER/`. The Netlify build in `netlify-build.cjs` excludes that folder and removes the preview loader tags from deployed HTML. Netlify publishes the generated `dist/` folder; don't override the publish directory if deploying from the repository. The regular site does not depend on any files in `PLACEHOLDER/`.


Portal customization: run `supabase/update-4-portal-customization.sql` in Supabase SQL Editor (safe to rerun). It adds the `portal_banner`, `portal_tiles`, and `portal_home_sections` columns and refreshes the Supabase schema cache. Then deploy the site files and open Admin → Portal Layout to edit the announcement banner and tiles, or Admin → Home page editor to show, hide, and reorder home page sections. The home page tile grid requires `portal-card-grid` in `index.html`, which is included in this version. These settings are stored in Supabase and persist when website source files are replaced.
