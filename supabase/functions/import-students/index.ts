// Supabase Edge Function: import-students
// Lets a signed-in ADMIN create (or reset) student logins in bulk from the admin page.
// Supabase supplies the secret key to this function automatically; you never handle it.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const ALPHA = "abcdefghjkmnpqrstuvwxyzACDEFGHJKLMNPQRTUVWXYZ2346789";
const randomPw = () =>
  Array.from(crypto.getRandomValues(new Uint8Array(10)), (b) => ALPHA[b % ALPHA.length]).join("");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    // Only people listed in the admins table may use this.
    const token = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
    const { data: { user } } = await admin.auth.getUser(token);
    if (!user?.email) return json({ error: "Not signed in." }, 401);
    const { data: row } = await admin.from("admins").select("email").eq("email", user.email.toLowerCase()).maybeSingle();
    if (!row) return json({ error: "Admins only." }, 403);

    const { students, password, random, reset } = await req.json();
    if (!Array.isArray(students) || students.length < 1 || students.length > 50) return json({ error: "Send 1 to 50 students at a time." }, 400);
    if (!random && (typeof password !== "string" || password.length < 8)) return json({ error: "The starting password must be at least 8 characters." }, 400);

    const results: Record<string, unknown>[] = [];
    for (const s of students) {
      const email = String(s.email ?? "").trim().toLowerCase();
      const name = String(s.name ?? "").trim();
      if (!/^[^@\s]+@latterup\.org$/.test(email)) { results.push({ email, status: "skipped", note: "not an @latterup.org address" }); continue; }
      const pw = random ? randomPw() : password;
      const attrs = {
        password: pw,
        email_confirm: true,
        user_metadata: { must_change_password: true },
        app_metadata: name ? { full_name: name } : {},
      };
      const { error } = await admin.auth.admin.createUser({ email, ...attrs });
      if (!error) { results.push({ email, name, status: "created", password: pw }); continue; }

      if (/already|exists|registered/i.test(error.message)) {
        if (!reset) { results.push({ email, status: "exists", note: "already has an account (left alone)" }); continue; }
        let id: string | undefined;
        for (let p = 1; !id; p++) {
          const { data } = await admin.auth.admin.listUsers({ page: p, perPage: 200 });
          id = data?.users.find((u) => u.email?.toLowerCase() === email)?.id;
          if (!data || data.users.length < 200) break;
        }
        if (id) {
          const r = await admin.auth.admin.updateUserById(id, attrs);
          results.push(r.error ? { email, status: "failed", note: r.error.message } : { email, name, status: "reset", password: pw });
          continue;
        }
      }
      results.push({ email, status: "failed", note: error.message });
    }
    return json({ results });
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 500);
  }
});
