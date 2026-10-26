# Latter UP Student Portal
Static site (Netlify) + Supabase (login, database, file storage).
Content is edited at /admin.html — no code changes needed. Database setup: supabase/setup.sql, then supabase/update-2-names.sql. Student accounts are created from Admin → Import students (needs the import-students edge function from supabase/functions/).
Only edit config.js if the Supabase project changes (anon key is public by design; never use the service_role key).


Portal customization: run `supabase/update-4-portal-customization.sql` in Supabase SQL Editor (safe to rerun). It adds the `portal_banner`, `portal_tiles`, and `portal_home_sections` columns and refreshes the Supabase schema cache. Then deploy the site files and open Admin → Portal Layout to edit the announcement banner and tiles, or Admin → Home page editor to show/hide and reorder home page sections. The home page tile grid requires `portal-card-grid` in `index.html`, which is included in this version. These settings are stored in Supabase and persist when website source files are replaced.
