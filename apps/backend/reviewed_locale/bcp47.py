"""Fail-closed BCP-47 / RFC 5646 language-tag validation.

Enough of the RFC 5646 grammar to gate a reviewed locale, with two properties
the naive "split on '-' and eyeball it" approach misses:

* **extlang prefix validation** -- an extlang subtag (e.g. ``yue``) is only
  well-formed after its registered prefix (``zh``). ``zh-yue`` is valid;
  ``en-yue`` is *not*, because Cantonese is not an extension of English.
* **fail-closed** -- duplicate variants, duplicate singleton extensions,
  private-use-only tags, unknown extlangs, and non-ASCII / control characters
  are all rejected rather than tolerated. Extension order is preserved (we do
  not perform the RFC 5646 section 4.5 canonical reordering).

Pure standard library; no side effects on import.

The extlang table is a curated subset of the IANA Language Subtag Registry
(the full registry cannot be fetched here -- no network). It is sufficient to
distinguish a valid extlang+prefix pair from an invalid one; an extlang outside
the table is rejected fail-closed.
"""

from __future__ import annotations

import re
from typing import Dict, List, NamedTuple, Tuple


class Bcp47Error(ValueError):
    """Raised when a tag is not a well-formed / valid language tag."""


# Curated extlang -> required prefix map (subset of the IANA registry).
EXTLANG_PREFIX: Dict[str, str] = {
    # Sinitic (macrolanguage zh)
    "yue": "zh", "cmn": "zh", "nan": "zh", "hak": "zh", "wuu": "zh",
    "hsn": "zh", "gan": "zh", "lzh": "zh", "cjy": "zh", "cdo": "zh",
    "cpx": "zh", "czo": "zh", "mnp": "zh",
    # Arabic (macrolanguage ar)
    "arb": "ar", "apc": "ar", "ary": "ar", "arz": "ar", "acm": "ar",
    "afb": "ar", "ajp": "ar", "apd": "ar", "ars": "ar",
    # Malay (macrolanguage ms)
    "zsm": "ms", "btj": "ms",
    # Uzbek / Azerbaijani / Swahili
    "uzn": "uz", "uzs": "uz", "azb": "az", "azj": "az",
    "swc": "sw", "swh": "sw",
    # Sign languages (macrolanguage sgn)
    "ase": "sgn", "bfi": "sgn", "gsg": "sgn", "fsl": "sgn",
}

_ALPHA = re.compile(r"^[A-Za-z]+$")
_DIGIT = re.compile(r"^[0-9]+$")
_ALNUM = re.compile(r"^[0-9A-Za-z]+$")
_TAG_CHARS = re.compile(r"^[A-Za-z0-9-]+$")


class LangTag(NamedTuple):
    language: str
    extlang: Tuple[str, ...]
    script: str
    region: str
    variants: Tuple[str, ...]
    extensions: Tuple[Tuple[str, Tuple[str, ...]], ...]
    privateuse: Tuple[str, ...]


def _is_alpha(s: str, lo: int, hi: int) -> bool:
    return lo <= len(s) <= hi and bool(_ALPHA.match(s))


def _is_variant(s: str) -> bool:
    if len(s) >= 5 and len(s) <= 8 and _ALNUM.match(s):
        return True
    if len(s) == 4 and s[0].isdigit() and bool(_ALNUM.match(s)):
        return True
    return False


def parse(tag: str) -> LangTag:
    """Parse and validate *tag*; raise :class:`Bcp47Error` if invalid."""
    if not isinstance(tag, str):
        raise Bcp47Error("tag must be a string")
    if not tag:
        raise Bcp47Error("empty tag")
    if not _TAG_CHARS.match(tag):
        # Rejects control characters, whitespace, and any non-ASCII byte.
        raise Bcp47Error("tag contains characters outside [A-Za-z0-9-]")
    if tag.startswith("-") or tag.endswith("-") or "--" in tag:
        raise Bcp47Error("empty subtag")

    subtags = tag.split("-")

    # Private-use-only tags (x-...) name no language; reject for a locale.
    if subtags[0].lower() == "x":
        raise Bcp47Error("private-use-only tag has no language")

    pos = 0

    # ---- language ----
    language = subtags[pos]
    if _is_alpha(language, 2, 3):
        allows_extlang = True
    elif _is_alpha(language, 4, 4):
        allows_extlang = False  # reserved
    elif _is_alpha(language, 5, 8):
        allows_extlang = False  # registered
    else:
        raise Bcp47Error("invalid primary language subtag: %r" % language)
    pos += 1

    # ---- extlang(s) ---- only 3ALPHA subtags, only after a 2-3 alpha language.
    extlang: List[str] = []
    while pos < len(subtags) and _is_alpha(subtags[pos], 3, 3):
        candidate = subtags[pos].lower()
        if not allows_extlang:
            raise Bcp47Error(
                "extlang %r not allowed after language %r" % (candidate, language)
            )
        if len(extlang) >= 3:
            raise Bcp47Error("too many extlang subtags")
        if candidate not in EXTLANG_PREFIX:
            raise Bcp47Error("unknown extlang subtag: %r" % candidate)
        required_prefix = EXTLANG_PREFIX[candidate]
        if language.lower() != required_prefix:
            raise Bcp47Error(
                "extlang %r requires prefix %r, got language %r"
                % (candidate, required_prefix, language)
            )
        extlang.append(candidate)
        # After the first extlang, only further extlangs may follow (a valid
        # tag never has more than one in practice); the loop keeps checking.
        allows_extlang = True
        pos += 1

    # ---- script ---- 4ALPHA
    script = ""
    if pos < len(subtags) and _is_alpha(subtags[pos], 4, 4):
        script = subtags[pos]
        pos += 1

    # ---- region ---- 2ALPHA or 3DIGIT
    region = ""
    if pos < len(subtags):
        s = subtags[pos]
        if _is_alpha(s, 2, 2) or (len(s) == 3 and _DIGIT.match(s)):
            region = s
            pos += 1

    # ---- variants ---- reject duplicates
    variants: List[str] = []
    while pos < len(subtags) and _is_variant(subtags[pos]):
        v = subtags[pos].lower()
        if v in variants:
            raise Bcp47Error("duplicate variant subtag: %r" % v)
        variants.append(v)
        pos += 1

    # ---- extensions ---- singleton (not x) then 1*(2*8alnum); reject dup singletons
    extensions: List[Tuple[str, Tuple[str, ...]]] = []
    seen_singletons: List[str] = []
    while pos < len(subtags) and len(subtags[pos]) == 1 and subtags[pos].lower() != "x":
        singleton = subtags[pos].lower()
        if not _ALNUM.match(singleton):
            raise Bcp47Error("invalid extension singleton: %r" % singleton)
        if singleton in seen_singletons:
            raise Bcp47Error("duplicate extension singleton: %r" % singleton)
        seen_singletons.append(singleton)
        pos += 1
        ext_parts: List[str] = []
        while pos < len(subtags) and 2 <= len(subtags[pos]) <= 8 and _ALNUM.match(subtags[pos]):
            ext_parts.append(subtags[pos].lower())
            pos += 1
        if not ext_parts:
            raise Bcp47Error("extension %r has no subtags" % singleton)
        extensions.append((singleton, tuple(ext_parts)))

    # ---- private use ---- x 1*(1*8alnum)
    privateuse: List[str] = []
    if pos < len(subtags) and subtags[pos].lower() == "x":
        pos += 1
        while pos < len(subtags) and 1 <= len(subtags[pos]) <= 8 and _ALNUM.match(subtags[pos]):
            privateuse.append(subtags[pos].lower())
            pos += 1
        if not privateuse:
            raise Bcp47Error("private-use sequence has no subtags")

    if pos != len(subtags):
        raise Bcp47Error("unparsed subtag(s) starting at: %r" % subtags[pos])

    return LangTag(
        language=language.lower(),
        extlang=tuple(extlang),
        script=script,
        region=region,
        variants=tuple(variants),
        extensions=tuple(extensions),
        privateuse=tuple(privateuse),
    )


def is_valid(tag: str) -> bool:
    """Return True iff *tag* is a well-formed, valid language tag."""
    try:
        parse(tag)
        return True
    except Bcp47Error:
        return False
