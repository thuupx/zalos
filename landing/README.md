# zalos landing site

Marketing page for zalos. Next.js 16 (App Router), React 19, Tailwind CSS v4,
shadcn/ui (Base UI primitives), bun. Bilingual (Vietnamese default, English) with
light and dark themes.

```bash
bun install
bun run dev                    # http://localhost:3000
bun run lint && bun run build  # what CI/Vercel runs
```

## Structure

| Path | What |
|------|------|
| `src/content/site.ts` | All copy, Vietnamese and English (same shape). Edit text here, never in components. |
| `src/lib/i18n.tsx` | `LocaleProvider` / `useLocale()`; choice persisted in `localStorage` (`zalos-locale`). |
| `src/components/site/` | One component per section (header, hero, chat mockup, features, how it works, security, quick start, FAQ, CTA, footer). |
| `src/components/ui/` | shadcn components (generated; add more with `bunx --bun shadcn@latest add <name>`). |
| `src/app/globals.css` | Theme tokens mirrored from the client's `client/lib/src/ui/theme/tokens.dart`. |
| `src/fonts/` | Google Sans Flex (OFL), the same font as the client app. |
| `public/brand/` | zalos logo and app icon. |

Use theme tokens (`bg-brand`, `text-brand-text`, `bg-bubble-out`, ...) instead of
raw colors so both themes stay in sync with the client.

## Deploy

Vercel project with **Root Directory** `landing`, framework Next.js, install
command `bun install`, build command `bun run build`. Set `NEXT_PUBLIC_SITE_URL`
to the production URL so Open Graph links resolve.
