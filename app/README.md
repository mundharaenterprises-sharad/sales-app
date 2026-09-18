# Sales App — the PWA

React + TypeScript, talking to Supabase. Installs to a phone home screen; no
app store.

## Setup

```bash
cd app
npm install
cp .env.example .env.local     # then fill in the two values
npm run dev
```

The two values come from Supabase: **Project Settings → Data API**, where you
want the **Project URL** and the **anon public** key.

The anon key is meant to be public — it ships inside the browser bundle, and
row-level security is what actually protects the data. The **service_role** key
is the opposite: it bypasses RLS entirely and must never appear in any `VITE_`
variable, because everything prefixed `VITE_` is visible to anyone who opens
the site.

Missing configuration shows a plain message on the login screen naming the file
to create, rather than a blank page.

## Commands

| | |
|---|---|
| `npm run dev` | Development server with hot reload |
| `npm run build` | Typecheck, then production build into `dist/` |
| `npm run preview` | Serve the production build locally |

## How it is put together

```
src/
  lib/
    supabase.ts   Client, roles, and turning database errors into plain English
    session.tsx   Who is signed in, their role, and online/offline state
    cache.ts      IndexedDB snapshots for offline reading
    format.ts     Money, quantities, dates — formatted the same way everywhere
  components/     Layout, and small shared pieces
  screens/        One file per screen
```

**Permissions are not enforced here.** Hiding a button is a courtesy, not
security. Every rule is enforced by row-level security and the database
functions, so a rep who tampers with the app still cannot raise an invoice.

**Offline is read-only, deliberately.** Products, stock and parties are cached
in IndexedDB and shown with their age stated plainly. Orders always need a
connection, because a reservation taken against a stale stock figure is a
reservation you cannot trust.

**Errors carry codes.** `SA001` means insufficient stock and its `details`
payload lists exactly what is short — that is what the order screen will render
when a rep tries to sell something that has gone.

## Deploying

Cloudflare Pages, building from this repository:

| Setting | Value |
|---|---|
| Build command | `npm run build` |
| Build output directory | `dist` |
| Root directory | `app` |

Set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` as environment variables
in the Pages project. Vite bakes them in at build time, so changing one needs a
rebuild, not just a restart.
