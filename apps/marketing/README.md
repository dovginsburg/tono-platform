# Tono Marketing Site

Static HTML deployed at **tonoit.com/**. The web app (`/app`) lives in
`apps/web/`; this subtree is the marketing surface — landing, features,
pricing, demo, docs entry, legal, and brand assets.

## Pages

| File | Title | Notes |
|---|---|---|
| `index.html` | tono — say what you mean | Hero + product intro |
| `features.html` | Features | |
| `pricing.html` | Pricing | |
| `demo.html` | Try it now | |
| `about.html` | About | |
| `brand.html` | tono — brand | Logos, palette, voice |
| `tono-icon-designs.html` | Icon explorations | |
| `docs/` | Public docs landing | Mirrors root docs site |
| `privacy.html` | Privacy Policy | |
| `terms.html` | Terms of Service | |

## Build / preview

No build step — these are plain HTML/CSS files served as-is. Two ways to
preview locally:

```sh
# Option 1: any static server
cd apps/marketing
python -m http.server 8080
open http://localhost:8080

# Option 2: serve from the repo root with whatever you already use (Netlify,
# Cloudflare Pages, GitHub Pages — repo's `CNAME` file pins the domain).
```

## Layout

```
apps/marketing/
├── index.html, about.html, brand.html, ...   # static pages
├── assets/        # CSS, JS, optimized images
├── icons/         # icon set
├── videos/        # demo / explainer videos
├── docs/          # public docs landing
└── CNAME          # tonoit.com (consumed by GitHub Pages / Netlify / CF)
```

## Out of scope for `tono-platform`

This subtree was cherry-picked from `dovginsburg/tonoit.com` via
`git subtree add` in commit `22d7386`. New marketing copy continues to
land in `tonoit.com` until the final-excellence gate (`t_319676e8`)
clears this subtree. See `../../OWNERSHIP.md` for the canonical table.
