#!/usr/bin/env python3
"""Render deterministic Coach geometry/state/palette regression evidence."""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

SCALE = 3
COACH_SIZE = (96, 44)
AXES = (
    ("Warmer", "#B4234D", "#FF6B8A"),
    ("Clearer", "#006A8E", "#49C7F2"),
    ("Funnier", "#7A5100", "#FFC247"),
    ("Safer", "#147A36", "#4CD471"),
)
OUT = Path(__file__).resolve().parents[3] / "artifacts" / "t_95f18bce-coach"


def font(size: int, bold: bool = False):
    names = (
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/SFNSRounded.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    )
    for name in names:
        try:
            return ImageFont.truetype(name, size * SCALE, index=1 if bold else 0)
        except (OSError, IndexError):
            pass
    return ImageFont.load_default()


def box(values):
    return tuple(round(value * SCALE) for value in values)


def point(x, y):
    return round(x * SCALE), round(y * SCALE)


def rounded(draw, values, radius, fill, outline=None):
    draw.rounded_rectangle(box(values), radius=radius * SCALE, fill=fill, outline=outline, width=SCALE)


def centered(draw, values, text, fill, text_font):
    bounds = box(values)
    text_bounds = draw.textbbox((0, 0), text, font=text_font)
    width = text_bounds[2] - text_bounds[0]
    height = text_bounds[3] - text_bounds[1]
    x = (bounds[0] + bounds[2] - width) / 2
    y = (bounds[1] + bounds[3] - height) / 2 - SCALE
    draw.text((x, y), text, fill=fill, font=text_font)


def canvas(width, height, dark):
    background = "#1C1C1E" if dark else "#D1D4DA"
    return Image.new("RGB", (width * SCALE, height * SCALE), background)


def render_control_state(name, title, state, dark, width):
    image = canvas(width, 112, dark)
    draw = ImageDraw.Draw(image)
    label = "#FFFFFF" if dark else "#111111"
    neutral = "#3A3A3C" if dark else "#FFFFFF"
    outline = "#696A6E" if dark else "#B8BBC1"
    colors = {
        "normal": "#8D4CB3" if dark else "#5E1F78",
        "pressed": "#713090" if dark else "#451258",
        "disabled": "#76617D",
    }
    draw.text(point(12, 10), f"{name} · {width}pt", fill=label, font=font(13, bold=True))
    rounded(draw, (8, 54, width - 112, 98), 5, neutral, outline)
    centered(draw, (8, 54, width - 112, 98), "suggestion   strip", label, font(13))
    left = width - 104
    top = 54
    rounded(draw, (left, top, left + COACH_SIZE[0], top + COACH_SIZE[1]), 5, colors[state])
    centered(draw, (left, top, left + COACH_SIZE[0], top + COACH_SIZE[1]), title, "#FFFFFF", font(16, bold=True))
    image.save(OUT / f"{name}.png")
    return image


def render_results():
    width, height = 402, 300
    image = canvas(width, height, dark=True)
    draw = ImageDraw.Draw(image)
    draw.text(point(12, 10), "Coach results · approved four-axis palette", fill="#FFFFFF", font=font(13, bold=True))
    y = 42
    for label, _, dark_color in AXES:
        rounded(draw, (8, y, width - 8, y + 56), 5, "#8D4CB3", "#696A6E")
        draw.ellipse(box((18, y + 12, 28, y + 22)), fill=dark_color)
        draw.text(point(34, y + 8), label, fill=dark_color, font=font(12, bold=True))
        draw.text(point(18, y + 29), f"{label} rewrite stays visibly distinct", fill="#FFFFFF", font=font(13))
        y += 62
    image.save(OUT / "results-four-axis-dark.png")
    return image


def contact_sheet(images):
    thumb_width = 402
    row_heights = (112, 300)
    sheet = Image.new("RGB", (thumb_width * 2 * SCALE, sum(row_heights) * SCALE), "#111111")
    for index, image in enumerate(images):
        fitted = image.copy()
        row = index // 2
        fitted.thumbnail((thumb_width * SCALE, row_heights[row] * SCALE))
        x = (index % 2) * thumb_width * SCALE
        y = sum(row_heights[:row]) * SCALE
        sheet.paste(fitted, (x, y))
    sheet.save(OUT / "coach-state-contact-sheet.png")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    images = [
        render_control_state("normal-light-compact", "Coach", "normal", False, 320),
        render_control_state("pressed-dark", "Coach", "pressed", True, 402),
        render_control_state("disabled-loading-light", "Coach", "disabled", False, 402),
        render_results(),
    ]
    contact_sheet(images)
    for path in sorted(OUT.glob("*.png")):
        print(path)


if __name__ == "__main__":
    main()
