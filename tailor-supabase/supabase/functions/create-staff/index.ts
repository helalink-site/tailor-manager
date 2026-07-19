// Deploy this from Supabase Dashboard → Edge Functions → Deploy a new function
// → name it "create-staff" → paste this code in the browser editor → Deploy.
// No CLI, no terminal needed. It runs on Supabase's servers, not your phone.

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY");

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) throw new Error("Missing authorization");

    // Client scoped to whoever is calling, so we can check who they are.
    const caller = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: userErr } = await caller.auth.getUser();
    if (userErr || !user) throw new Error("Not authenticated");

    // Admin client, only usable inside this server function, never in the browser.
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: callerProfile } = await admin
      .from("staff").select("role, active").eq("id", user.id).single();
    if (!callerProfile || callerProfile.role !== "admin" || !callerProfile.active) {
      throw new Error("Only an active admin can add staff");
    }

    const { name, phone, password, role } = await req.json();
    if (!name || !phone || !password) throw new Error("Missing name, phone, or password");

    const digits = phone.replace(/\D/g, "");
    const email = `${digits}@tailor.local`;

    const { data: newUser, error: createErr } = await admin.auth.admin.createUser({
      email, password, email_confirm: true,
    });
    if (createErr) throw createErr;

    const { error: profileErr } = await admin.from("staff").insert({
      id: newUser.user.id, name, phone, role: role || "staff",
    });
    if (profileErr) throw profileErr;

    return new Response(JSON.stringify({ ok: true, id: newUser.user.id }), {
      headers: { ...cors, "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: err.message }), {
      status: 400,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }
});
