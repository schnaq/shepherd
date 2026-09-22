# shepherd.schnaq.com

The product page for Shepherd: one dark page in Next.js, hosted on Vercel.

## Run it

```sh
bun install
bun run dev        # http://localhost:3000
bun run build
bun run typecheck
```

`next build` needs Node, and Bun as the runtime does not get through page-data collection
(Next 16.3, Bun 1.3). On a Mac without Node, borrow one for the command:

```sh
mise x node@22 -- bun run build
```

Vercel has Node, so nothing changes there.

There is no test suite and no analytics. The page fetches the latest release from the GitHub API
once an hour (`lib/release.ts`) and falls back to a pinned version with a link to the release
list when the API cannot be reached.

## Deploy on Vercel

One Vercel project pointing at this repository with:

- **Root Directory:** `site`
- **Framework preset:** Next.js (detected)
- **Package manager:** Bun (detected from `bun.lock`)
- **Domain:** `shepherd.schnaq.com`, with a `CNAME` record at the DNS provider pointing to
  `cname.vercel-dns.com`

Nothing else to configure: no environment variables, no build command override.

## Where things live

- `app/` — layout, the single page, the Open Graph image
- `components/` — one file per section; `InboxDemo` and `CopyButton` are the only client components
- `lib/release.ts` — the release lookup
- `public/` — the app icon and the screenshots, copied from `docs/assets`
- `app/globals.css` — every style; the palette is Shepherd's own from `Theme.swift`
