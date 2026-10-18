-- Supplier Orders: team, roles, order requests and push notifications.
-- Run once in the Supabase SQL Editor (after the app_state table from the README).
-- Safe to run on a project that already has app_state; it only adds new tables and functions.

-- ---------- tables ----------
create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  code text not null unique,                 -- invite code staff type in to join
  data jsonb,                                -- shared supplier list (same shape as data.json)
  phones jsonb not null default '{}',        -- shared WhatsApp numbers {supplier: number}
  created_by uuid not null default auth.uid() references auth.users on delete cascade,
  updated_at timestamptz not null default now()
);

create table if not exists public.roles (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams on delete cascade,
  name text not null,
  can_order boolean not null default false,    -- send orders to suppliers directly
  can_approve boolean not null default false,  -- approve / hold requests
  can_manage boolean not null default false,   -- team, roles, supplier list
  suppliers text[],                            -- null = all suppliers
  is_default boolean not null default false    -- role given to people who join with the code
);

create table if not exists public.members (
  team_id uuid not null references public.teams on delete cascade,
  user_id uuid not null references auth.users on delete cascade,
  name text not null,
  role_id uuid references public.roles on delete set null,
  joined_at timestamptz not null default now(),
  primary key (team_id, user_id)
);
create unique index if not exists members_one_team on public.members(user_id);  -- one team per person

create table if not exists public.requests (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams on delete cascade,
  requester uuid not null default auth.uid() references auth.users on delete cascade,
  requester_name text not null,
  lines jsonb not null,                        -- [{id, q, n, s}]
  note text,
  outlet text,
  status text not null default 'pending' check (status in ('pending','approved','on_hold')),
  decided_by uuid references auth.users on delete set null,
  decided_by_name text,
  decided_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists requests_team on public.requests(team_id, created_at desc);

create table if not exists public.push_subs (
  endpoint text primary key,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  sub jsonb not null,
  created_at timestamptz not null default now()
);

-- ---------- helpers (run with owner rights so policies can use them) ----------
create or replace function public.my_team() returns uuid
language sql stable security definer set search_path = public as $$
  select team_id from members where user_id = auth.uid()
$$;

create or replace function public.my_perm(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select case p when 'order' then r.can_order when 'approve' then r.can_approve when 'manage' then r.can_manage end
    from members m join roles r on r.id = m.role_id
    where m.user_id = auth.uid()), false)
$$;

-- A team with members must always keep at least one manager
create or replace function public.ensure_manager(t uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from members where team_id = t)
     and not exists (select 1 from members m join roles r on r.id = m.role_id where m.team_id = t and r.can_manage) then
    raise exception 'The team needs at least one person who can manage it';
  end if;
end $$;

create or replace function public.trg_ensure_manager() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform ensure_manager(coalesce(new.team_id, old.team_id));
  return null;
end $$;

drop trigger if exists roles_keep_manager on public.roles;
create constraint trigger roles_keep_manager after update or delete on public.roles
  deferrable initially deferred for each row execute function public.trg_ensure_manager();
drop trigger if exists members_keep_manager on public.members;
create constraint trigger members_keep_manager after update or delete on public.members
  deferrable initially deferred for each row execute function public.trg_ensure_manager();

-- ---------- row-level security ----------
alter table public.teams enable row level security;
alter table public.roles enable row level security;
alter table public.members enable row level security;
alter table public.requests enable row level security;
alter table public.push_subs enable row level security;

drop policy if exists "members read team" on public.teams;
create policy "members read team" on public.teams for select using (id = public.my_team());
drop policy if exists "managers edit team" on public.teams;
create policy "managers edit team" on public.teams for update
  using (id = public.my_team() and public.my_perm('manage')) with check (id = public.my_team());

drop policy if exists "members read roles" on public.roles;
create policy "members read roles" on public.roles for select using (team_id = public.my_team());
drop policy if exists "managers add roles" on public.roles;
create policy "managers add roles" on public.roles for insert with check (team_id = public.my_team() and public.my_perm('manage'));
drop policy if exists "managers edit roles" on public.roles;
create policy "managers edit roles" on public.roles for update
  using (team_id = public.my_team() and public.my_perm('manage')) with check (team_id = public.my_team());
drop policy if exists "managers delete roles" on public.roles;
create policy "managers delete roles" on public.roles for delete using (team_id = public.my_team() and public.my_perm('manage'));

drop policy if exists "members read members" on public.members;
create policy "members read members" on public.members for select using (team_id = public.my_team());
drop policy if exists "managers remove members" on public.members;
create policy "managers remove members" on public.members for delete
  using (team_id = public.my_team() and (public.my_perm('manage') or user_id = auth.uid()));
-- joining, renaming and role changes go through the functions below

drop policy if exists "read requests" on public.requests;
create policy "read requests" on public.requests for select
  using (team_id = public.my_team() and (requester = auth.uid() or public.my_perm('approve')));
drop policy if exists "send requests" on public.requests;
create policy "send requests" on public.requests for insert
  with check (team_id = public.my_team() and requester = auth.uid() and status = 'pending' and decided_by is null);
drop policy if exists "cancel requests" on public.requests;
create policy "cancel requests" on public.requests for delete
  using (team_id = public.my_team() and ((requester = auth.uid() and status <> 'approved') or public.my_perm('manage')));
-- approving / holding goes through decide_request()

drop policy if exists "own push subs" on public.push_subs;
create policy "own push subs" on public.push_subs for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------- actions the app calls ----------
create or replace function public.create_team(team_name text, my_name text, team_data jsonb default null, team_phones jsonb default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare t uuid; mgr uuid; c text;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if exists (select 1 from members where user_id = auth.uid()) then raise exception 'You are already in a team'; end if;
  loop
    c := upper(substr(translate(md5(random()::text || clock_timestamp()::text), '01', ''), 1, 6));
    exit when length(c) = 6 and not exists (select 1 from teams where code = c);
  end loop;
  insert into teams (name, code, data, phones, created_by) values (team_name, c, team_data, coalesce(team_phones, '{}'), auth.uid()) returning id into t;
  insert into roles (team_id, name, can_order, can_approve, can_manage) values (t, 'Manager', true, true, true) returning id into mgr;
  insert into roles (team_id, name, can_order, can_approve) values (t, 'Senior', true, true);
  insert into roles (team_id, name, suppliers, is_default) values (t, 'Newcomer', array['Office'], true);
  insert into members (team_id, user_id, name, role_id) values (t, auth.uid(), my_name, mgr);
  return t;
end $$;

create or replace function public.join_team(invite_code text, my_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare t uuid; r uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if exists (select 1 from members where user_id = auth.uid()) then raise exception 'You are already in a team'; end if;
  select id into t from teams where code = upper(trim(invite_code));
  if t is null then raise exception 'That team code doesn''t exist'; end if;
  select id into r from roles where team_id = t and is_default order by name limit 1;
  insert into members (team_id, user_id, name, role_id) values (t, auth.uid(), my_name, r);
  return t;
end $$;

create or replace function public.set_member_role(member uuid, new_role uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not my_perm('manage') then raise exception 'Only managers can change roles'; end if;
  if not exists (select 1 from roles where id = new_role and team_id = my_team()) then raise exception 'Unknown role'; end if;
  update members set role_id = new_role where user_id = member and team_id = my_team();
end $$;

create or replace function public.set_my_name(new_name text)
returns void language sql security definer set search_path = public as $$
  update members set name = new_name where user_id = auth.uid()
$$;

create or replace function public.set_default_role(role uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not my_perm('manage') then raise exception 'Only managers can do this'; end if;
  update roles set is_default = (id = role) where team_id = my_team();
end $$;

create or replace function public.set_phone(supplier text, phone text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not (my_perm('order') or my_perm('manage')) then raise exception 'Not allowed'; end if;
  -- updated_at is left alone: it marks supplier-list changes, and phones don't need a list reload
  update teams set phones = case when coalesce(phone, '') = '' then phones - supplier else phones || jsonb_build_object(supplier, phone) end
   where id = my_team();
end $$;

create or replace function public.decide_request(request uuid, new_status text, my_name text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not my_perm('approve') then raise exception 'Only approvers can do this'; end if;
  if new_status not in ('approved', 'on_hold') then raise exception 'Unknown status'; end if;
  update requests set status = new_status, decided_by = auth.uid(), decided_by_name = my_name, decided_at = now()
   where id = request and team_id = my_team();
  if not found then raise exception 'Request not found'; end if;
end $$;

create or replace function public.new_team_code()
returns text language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if not my_perm('manage') then raise exception 'Only managers can do this'; end if;
  loop
    c := upper(substr(translate(md5(random()::text || clock_timestamp()::text), '01', ''), 1, 6));
    exit when length(c) = 6 and not exists (select 1 from teams where code = c);
  end loop;
  update teams set code = c where id = my_team();
  return c;
end $$;
