# PLACEHOLDER preview assets

This folder contains local-only sample content, images, and a read-only admin mockup for checking page layouts. On `localhost` or `127.0.0.1`, enable it from the profile menu with **Use local preview**. Exit preview from the same menu. When preview is off, sample images and content are not rendered, including when signed out.

The admin preview uses mock data only. It does not grant Supabase permissions and all save, upload, and account-management operations are disabled.

To exclude the preview from a Netlify deploy, remove the `<script src="PLACEHOLDER/preview.js"></script>` line from `index.html`, `announcements.html`, `videos.html`, and `photos.html`, remove the preview loader from `admin.html`, and leave this folder out of the deploy. The production site does not depend on this folder.
