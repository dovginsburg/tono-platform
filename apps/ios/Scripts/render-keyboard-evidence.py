#!/usr/bin/env python3
"""Render deterministic Tono keyboard visual-spec evidence in light/dark modes."""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

WIDTH = 402
HEIGHT = 256
RESULTS_HEIGHT = 292
SECTION_GAP = 12
CANVAS_HEIGHT = HEIGHT + SECTION_GAP + RESULTS_HEIGHT
SCALE = 3
TOP_BAR = 46
EDGE = 4
ROW_GAP = 8
KEY_HEIGHT = 44
KEY_RADIUS = 5
COACH_HEIGHT = 36
LETTERS = [list("QWERTYUIOP"), list("ASDFGHJKL"), list("ZXCVBNM")]


def font(size: int):
    for path in (
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/SFNSRounded.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ):
        try:
            return ImageFont.truetype(path, size * SCALE)
        except OSError:
            pass
    return ImageFont.load_default()


def rounded(draw, box, radius, fill, outline=None, width=1):
    draw.rounded_rectangle(
        tuple(int(v * SCALE) for v in box),
        radius=radius * SCALE,
        fill=fill,
        outline=outline,
        width=width * SCALE,
    )


def centered(draw, box, text, fill, text_font):
    scaled = tuple(int(v * SCALE) for v in box)
    bounds = draw.textbbox((0, 0), text, font=text_font)
    x = (scaled[0] + scaled[2] - (bounds[2] - bounds[0])) / 2
    y = (scaled[1] + scaled[3] - (bounds[3] - bounds[1])) / 2 - 2 * SCALE
    draw.text((x, y), text, fill=fill, font=text_font)


def draw_coach_results(draw, origin_y, *, background, label, border, coach, pressed, disabled):
    """Render the expanded Coach state with all four canonical choices.

    The second state intentionally includes normal, pressed/selected, and
    disabled controls so the evidence covers every branded interaction state.
    """
    draw.rectangle(
        (0, origin_y * SCALE, WIDTH * SCALE, (origin_y + RESULTS_HEIGHT) * SCALE),
        fill=background,
    )
    title_font = font(14)
    axis_font = font(11)
    body_font = font(12)
    state_font = font(9)

    draw.text((12 * SCALE, (origin_y + 7) * SCALE), "Tono · Looks okay", fill=label, font=title_font)
    draw.text((352 * SCALE, (origin_y + 7) * SCALE), "Back", fill=label, font=title_font)

    choices = [
        ("Warmer", "Thanks for checking — could you help with this?", coach, "normal"),
        ("Clearer", "Please send the revised draft by 3 PM.", pressed, "pressed"),
        ("Funnier", "Tiny plot twist: can we move this to Friday?", coach, "normal"),
        ("Safer", "Would you be open to reviewing this together?", disabled, "disabled"),
    ]
    y = origin_y + 40
    card_height = 57
    for axis, rewrite, fill, state in choices:
        rounded(draw, (EDGE, y, WIDTH - EDGE, y + card_height), KEY_RADIUS, fill, border)
        draw.text((14 * SCALE, (y + 5) * SCALE), f"● {axis}", fill="#FFFFFF", font=axis_font)
        state_box = draw.textbbox((0, 0), state, font=state_font)
        state_width = state_box[2] - state_box[0]
        draw.text(
            ((WIDTH - 14) * SCALE - state_width, (y + 6) * SCALE),
            state,
            fill="#FFFFFF",
            font=state_font,
        )
        draw.text((14 * SCALE, (y + 26) * SCALE), rewrite, fill="#FFFFFF", font=body_font)
        y += card_height + 4


def render(name: str, dark: bool):
    background = "#1C1C1E" if dark else "#D1D4DA"
    key = "#55565A" if dark else "#FFFFFF"
    control = "#3A3A3C" if dark else "#B4B7BC"
    label = "#FFFFFF" if dark else "#000000"
    border = "#696A6E" if dark else "#C3C5C9"
    coach = "#8D4CB3" if dark else "#5E1F78"
    coach_pressed = "#713090" if dark else "#451258"
    coach_disabled = "#76617D"

    image = Image.new("RGB", (WIDTH * SCALE, CANVAS_HEIGHT * SCALE), background)
    draw = ImageDraw.Draw(image)
    key_font = font(22)
    control_font = font(15)
    coach_font = font(16)

    # Candidate strip stays Apple/system neutral. Only Coach carries the brand.
    rounded(draw, (EDGE, 5, 285, 41), KEY_RADIUS, key, border)
    centered(draw, (EDGE, 5, 285, 41), "synthetic   message   text", label, control_font)
    rounded(draw, (294, 5, 394, 41), KEY_RADIUS, coach)
    centered(draw, (294, 5, 394, 41), "Coach", "#FFFFFF", coach_font)

    y = TOP_BAR + 2
    for row_index, chars in enumerate(LETTERS):
        if row_index == 0:
            left, right = EDGE, WIDTH - EDGE
        elif row_index == 1:
            row1_width = (WIDTH - EDGE * 2 - ROW_GAP * 9) / 10
            inset = (row1_width + ROW_GAP) / 2
            left, right = EDGE + inset, WIDTH - EDGE - inset
        else:
            left, right = 58, WIDTH - 58
        gap = ROW_GAP
        key_width = (right - left - gap * (len(chars) - 1)) / len(chars)
        for index, char in enumerate(chars):
            x = left + index * (key_width + gap)
            rounded(draw, (x, y, x + key_width, y + KEY_HEIGHT), KEY_RADIUS, key, border)
            centered(draw, (x, y, x + key_width, y + KEY_HEIGHT), char, label, key_font)
        if row_index == 2:
            rounded(draw, (EDGE, y, 52, y + KEY_HEIGHT), KEY_RADIUS, control, border)
            centered(draw, (EDGE, y, 52, y + KEY_HEIGHT), "⇧", label, key_font)
            rounded(draw, (WIDTH - 52, y, WIDTH - EDGE, y + KEY_HEIGHT), KEY_RADIUS, control, border)
            centered(draw, (WIDTH - 52, y, WIDTH - EDGE, y + KEY_HEIGHT), "⌫", label, key_font)
        y += KEY_HEIGHT + ROW_GAP

    rounded(draw, (EDGE, y, 50, y + KEY_HEIGHT), KEY_RADIUS, control, border)
    centered(draw, (EDGE, y, 50, y + KEY_HEIGHT), "123", label, control_font)
    rounded(draw, (56, y, 98, y + KEY_HEIGHT), KEY_RADIUS, control, border)
    centered(draw, (56, y, 98, y + KEY_HEIGHT), ":-)", label, control_font)
    rounded(draw, (104, y, 320, y + KEY_HEIGHT), KEY_RADIUS, key, border)
    centered(draw, (104, y, 320, y + KEY_HEIGHT), "space", label, control_font)
    rounded(draw, (326, y, WIDTH - EDGE, y + KEY_HEIGHT), KEY_RADIUS, control, border)
    centered(draw, (326, y, WIDTH - EDGE, y + KEY_HEIGHT), "return", label, control_font)

    draw_coach_results(
        draw,
        HEIGHT + SECTION_GAP,
        background=background,
        label=label,
        border=border,
        coach=coach,
        pressed=coach_pressed,
        disabled=coach_disabled,
    )

    output = Path(__file__).resolve().parents[3] / "artifacts" / name
    output.parent.mkdir(parents=True, exist_ok=True)
    image.save(output)
    print(output)


if __name__ == "__main__":
    render("t_6b06eaaa-tono-keyboard-spec-light.png", dark=False)
    render("t_6b06eaaa-tono-keyboard-spec-dark.png", dark=True)
