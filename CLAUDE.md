# Supplier Orders

Mobile-first web app for placing weekly supplier orders over WhatsApp for a multi-outlet bar. Installable as a PWA, hosted on GitHub Pages.

## Structure
- `index.template.html`: the whole app (HTML/CSS/JS, no framework). `__DATA__` is replaced at build time with `data/data.json`.
  - UI follows the design handoff (indigo, light + dark): bottom tabs Items / Suppliers / History (+ Requests in a team), floating "Review order" button, Review order screen, bottom sheets (Delivery, Appearance, Send preview, Sent with Undo), welcome screen on first run.
  - Design tokens are CSS variables (`--bg --sf --card --ink --mute --line --acc --accInk --a1 --a7 --ok --ok1`) on `:root` and `:root[data-theme="dark"]`. Fonts: Caprasimo (headings/buttons) + Figtree (body). Icons: inline Lucide SVG paths in the `ICON` map.
  - Appearance choice (`system` | `light` | `dark`) is per phone in localStorage key `supplier-orders-theme` (not synced); an inline head script applies it before paint.
  - Ordering flow: Send → preview sheet → Open WhatsApp/Copy → "Sent?" sheet (`ask`). Only "Yes, sent" saves to History (`markSent`), then the Sent sheet offers Next / Undo.
  - Review cards fix problems in place: "Add items" jumps to Items filtered to that supplier; chat suppliers without a number get a WhatsApp number field on the card.
  - `dateClash()` reads the supplier's free-text `cut` for "<Day>s only" delivery days and a same-day cut-off time (e.g. "Order by 4pm") when the delivery date is tomorrow, and shows a warning on the card.
  - Chosen delivery date is saved as `st.delivery` (yyyy-mm-dd) and kept while it's still one of the next four delivery days.
  - Chip row: "In my order · n" (when the cart has items), All, "Cocktails ›" (switches the row to cocktail chips), then suppliers.
  - Stock count (`screen="count"`, `countHTML()`): "Count" on an Items group header. Usual amount = `parOf(i)` (`st.par[id]` override, else item `par`); shelf counts live only in `shelf` (not saved); "Add n items" sets `st.cart[id]` to the shortfall.
  - Rendering is plain `innerHTML` (`render()` for the page, `renderSheet()` for sheets) with one delegated click handler keyed on `data-act`.
- `data/data.json`: **fake sample data only** (this repo is public). Top-level keys: `business`, `outlets[]`, `billing` (billing address lines), `addresses` ({outlet: delivery address lines}), `deliveryTime`, `items[]`, `suppliers[]`.
  - Order message (`message()`): *Billing Address* 🚩billing, *Delivery Address* (outlet address, or "business outlet"), *Delivery Date:* "19 Oct 2026 Mon", *Delivery Time:*, item lines "12 btls Name" (`lineText()`: item unit `u`, pluralised; a typed unit wins), note, "Thanks 😊".
  - Item keys: `id`, `n` name, `s` supplier, `p` price, `pt` price text, `c` category, `pr` promo/note, `pk` pack size, `k` cocktails, `u` unit (btl, ctn, pkt…; optional), `par` usual amount for stock counts (optional).
  - Supplier keys: `n` name, `t` type (`chat` | `online` | `internal` | `none`), `m` MOQ text, `mn` MOQ number, `cut` cut-off, `note` free-text note shown on supplier and review cards (optional).
- Real data is never committed. Users load their own `data.json` with "Import data.json" (Suppliers tab). It is stored in localStorage key `supplier-orders-data` and overrides the built-in sample.
- `scripts/parse.py` + `scripts/build.py`: regenerate `data.json` from a spreadsheet export (`hops.xlsx`). Business-specific settings (aliases, MOQs, cut-offs, extra items, business name, outlets) live in `scripts/config.local.json` (git-ignored). `scripts/config.example.json` is the committed fake version and the fallback.
  - `build.py` also needs `items.json` (cocktail → ingredient → supplier, from the sheet's "Ingredients & Suppliers" tab). The script that produces it is not in this repo yet.
- `scripts/inject.py`: writes `dist/` (index.html + `manifest.webmanifest`, `sw.js`, `icons/`).
- `.github/workflows/deploy.yml`: on push to `main`, runs inject.py and publishes `dist/` to GitHub Pages.
- `sync.json`: Supabase project URL + public anon key for phone sync, plus `vapid` (public push key). Empty values hide the sync UI. The key is public by design; row-level security protects the data.
- `private/` (git-ignored): the owner's real `data.json` and config.

## Phone sync (Supabase)
- Table `public.app_state(user_id uuid pk default auth.uid(), state jsonb, data jsonb, updated_at timestamptz)` with RLS policy "own row only" (`auth.uid() = user_id`). SQL is in README.
- Login is email + password (`signInWithPassword` / `signUp`) with "Confirm email" turned off in Supabase, so no emails are sent. Not magic links (iOS home-screen apps don't share storage with Safari) and not email codes (free projects can't edit email templates without custom SMTP).
- supabase-js is loaded from jsdelivr (pinned version, `SUPA_JS`) only when sync is configured; `sw.js` caches it.
- Pull happens on start, on returning to the foreground and on `online`. Push is a debounced upsert after `save()`. Newest `updated_at` vs `st.updatedAt` wins. On first sign-in the cloud copy wins.
- Imported data syncs via its `importedAt` stamp. "Use sample data" stores a `{sample:true, importedAt}` marker so other phones follow.

## Teams (supabase/team.sql)
- Tables `teams` (name, invite `code`, shared `data` + `phones`), `roles` (`can_order`, `can_approve`, `can_manage`, `suppliers` text[] null = all, `is_default`), `members` (one team per user), `requests` (`lines` [{id,q,n,s}], `status` pending | approved | on_hold), `push_subs`. RLS everywhere; joining, role changes, phones and decisions go through security-definer RPCs (`create_team`, `join_team`, `set_member_role`, `set_default_role`, `set_phone`, `decide_request`, `new_team_code`). A team always keeps one manager (constraint trigger).
- Client (`team` block in the template): `loadTeam()` after pull; `can(p)` / `seesSup(s)` / `phoneOf(s)` are true/personal when not in a team, so solo use is unchanged. Team `data` is applied with a `"team:"+updated_at` stamp in `importedAt` (change → reload). Managers' imports write `teams.data`.
- Roles without `can_order` see "Send request" on Review instead of per-supplier send; approving adds the lines to the approver's cart. Supplier limits are UI-only (documented).
- Push: public VAPID key is `sync.json` `vapid`; private key only in Supabase secrets (owner's copy in `private/vapid.txt`). `supabase/functions/notify` (Database Webhook on `requests` insert/update) re-reads the row with the service role, only sends for events < 5 min old, and drops 404/410 subscriptions. `sw.js` shows the notification and opens `./?tab=requests`.

## Cut-off reminders (supabase/reminders.sql)
- Table `reminders(user_id, supplier, at time, days int[] 0=Sun, cut, tz, last_sent)`, RLS own rows. `remindPlan()` reads the time from the supplier's `cut` text (1 h earlier; Mon–Sat, Mon–Fri when there's a separate Sat time, or the day before a "<Day>s only" delivery day). Toggle on Suppliers cards (signed in + push supported); turning one on also turns on notifications.
- "Turn on notifications" lives in the Sync panel. `supabase/functions/remind` runs every 15 min (Supabase Cron), sends reminders due in the last 30 min that haven't gone out today (`last_sent`), adds the count of that supplier's items in the synced cart, and opens `./?screen=order`.

## Build
    python scripts/inject.py                               # build dist/
    pip install openpyxl
    python scripts/parse.py && python scripts/build.py     # only when the sheet changes; run in a folder containing hops.xlsx

## Notes
- App state (cart, WhatsApp numbers, notes, history, custom items) lives in localStorage key `supplier-orders`, and is synced to Supabase when signed in.
- `sw.js` is network-first for the page and cache-first for icons and fonts. Bump `CACHE` when changing the shell file list.
- WhatsApp sending uses `https://wa.me/<number>?text=...`; 8-digit numbers get the 65 prefix.
- Never commit real prices, supplier contacts or the business name.
- Owner prefers a minimal, clean UI; don't add unrequested features.
