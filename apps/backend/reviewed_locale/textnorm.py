"""Obfuscation-resistant text normalization for the forbidden-token gate.

A naive ``token in text`` check is trivially defeated: ``s.u.i.c.i.d.e``,
``su<zero-width-space>icide``, fullwidth ``９８８``, or Cyrillic homoglyphs all
sail through. This module reduces text to a canonical *skeleton* so those
evasions collapse onto the token they are hiding.

Pure standard library (``unicodedata`` + ``re``); no side effects on import.
"""

from __future__ import annotations

import re
import unicodedata
from typing import List

# Characters that carry no visible glyph but are commonly injected to break up
# a word: zero-width spaces/joiners, the BOM/word-joiner, the soft hyphen, and
# the bidirectional / isolate controls. NFKC does not remove these, so we strip
# them explicitly. (Unicode general category "Cf" plus a couple of specials.)
_ZERO_WIDTH = {
    "­",  # SOFT HYPHEN
    "​",  # ZERO WIDTH SPACE
    "‌",  # ZERO WIDTH NON-JOINER
    "‍",  # ZERO WIDTH JOINER
    "⁠",  # WORD JOINER
    "⁡",  # FUNCTION APPLICATION
    "⁢",  # INVISIBLE TIMES
    "⁣",  # INVISIBLE SEPARATOR
    "⁤",  # INVISIBLE PLUS
    "﻿",  # ZERO WIDTH NO-BREAK SPACE / BOM
    "‪",  # LRE
    "‫",  # RLE
    "‬",  # PDF
    "‭",  # LRO
    "‮",  # RLO
    "⁦",  # LRI
    "⁧",  # RLI
    "⁨",  # FSI
    "⁩",  # PDI
}

# Confusable homoglyph folding. NFKC already folds fullwidth/compatibility
# forms, so this table only needs the cross-script look-alikes and leetspeak
# that NFKC leaves alone. Values are always lowercase ASCII.
_CONFUSABLES = {
    # Cyrillic -> Latin look-alikes
    "а": "a", "е": "e", "о": "o", "р": "p",
    "с": "c", "х": "x", "у": "y", "і": "i",
    "ѕ": "s", "к": "k", "м": "m", "т": "t",
    "н": "h", "в": "b", "г": "r", "п": "n",
    # Greek -> Latin look-alikes
    "ο": "o", "α": "a", "ε": "e", "ρ": "p",
    "ν": "v", "υ": "u", "ι": "i", "τ": "t",
    "κ": "k", "χ": "x",
    # Dotless i and a couple of Latin extendeds used to dodge filters
    "ı": "i", "ł": "l",
    # Leetspeak
    "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t",
    "@": "a", "$": "s", "!": "i", "|": "i",
}

# Separators tolerated *between digits* when reconstructing a numeric token.
_DIGIT_SEPARATORS = set(" .-_,/·–—\t")


def strip_ignorables(text: str) -> str:
    """Remove zero-width / bidi controls and combining marks."""
    out: List[str] = []
    for ch in text:
        if ch in _ZERO_WIDTH:
            continue
        cat = unicodedata.category(ch)
        if cat in ("Mn", "Me", "Cf"):
            # Combining marks and format chars: drop (diacritics folded away).
            continue
        out.append(ch)
    return "".join(out)


def word_skeleton(text: str) -> str:
    """Collapse *text* to a lowercase alphanumeric skeleton.

    NFKC-fold, strip ignorables, casefold, apply confusable/leet folding, then
    keep only ``[a-z0-9]``. ``S.U.I​C.I.D.E`` and ``ѕu1cide`` both become
    ``suicide``.
    """
    text = unicodedata.normalize("NFKC", text)
    text = strip_ignorables(text)
    text = text.casefold()
    folded: List[str] = []
    for ch in text:
        folded.append(_CONFUSABLES.get(ch, ch))
    text = "".join(folded)
    return re.sub(r"[^a-z0-9]+", "", text)


def contains_word_skeleton(text: str, token: str) -> bool:
    """True if *token*'s skeleton appears inside *text*'s skeleton."""
    tok = word_skeleton(token)
    if not tok:
        return False
    return tok in word_skeleton(text)


def digit_runs(text: str) -> List[str]:
    """Return separator-tolerant digit runs.

    ``9-8-8`` -> ``["988"]``; ``1988`` -> ``["1988"]``; ``call 988 or 911``
    -> ``["988", "911"]``. A run is a maximal span of digits joined only by
    "light" separators; any other character (letter, ``(``, ``+`` ...) breaks
    the run, so ``988`` is recovered with exact numeric boundaries.
    """
    text = unicodedata.normalize("NFKC", text)
    text = strip_ignorables(text)
    runs: List[str] = []
    current: List[str] = []
    pending_sep = False
    for ch in text:
        if ch.isdigit():
            # An ASCII/Unicode decimal digit. NFKC has already mapped fullwidth
            # forms to 0-9; normalize any remaining Unicode digit to its value.
            digit = unicodedata.digit(ch, None)
            current.append(str(digit) if digit is not None else ch)
            pending_sep = False
        elif ch in _DIGIT_SEPARATORS and current:
            # Tolerate a separator only *between* digits; remember we saw one
            # but do not let a trailing separator keep the run open forever.
            pending_sep = True
        else:
            if current:
                runs.append("".join(current))
            current = []
            pending_sep = False
    if current:
        runs.append("".join(current))
    _ = pending_sep  # explicit: trailing separators are irrelevant
    return runs


def contains_numeric_token(text: str, token: str) -> bool:
    """True if *token* appears as a bounded, separator-tolerant digit run."""
    return token in digit_runs(text)
