# Tono app-icon refresh — Mark → Dov / Gary

## Brand palette (sourced from tonoit.com website)

| Role         | Hex       | RGB             | Source on tonoit.com                          |
|--------------|-----------|-----------------|-----------------------------------------------|
| Primary accent (CTAs, "Try live demo" button, dot in nav) | `#A855F7` | 168, 85, 247    | `assets/styles.css` → `--accent`               |
| Accent hover / pressed                    | `#9333EA` | 147, 51, 234    | `--accent-hover`                              |
| Accent soft / muted text                  | `#D8B4FE` | 216, 180, 254   | `--accent-light` (also `--text-softer = #9ca3af`) |
| Brand violet gradient top → mid → deep    | `#B66BFF` → `#8B3DF0` → `#4E1A9E` | — | `brand.html` → `.sticker-violet` (radial gradient) |
| Background / dark base                    | `#000000` | 0, 0, 0         | `--bg`                                        |

The web wordmark is **lowercase "tono"**, Inter family, weight 700–900, letter-spacing −0.02em to −0.085em. SF Compact Black is the iOS-system analog (Apple ships it on macOS/iOS) — same geometric flavor, ships the brand, and the "t" will feel native on a user's home screen.

## Glyph convention

A true lowercase "t" — crossbar near the top of the x-height, vertical stem, no ascender. Set at roughly 62% of icon height, optically centered, in pure white (`#FFFFFF`) on the violet. iOS applies its own rounded-corner mask — we do **not** bake corners into the source PNG.

## Candidates (1024×1024, PNG, sRGB, no alpha)

| File                                | Background      | Glyph weight | Treatment    | Best for |
|-------------------------------------|-----------------|--------------|--------------|----------|
| `candidate-A-regular-flat.png`      | flat `#A855F7`  | black        | plain        | maximum scale, fastest read |
| `candidate-B-medium-gradient.png` ← **canonical** | vertical violet gradient `#D8B4FE → #A855F7 → #4E1A9E` | medium | none | on-brand with site's gradient stickers; mid-weight survives 60 px |
| `candidate-C-regular-grad-gloss.png`| gradient + top white sheen | black | 8% white top | iOS-style "material" polish |
| `candidate-D-medium-flat-glow.png`  | flat `#A855F7`  | medium       | soft white halo behind glyph | niche, looks like a notification bubble; risky if anything else is purple |

## Mockups

- `_preview/icon-candidates-mockup.png` — all four at 240 / 120 / 60 px with captions.
- `_preview/icon-home-screen-mockup.png` — each candidate scattered among faux apps at real 60 px home-screen size.
- `_preview/icon-legibility-sheet.png` — all four at 180 / 120 / 60 / 40 px so you can see which survives downscaling.

## Canonical asset (what Gary drops into Xcode)

`AppIcon.appiconset/icon-1024.png` — RGB, 1024×1024, sRGB, no alpha, no rounded corners baked in. Direction matches **candidate B** (gradient + medium weight "t"). All 10 sibling variants (`icon-20@2x.png` … `icon-167.png`) have been regenerated from the canonical file so everything on disk is consistent.

To rebuild in Xcode: opening the project with `icon-1024.png` swapped should be enough — Xcode 16 will downscale for the small slots on first build. If Gary prefers to start from a single 1024, deleting the smaller files and letting Xcode auto-generate also works.

## Recommendation

**B (gradient, medium weight)** — it's the only one that pays off the existing brand system (the gradient is straight off tonoit.com's brand stickers), and the medium-weight glyph holds up at 60 px without becoming either a thread (regular) or a blob (black). Distinctive against the apps it's likely to sit next to.

If Dov wants the cleaner "less is more" look, A is the safer fallback. C and D are both polished but add decoration that doesn't show up at 60 px and risks looking like a notification badge.

## Files touched (this folder only)

```
AppIcon.appiconset/
├── Contents.json
├── icon-20@2x.png        ← regenerated
├── icon-20@3x.png        ← regenerated
├── icon-29@2x.png        ← regenerated
├── icon-29@3x.png        ← regenerated
├── icon-40@2x.png        ← regenerated
├── icon-40@3x.png        ← regenerated
├── icon-60@2x.png        ← regenerated
├── icon-60@3x.png        ← regenerated
├── icon-152.png          ← regenerated
├── icon-167.png          ← regenerated
├── icon-1024.png         ← REPLACED (canonical, gradient + medium "t")
├── IconCandidates/       ← new, the 4 mockup-ready variants
└── _preview/             ← new, mockups + this README + build script
```

Nothing outside this folder was modified.
