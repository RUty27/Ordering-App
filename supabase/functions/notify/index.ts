// Sends phone notifications for team order requests.
// Called by a Supabase Database Webhook on public.requests (insert + update), see README.
//   new request          -> everyone in the team whose role can approve
//   approved / on hold   -> the person who asked
// Secrets: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY (and optionally VAPID_SUBJECT, e.g. mailto:you@example.com).
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.117.2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT") || "mailto:orders@example.com",
  Deno.env.get("VAPID_PUBLIC_KEY")!, Deno.env.get("VAPID_PRIVATE_KEY")!);

// Only events from the last few minutes, so a replayed call can't spam anyone
const recent = (t?: string) => !!t && Date.now() - Date.parse(t) < 5 * 60 * 1000;
const plural = (n: number, w: string) => `${n} ${w}${n === 1 ? "" : "s"}`;

Deno.serve(async (req: Request) => {
  const p = await req.json().catch(() => null);
  const id = p && p.record && p.record.id;
  if (!id) return new Response("ignored");
  // Don't trust the payload: read the request again from the database
  const { data: r } = await db.from("requests").select("*").eq("id", id).maybeSingle();
  if (!r) return new Response("ignored");

  const lines = r.lines || [], items = plural(lines.length, "item");
  let users: string[] = [], title = "", body = "";
  if (p.type === "INSERT" && r.status === "pending" && recent(r.created_at)) {
    const { data } = await db.from("members").select("user_id, roles!inner(can_approve)")
      .eq("team_id", r.team_id).eq("roles.can_approve", true);
    users = (data || []).map((m: any) => m.user_id).filter((u: string) => u !== r.requester);
    title = `New request from ${r.requester_name}`;
    body = `${items}: ${lines.slice(0, 3).map((l: any) => l.n).join(", ")}${lines.length > 3 ? "…" : ""}`;
  } else if (p.type === "UPDATE" && r.status !== "pending" && recent(r.decided_at)) {
    users = [r.requester];
    title = r.status === "approved" ? "Request approved" : "Request on hold";
    body = `${items}, by ${r.decided_by_name || "a manager"}`;
  }
  if (!users.length) return new Response("nobody to notify");

  const { data: subs } = await db.from("push_subs").select("endpoint, sub").in("user_id", users);
  let sent = 0;
  await Promise.all((subs || []).map((s: any) => webpush.sendNotification(s.sub, JSON.stringify({ title, body, tag: r.id }))
    .then(() => sent++)
    .catch(async (e: any) => {
      // The phone turned notifications off or the app was removed: forget it
      if (e.statusCode === 404 || e.statusCode === 410) await db.from("push_subs").delete().eq("endpoint", s.endpoint);
    })));
  return new Response(`sent ${sent}`);
});
