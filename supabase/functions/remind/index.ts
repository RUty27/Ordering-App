// Sends cut-off reminders ("Order Citrus Lane by 4pm").
// Run every 15 minutes by Supabase Cron (see README). Each reminder goes out at most once a day.
// Uses the same secrets as the notify function: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.117.2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT") || "mailto:orders@example.com",
  Deno.env.get("VAPID_PUBLIC_KEY")!, Deno.env.get("VAPID_PRIVATE_KEY")!);

const WINDOW = 30; // two 15-minute runs, so one late or missed run still sends (last_sent stops doubles)
const DOW = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const plural = (n: number, w: string) => `${n} ${w}${n === 1 ? "" : "s"}`;

// Weekday, minutes past midnight and date (yyyy-mm-dd) in a time zone
function localNow(tz: string, now: Date) {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-US", { timeZone: tz, weekday: "short", year: "numeric", month: "2-digit",
    day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(now).map(x => [x.type, x.value]));
  return { day: DOW.indexOf(p.weekday), mins: +p.hour * 60 + +p.minute, date: `${p.year}-${p.month}-${p.day}` };
}

Deno.serve(async () => {
  const now = new Date();
  const { data: rems } = await db.from("reminders").select("*");
  const due = (rems || []).filter((r: any) => {
    const t = localNow(r.tz || "Asia/Singapore", now), [h, m] = String(r.at).split(":").map(Number), at = h * 60 + m;
    // Due if its time fell within the window today, on one of its days, and it hasn't gone out today
    return r.days.includes(t.day) && at <= t.mins && at > t.mins - WINDOW && r.last_sent !== t.date;
  });
  if (!due.length) return new Response("nothing due");

  const users = [...new Set(due.map((r: any) => r.user_id))];
  const [{ data: subs }, { data: states }] = await Promise.all([
    db.from("push_subs").select("endpoint, sub, user_id").in("user_id", users),
    db.from("app_state").select("user_id, state, data").in("user_id", users)]);
  let sent = 0;
  for (const r of due) {
    // "3 items in your order" when this person's synced order already has items from the supplier
    const row = (states || []).find((s: any) => s.user_id === r.user_id), items = (row && row.data && row.data.items) || [];
    const cart = Object.keys((row && row.state && row.state.cart) || {});
    const custom = (row && row.state && row.state.custom) || [];
    const n = cart.filter(id => [...items, ...custom].some((i: any) => String(i.id) === id && i.s === r.supplier)).length;
    const msg = JSON.stringify({ title: `Order ${r.supplier} by ${r.cut || "the cut-off"}`,
      body: n ? `1 hour to go. ${plural(n, "item")} in your order.` : "1 hour to go.", tag: "remind-" + r.supplier, url: "./?screen=order" });
    await Promise.all((subs || []).filter((s: any) => s.user_id === r.user_id).map((s: any) => webpush.sendNotification(s.sub, msg)
      .then(() => sent++)
      .catch(async (e: any) => {
        if (e.statusCode === 404 || e.statusCode === 410) await db.from("push_subs").delete().eq("endpoint", s.endpoint);
      })));
    await db.from("reminders").update({ last_sent: localNow(r.tz || "Asia/Singapore", now).date })
      .eq("user_id", r.user_id).eq("supplier", r.supplier);
  }
  return new Response(`sent ${sent}`);
});
