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

There is no test suite and no analytics. No version is written into the page: the download
buttons lead to GitHub's `releases/latest`, and a shields.io badge beside them
(`components/LatestRelease.tsx`) shows the current version as GitHub reports it, so a release
never needs a redeploy.

## Deploy on Vercel

`.github/workflows/site.yml` deploys: every push to `main` that touches `site/` is built,
typechecked, built again as Vercel's production output (`vercel build --prod`) and shipped with
`vercel deploy --prebuilt --prod`, so what goes live is what the workflow checked. Actions → Site →
Run workflow redeploys `main` by hand. Pull requests get the build and typecheck, no deploy.

This is the only deploy path. **Vercel's Git integration must stay disconnected** from this
repository (Vercel → Project → Settings → Git), or every push deploys twice.

The workflow needs three repository secrets: `VERCEL_TOKEN` (a token of an account that is a
member of the team), `VERCEL_ORG_ID` and `VERCEL_PROJECT_ID` (both from `vercel link`, in
`.vercel/project.json`). The project settings the CLI pulls:

- **Root Directory:** `site`
- **Framework preset:** Next.js (detected)
- **Package manager:** Bun (detected from `bun.lock`)
- **Domain:** `shepherd.schnaq.com`, with a `CNAME` record at the DNS provider pointing to
  `cname.vercel-dns.com`

## Where things live

- `app/` — layout, the single page, the Open Graph image
- `components/` — one file per section; `InboxDemo` and `CopyButton` are the only client components
- `public/` — the app icon and the screenshots, copied from `docs/assets`
- `app/globals.css` — every style; the palette is Shepherd's own from `Theme.swift`
