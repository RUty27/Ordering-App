# Supplier Orders

Mobile-first web app for placing weekly supplier orders over WhatsApp for a multi-outlet bar. Installable as a PWA, hosted on GitHub Pages.

## Structure
- `index.template.html`: the whole app (HTML/CSS/JS, no framework). `__DATA__` is replaced at build time with `data/data.json`.
  - UI follows the design handoff (indigo, light + dark): bottom tabs Items / Suppliers / History, floating "Review order" button, Review order screen, bottom sheets (Delivery, Appearance, Send preview, Sent with Undo), welcome screen on first run.
  - Design tokens are CSS variables (`--bg --sf --card --ink --mute --line --acc --accInk --a1 --a7 --ok --ok1`) on `:root` and `:root[data-theme="dark"]`. Fonts: Caprasimo (headings/buttons) + Figtree (body). Icons: inline Lucide SVG paths in the `ICON` map.
  - Appearance choice (`system` | `light` | `dark`) is per phone in localStorage key `supplier-orders-theme` (not synced); an inline head script applies it before paint.
  - Ordering flow: Send → preview sheet → Open WhatsApp/Copy → "Sent?" sheet (`ask`). Only "Yes, sent" saves to History (`markSent`), then the Sent sheet offers Next / Undo.
  - Review cards fix problems in place: "Add items" jumps to Items filtered to that supplier; chat suppliers without a number get a WhatsApp number field on the card.
  - `dateClash()` reads the supplier's free-text `cut` for "<Day>s only" delivery days and a same-day cut-off time (e.g. "Order by 4pm") when the delivery date is tomorrow, and shows a warning on the card.
  - Chosen delivery date is saved as `st.delivery` (yyyy-mm-dd) and kept while it's still one of the next four delivery days.
  - Chip row: "In my order · n" (when the cart has items), All, "Cocktails ›" (switches the row to cocktail chips), then suppliers.
  - Rendering is plain `innerHTML` (`render()` for the page, `renderSheet()` for sheets) with one delegated click handler keyed on `data-act`.
- `data/data.json`: **fake sample data only** (this repo is public). Top-level keys: `business`, `outlets[]`, `billing` (billing address lines), `addresses` ({outlet: delivery address lines}), `deliveryTime`, `items[]`, `suppliers[]`.
  - Order message (`message()`): *Billing Address* 🚩billing, *Delivery Address* (outlet address, or "business outlet"), *Delivery Date:* "19 Oct 2026 Mon", *Delivery Time:*, item lines "12 btls Name" (`lineText()`: item unit `u`, pluralised; a typed unit wins), note, "Thanks 😊".
  - Item keys: `id`, `n` name, `s` supplier, `p` price, `pt` price text, `c` category, `pr` promo/note, `pk` pack size, `k` cocktails, `u` unit (btl, ctn, pkt…; optional).
  - Supplier keys: `n` name, `t` type (`chat` | `online` | `internal` | `none`), `m` MOQ text, `mn` MOQ number, `cut` cut-off, `note` free-text note shown on supplier and review cards (optional).
- Real data is never committed. Users load their own `data.json` with "Import data.json" (Suppliers tab). It is stored in localStorage key `supplier-orders-data` and overrides the built-in sample.
- `scripts/parse.py` + `scripts/build.py`: regenerate `data.json` from a spreadsheet export (`hops.xlsx`). Business-specific settings (aliases, MOQs, cut-offs, extra items, business name, outlets) live in `scripts/config.local.json` (git-ignored). `scripts/config.example.json` is the committed fake version and the fallback.
  - `build.py` also needs `items.json` (cocktail → ingredient → supplier, from the sheet's "Ingredients & Suppliers" tab). The script that produces it is not in this repo yet.
- `scripts/inject.py`: writes `dist/` (index.html + `manifest.webmanifest`, `sw.js`, `icons/`).
- `.github/workflows/deploy.yml`: on push to `main`, runs inject.py and publishes `dist/` to GitHub Pages.
- `sync.json`: Supabase project URL + public anon key for phone sync. Empty values hide the sync UI. The key is public by design; row-level security protects the data.
- `private/` (git-ignored): the owner's real `data.json` and config.

## Phone sync (Supabase)
- Table `public.app_state(user_id uuid pk default auth.uid(), state jsonb, data jsonb, updated_at timestamptz)` with RLS policy "own row only" (`auth.uid() = user_id`). SQL is in README.
- Login is email + password (`signInWithPassword` / `signUp`) with "Confirm email" turned off in Supabase, so no emails are sent. Not magic links (iOS home-screen apps don't share storage with Safari) and not email codes (free projects can't edit email templates without custom SMTP).
- supabase-js is loaded from jsdelivr (pinned version, `SUPA_JS`) only when sync is configured; `sw.js` caches it.
- Pull happens on start, on returning to the foreground and on `online`. Push is a debounced upsert after `save()`. Newest `updated_at` vs `st.updatedAt` wins. On first sign-in the cloud copy wins.
- Imported data syncs via its `importedAt` stamp. "Use sample data" stores a `{sample:true, importedAt}` marker so other phones follow.

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
