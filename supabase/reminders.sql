-- Supplier Orders: cut-off reminders (a phone notification before a supplier's cut-off).
-- Run once in the Supabase SQL Editor, after team.sql (it uses the push_subs table from there).
-- Safe to run again.

create table if not exists public.reminders (
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  supplier text not null,
  at time not null,              -- local time to send (1 hour before the cut-off)
  days int[] not null,           -- weekdays to send on, 0 = Sunday … 6 = Saturday
  cut text not null default '',  -- the cut-off as people read it, e.g. "4pm"
  tz text not null default 'Asia/Singapore',
  last_sent date,                -- set by the sender so a reminder goes out once a day
  primary key (user_id, supplier)
);

alter table public.reminders enable row level security;
drop policy if exists "own reminders" on public.reminders;
create policy "own reminders" on public.reminders for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());
