import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  try {
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    if (!token) return json({ error: "Not signed in." }, 401);

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const { data: { user }, error: userError } = await admin.auth.getUser(token);
    if (userError || !user) return json({ error: "Sign-in could not be verified." }, 401);
    if (user.is_anonymous) return json({ error: "Anonymous visitor sessions cannot set passwords." }, 403);

    const body = await req.json();
    if (typeof body.password !== "string" || body.password.length < 8) {
      return json({ error: "The new password must be at least 8 characters." }, 400);
    }

    const { error } = await admin.auth.admin.updateUserById(user.id, {
      password: body.password,
      user_metadata: { ...user.user_metadata, must_change_password: false },
      app_metadata: { ...user.app_metadata, must_change_password: false },
    });
    if (error) return json({ error: error.message }, 400);

    return json({ ok: true });
  } catch (error) {
    return json({ error: String((error as Error).message ?? error) }, 500);
  }
});
