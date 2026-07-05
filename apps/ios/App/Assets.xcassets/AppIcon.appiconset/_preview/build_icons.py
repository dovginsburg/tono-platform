#!/usr/bin/env python3
"""
Tono app-icon generator — lowercase 't' on Tono web purple.

Palette pulled from tonoit.com (website/assets/styles.css):
  --accent:           #A855F7  (primary brand violet, buttons, CTAs)
  --accent-hover:     #9333EA
  --accent-light:     #D8B4FE
  Brand violet gradient: #B66BFF -> #8B3DF0 -> #4E1A9E  (stickers)

Web wordmark: lowercase Inter weight 800-900, tight tracking.
iOS system analog: SF Compact Black — same geometric flavor.

We render 4 candidates + the canonical 1024 (same look as candidate 1),
then produce:
  - 4 x 1024×1024 PNGs (full square, NO rounded corners baked in — iOS applies)
  - 1 x mockup sheet PNG showing each at home-screen sizes
  - 1 x legibility contact-sheet PNG at 180 / 120 / 60 / 40 px

All PNGs are sRGB, no alpha channel (iOS AppIcon requirement).
"""
from __future__ import annotations
from PIL import Image, ImageDraw, ImageFilter, ImageFont
import os, math

# ---------- CONFIG ----------
OUT_DIR       = '/Users/Ezra/Projects/apps/tono/ios/App/Assets.xcassets/AppIcon.appiconset/IconCandidates'
PREVIEW_DIR   = '/Users/Ezra/Projects/apps/tono/ios/App/Assets.xcassets/AppIcon.appiconset/_preview'
ICONSET_DIR   = '/Users/Ezra/Projects/apps/tono/ios/App/Assets.xcassets/AppIcon.appiconset'
SZ            = 1024

# Brand purple (canonical "Tono accent" — also matches the brand's purple stickers)
TONE_ACCENT   = (0xA8, 0x55, 0xF7)   # #A855F7
TONE_ACCENT_HOVER = (0x93, 0x33, 0xEA)  # #9333EA
TONE_LIGHT    = (0xD8, 0xB4, 0xFE)   # #D8B4FE
TONE_DEEP     = (0x4E, 0x1A, 0x9E)   # #4E1A9E

# Font: SF Compact (Apple system, ships with macOS). Black weight mirrors Inter 900.
FONT_PATH = '/System/Library/Fonts/SFCompact.ttf'

# ---------- HELPERS ----------
def load_font(point_size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT_PATH, point_size)


def measure_glyph(draw: ImageDraw.ImageDraw, ch: str, font: ImageFont.FreeTypeFont):
    """Return (x_off, y_off, w, h) so textwidth accounts for left/top bearing."""
    l, t, r, b = draw.textbbox((0, 0), ch, font=font)
    return l, t, r, b


def render_icon(
    *,
    size: int,
    bg_kind: str,            # 'flat' | 'gradient' | 'gradient_gloss'
    glyph_color,
    glyph_weight: str,       # 'regular' | 'medium' | 'black'
    glow: bool = False,
    return_surface: bool = False,
):
    """
    Produce a single RGBA surface of `size`×`size`. Pixel-precise lowercase 't'.
    iOS applies its own mask — NO rounded corners are drawn here.
    """
    # Glyph point size: lowercase 't' should fill ~58-62% of icon vertically
    # (standard product-icon glyph cap height ratio). We tune per weight.
    ratio = {'regular': 0.60, 'medium': 0.62, 'black': 0.65}[glyph_weight]
    point = int(size * ratio / 1.0)   # for SF Compact, point ~= rendered px roughly
    # PIL's FreeType loads at point size; rasterized px-height is ~70% of point.
    # Empirically: SF Compact Black at point=700 yields ~451px caps. We want ~62%.
    point = int(size * 0.66)   # 1024 → 676 px raster cap height

    font = load_font(point)

    # ---- Background ----
    if bg_kind == 'flat':
        bg = Image.new('RGB', (size, size), TONE_ACCENT)
    elif bg_kind == 'gradient':
        bg = Image.new('RGB', (size, size))
        # Vertical violet gradient: light top → accent mid → deep bottom
        top_rgb = TONE_LIGHT
        mid_rgb = TONE_ACCENT
        bot_rgb = TONE_DEEP
        px = bg.load()
        for y in range(size):
            t = y / (size - 1)
            if t < 0.5:
                k = t * 2
                r = int(top_rgb[0] + (mid_rgb[0] - top_rgb[0]) * k)
                g = int(top_rgb[1] + (mid_rgb[1] - top_rgb[1]) * k)
                b = int(top_rgb[2] + (mid_rgb[2] - top_rgb[2]) * k)
            else:
                k = (t - 0.5) * 2
                r = int(mid_rgb[0] + (bot_rgb[0] - mid_rgb[0]) * k)
                g = int(mid_rgb[1] + (bot_rgb[1] - mid_rgb[1]) * k)
                b = int(mid_rgb[2] + (bot_rgb[2] - mid_rgb[2]) * k)
            for x in range(size):
                px[x, y] = (r, g, b)
    elif bg_kind == 'gradient_gloss':
        # Same gradient + a subtle top highlight (8% white) for a polished material feel
        bg = Image.new('RGB', (size, size))
        top_rgb = TONE_LIGHT
        mid_rgb = TONE_ACCENT
        bot_rgb = TONE_DEEP
        px = bg.load()
        for y in range(size):
            t = y / (size - 1)
            if t < 0.5:
                k = t * 2
                r = int(top_rgb[0] + (mid_rgb[0] - top_rgb[0]) * k)
                g = int(top_rgb[1] + (mid_rgb[1] - top_rgb[1]) * k)
                b = int(top_rgb[2] + (mid_rgb[2] - top_rgb[2]) * k)
            else:
                k = (t - 0.5) * 2
                r = int(mid_rgb[0] + (bot_rgb[0] - mid_rgb[0]) * k)
                g = int(mid_rgb[1] + (bot_rgb[1] - mid_rgb[1]) * k)
                b = int(mid_rgb[2] + (bot_rgb[2] - mid_rgb[2]) * k)
            for x in range(size):
                px[x, y] = (r, g, b)
        # Add top highlight: 8% white overlay fading down 40% of icon
        overlay = Image.new('RGB', (size, size), (0, 0, 0))
        op = Image.new('L', (size, size), 0)
        opd = ImageDraw.Draw(op)
        for y in range(size):
            a = max(0, int(20 * (1 - y / (size * 0.4))))
            opd.line([(0, y), (size, y)], fill=a)
        bg = Image.composite(Image.new('RGB', (size, size), (255, 255, 255)), bg, op)
    else:
        raise ValueError(bg_kind)

    # Convert to RGBA for compositing the glyph with optional glow
    surface = bg.convert('RGBA')
    overlay = Image.new('RGBA', (size, size), (0, 0, 0, 0))

    # ---- Glyph ----
    # PIL's textbbox is the tight bounding box of the ink (excluding ascent whitespace)
    d = ImageDraw.Draw(overlay)
    l, t, r, b = measure_glyph(d, 't', font)
    gw, gh = r - l, b - t
    # Center the glyph in icon. optical centering: SF Compact 't' has more weight
    # at top of the cap, so nudge ~2% downward for visual balance.
    cx = size // 2
    cy = size // 2 + int(size * 0.015)
    x0 = cx - gw // 2 - l
    y0 = cy - gh // 2 - t
    d.text((x0, y0), 't', font=font, fill=glyph_color)

    # Optional soft glow halo behind glyph (candidate 4)
    if glow:
        alpha = overlay.split()[-1]
        blur = alpha.filter(ImageFilter.GaussianBlur(radius=size * 0.025))
        glow_color_img = Image.new('RGBA', (size, size), TONE_LIGHT + (0,))
        # Mask the colored layer with the blurred alpha and add to overlay
        glow_layer = Image.composite(
            Image.new('RGBA', (size, size), (255, 255, 255, 110)),
            Image.new('RGBA', (size, size), (0, 0, 0, 0)),
            blur,
        )
        overlay = Image.alpha_composite(overlay, glow_layer)

    # Composite glyph onto background
    final = Image.alpha_composite(surface, overlay)
    if return_surface:
        return final
    return final.convert('RGB')


def save_icon(im: Image.Image, path: str):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if im.mode != 'RGB':
        im = im.convert('RGB')
    im.save(path, 'PNG', optimize=True)


# ---------- CANDIDATES ----------
def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(PREVIEW_DIR, exist_ok=True)

    candidates = [
        # (filename, bg, glyph_color, glyph_weight, glow, label)
        ('candidate-A-regular-flat.png',     'flat',           (255, 255, 255), 'black',  False, 'A · flat · black'),
        ('candidate-B-medium-gradient.png',  'gradient',       (255, 255, 255), 'medium', False, 'B · gradient · medium'),
        ('candidate-C-regular-grad-gloss.png','gradient_gloss',(255, 255, 255), 'black',  False, 'C · gloss · black'),
        ('candidate-D-medium-flat-glow.png', 'flat',           (255, 255, 255), 'medium', True,  'D · flat · medium · glow'),
    ]

    rendered = {}
    for fn, bg, gc, gw, glow, label in candidates:
        im = render_icon(size=SZ, bg_kind=bg, glyph_color=gc,
                         glyph_weight=gw, glow=glow)
        path = os.path.join(OUT_DIR, fn)
        save_icon(im, path)
        rendered[label] = im
        print(f'wrote {path}  ({label})')

    # ---- Canonical 1024 — same direction as B (gradient, medium weight) ----
    # Why B: gradient matches the site's brand stickers and CTAs; medium weight
    # is the most legible at 60 px (home-screen size) — it survives downscaling
    # without becoming a blob (black gets too heavy) or a thread (regular too thin).
    canonical = render_icon(
        size=SZ, bg_kind='gradient', glyph_color=(255, 255, 255), glyph_weight='medium',
        glow=False,
    )
    canonical_path = os.path.join(ICONSET_DIR, 'icon-1024.png')
    save_icon(canonical, canonical_path)
    print(f'wrote {canonical_path}  (CANONICAL — same direction as B)')

    # ---- Mockup: 4-up at home-screen sizes (180 + 120 + 60 px) ----
    mock = Image.new('RGB', (1400, 1100), (10, 10, 14))
    d = ImageDraw.Draw(mock)
    # The wall is iPhone-ish, so background is near-black (matches FORT dark)

    # Header
    head_font = load_font(36)
    sub_font  = load_font(22)
    d.text((40, 30),  'Tono · App Icon — candidates', font=head_font, fill=(255, 255, 255))
    d.text((40, 80),  'lowercase "t" on web purple (#A855F7) — palette from tonoit.com',
           font=sub_font, fill=(160, 160, 180))

    # Render each candidate at 360 (large preview) + 120 (home-screen) + 60 (realsize)
    y = 150
    for fn, bg, gc, gw, glow, label in candidates:
        im = render_icon(size=SZ, bg_kind=bg, glyph_color=gc,
                         glyph_weight=gw, glow=glow)
        big = im.resize((240, 240), Image.LANCZOS)
        mid = im.resize((120, 120), Image.LANCZOS)
        sm  = im.resize((60, 60),  Image.LANCZOS)
        mock.paste(big, (40,  y))
        mock.paste(mid, (320, y + 60))
        mock.paste(sm,  (470, y + 90))
        d.text((560, y + 30), label, font=load_font(28), fill=(255, 255, 255))
        d.text((560, y + 70), '240 px         120 px         60 px',
               font=load_font(18), fill=(140, 140, 160))
        y += 240

    mock_path = os.path.join(PREVIEW_DIR, 'icon-candidates-mockup.png')
    save_icon(mock, mock_path)
    print(f'wrote {mock_path}')

    # ---- Legibility contact sheet: ALL 4 at 180 / 120 / 60 / 40 ----
    sheet = Image.new('RGB', (1600, 720), (10, 10, 14))
    sd = ImageDraw.Draw(sheet)
    sd.text((40, 24), 'Legibility test — same glyph across 4 size classes',
            font=load_font(32), fill=(255, 255, 255))
    sd.text((40, 64), '180 (Settings tile) · 120 (large folder) · 60 (home) · 40 (small)',
            font=load_font(20), fill=(160, 160, 180))
    sizes = [180, 120, 60, 40]
    x = 40
    for s in sizes:
        x0 = x
        yy = 130
        for fn, bg, gc, gw, glow, label in candidates:
            im = render_icon(size=SZ, bg_kind=bg, glyph_color=gc,
                             glyph_weight=gw, glow=glow)
            r = im.resize((s, s), Image.LANCZOS)
            sheet.paste(r, (x0, yy))
            yy += s + 12
        x = x0 + max(sizes) + 40
    sheet_path = os.path.join(PREVIEW_DIR, 'icon-legibility-sheet.png')
    save_icon(sheet, sheet_path)
    print(f'wrote {sheet_path}')

    print('\nDONE')


if __name__ == '__main__':
    main()
