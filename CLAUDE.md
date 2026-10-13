# Supplier Orders

Mobile-first web app for placing weekly supplier orders over WhatsApp for a multi-outlet bar. Installable as a PWA, hosted on GitHub Pages.

## Structure
- `index.template.html`: the whole app (HTML/CSS/JS, no framework). `__DATA__` is replaced at build time with `data/data.json`.
- `data/data.json`: **fake sample data only** (this repo is public). Top-level keys: `business`, `outlets[]`, `items[]`, `suppliers[]`.
  - Item keys: `id`, `n` name, `s` supplier, `p` price, `pt` price text, `c` category, `pr` promo/note, `pk` pack size, `k` cocktails.
  - Supplier keys: `n` name, `t` type (`chat` | `online` | `internal` | `none`), `m` MOQ text, `mn` MOQ number, `cut` cut-off.
- Real data is never committed. Users load their own `data.json` with "Import data.json" (Suppliers tab). It is stored in localStorage key `supplier-orders-data` and overrides the built-in sample.
- `scripts/parse.py` + `scripts/build.py`: regenerate `data.json` from a spreadsheet export (`hops.xlsx`). Business-specific settings (aliases, MOQs, cut-offs, extra items, business name, outlets) live in `scripts/config.local.json` (git-ignored). `scripts/config.example.json` is the committed fake version and the fallback.
  - `build.py` also needs `items.json` (cocktail → ingredient → supplier, from the sheet's "Ingredients & Suppliers" tab). The script that produces it is not in this repo yet.
- `scripts/inject.py`: writes `dist/` (index.html + `manifest.webmanifest`, `sw.js`, `icons/`).
- `.github/workflows/deploy.yml`: on push to `main`, runs inject.py and publishes `dist/` to GitHub Pages.
- `private/` (git-ignored): the owner's real `data.json` and config.

## Build
    python scripts/inject.py                               # build dist/
    pip install openpyxl
    python scripts/parse.py && python scripts/build.py     # only when the sheet changes; run in a folder containing hops.xlsx

## Notes
- App state (cart, WhatsApp numbers, notes, history, custom items) lives in localStorage key `supplier-orders`. The `claude.use("db")` sync only works when published as a claude.ai artifact; elsewhere it does nothing.
- `sw.js` is network-first for the page and cache-first for icons and fonts. Bump `CACHE` when changing the shell file list.
- WhatsApp sending uses `https://wa.me/<number>?text=...`; 8-digit numbers get the 65 prefix.
- Never commit real prices, supplier contacts or the business name.
- Owner prefers a minimal, clean UI; don't add unrequested features.
