"""Report-only output-hygiene validator for Social Tone Coach responses.

This module is a *stdlib-only*, *hard-default-off*, *report-only* validator. It
is deliberately standalone: nothing in the product imports it, and it imports
nothing from the backend package (so it never drags in httpx/fastapi/pydantic).
The only importer is ``tests/test_coach_output_hygiene.py``.

What it checks (only when a caller explicitly passes ``enabled=True``):

1. The banned *tool-narration* phrases from ``SYSTEM_PROMPT`` rule 5 in
   ``backend/analyze.py`` -- verbatim: "based on", "I checked", "looking at",
   "my read" -- appearing in the coach-*authored* fields ``perception``,
   ``subtext``, ``risk_reason`` and each ``suggestions[i].rationale``. The
   rewrite itself (``suggestions[i].text``, or any top-level ``rewrite``) is
   NEVER scanned or altered.
2. ``risk_reason`` must be at most 12 Unicode words.

It never raises and never mutates its input; malformed payloads simply yield no
findings for the parts that cannot be read (mirroring the defensive ``.get`` /
``str`` / ``isinstance`` style of ``enforce_coach_contract`` in the baseline).
There is no runtime wiring and no ambient/env switch -- "hard default off" means
a caller must opt in per call.

Unicode contract
----------------
Obfuscation and seam handling rely on the Unicode *Default_Ignorable_Code_Point*
(DICP) derived property, pinned below as an explicit range table for a single,
recorded Unicode version. The table is NOT approximated by General_Category=Cf;
it includes the non-Cf members (e.g. U+034F, U+FE0F, U+E0100) exactly as the
official data lists them.

* Unicode version : 13.0.0
* Source          : https://www.unicode.org/Public/13.0.0/ucd/DerivedCoreProperties.txt
* Source SHA-256  : a5d45f59b39deaab3c72ce8c1a2e212a5e086dff11b1f9d5bb0e352642e82248
* Member count    : 4173

The focused test fetches that official file (into untracked
``controller-artifacts/``), parses ``Default_Ignorable_Code_Point`` independently
of this table, and proves exact set equality plus a complete-property sweep.

Boundary semantics
------------------
Two distinct rules -- deliberately NOT one shared soft boundary:

* Phrase-INTERNAL (lenient), in :func:`_match_phrase_at`: default-ignorables may
  vanish between the characters of a word, and an inter-word seam is one-or-more
  soft separators (default-ignorable, whitespace, or Unicode dash). A glued
  (empty) seam does not match.
* OUTER start/end (strict), in :func:`_left_boundary_ok` / :func:`_right_boundary_ok`:
  a phrase edge is valid only at a true string edge, or against a character that
  does not continue the token. Token content is letters, digits and combining
  marks; default-ignorables are transparent (looked *through*, never counted as
  an edge). So a default-ignorable-only gap -- and, likewise, a bare combining
  mark -- can NEVER fabricate an outer edge inside a larger token, while real
  separators (whitespace, dashes) and ordinary punctuation/symbols legitimately
  delimit the phrase.
"""

from __future__ import annotations

import unicodedata
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any, Optional

__all__ = [
    "Finding",
    "scan_coach_output",
    "is_default_ignorable",
    "BANNED_TOOL_NARRATION_PHRASES",
    "BANNED_TOOL_NARRATION_CODE",
    "RISK_REASON_WORD_LIMIT_CODE",
    "RISK_REASON_MAX_WORDS",
    "COACH_AUTHORED_TEXT_FIELDS",
    "DEFAULT_IGNORABLE_RANGES",
    "UNICODE_VERSION",
    "DERIVED_CORE_PROPERTIES_URL",
    "DERIVED_CORE_PROPERTIES_SHA256",
]


# --------------------------------------------------------------------------- #
# Unicode Default_Ignorable_Code_Point (Unicode 13.0.0), pinned explicitly.
# --------------------------------------------------------------------------- #
UNICODE_VERSION = "13.0.0"
DERIVED_CORE_PROPERTIES_URL = (
    "https://www.unicode.org/Public/13.0.0/ucd/DerivedCoreProperties.txt"
)
DERIVED_CORE_PROPERTIES_SHA256 = (
    "a5d45f59b39deaab3c72ce8c1a2e212a5e086dff11b1f9d5bb0e352642e82248"
)

# One entry per line of the official file's Default_Ignorable_Code_Point block,
# transcribed verbatim (26 ranges, 4173 code points). Inclusive [lo, hi].
DEFAULT_IGNORABLE_RANGES: "tuple[tuple[int, int], ...]" = (
    (0x00AD, 0x00AD),    # SOFT HYPHEN (Cf)
    (0x034F, 0x034F),    # COMBINING GRAPHEME JOINER (Mn, non-Cf)
    (0x061C, 0x061C),    # ARABIC LETTER MARK (Cf)
    (0x115F, 0x1160),    # HANGUL CHOSEONG/JUNGSEONG FILLER (Lo, non-Cf)
    (0x17B4, 0x17B5),    # KHMER VOWEL INHERENT AQ..AA (Mn, non-Cf)
    (0x180B, 0x180D),    # MONGOLIAN FREE VARIATION SELECTOR ONE..THREE (Mn)
    (0x180E, 0x180E),    # MONGOLIAN VOWEL SEPARATOR (Cf)
    (0x200B, 0x200F),    # ZERO WIDTH SPACE..RIGHT-TO-LEFT MARK (Cf)
    (0x202A, 0x202E),    # LEFT-TO-RIGHT EMBEDDING..RIGHT-TO-LEFT OVERRIDE (Cf)
    (0x2060, 0x2064),    # WORD JOINER..INVISIBLE PLUS (Cf)
    (0x2065, 0x2065),    # <reserved-2065> (Cn, non-Cf)
    (0x2066, 0x206F),    # LEFT-TO-RIGHT ISOLATE..NOMINAL DIGIT SHAPES (Cf)
    (0x3164, 0x3164),    # HANGUL FILLER (Lo, non-Cf)
    (0xFE00, 0xFE0F),    # VARIATION SELECTOR-1..16 (Mn, non-Cf)
    (0xFEFF, 0xFEFF),    # ZERO WIDTH NO-BREAK SPACE (Cf)
    (0xFFA0, 0xFFA0),    # HALFWIDTH HANGUL FILLER (Lo, non-Cf)
    (0xFFF0, 0xFFF8),    # <reserved-FFF0..FFF8> (Cn, non-Cf)
    (0x1BCA0, 0x1BCA3),  # SHORTHAND FORMAT LETTER OVERLAP..UP STEP (Cf)
    (0x1D173, 0x1D17A),  # MUSICAL SYMBOL BEGIN BEAM..END PHRASE (Cf)
    (0xE0000, 0xE0000),  # <reserved-E0000> (Cn, non-Cf)
    (0xE0001, 0xE0001),  # LANGUAGE TAG (Cf)
    (0xE0002, 0xE001F),  # <reserved-E0002..E001F> (Cn, non-Cf)
    (0xE0020, 0xE007F),  # TAG SPACE..CANCEL TAG (Cf)
    (0xE0080, 0xE00FF),  # <reserved-E0080..E00FF> (Cn, non-Cf)
    (0xE0100, 0xE01EF),  # VARIATION SELECTOR-17..256 (Mn, non-Cf)
    (0xE01F0, 0xE0FFF),  # <reserved-E01F0..E0FFF> (Cn, non-Cf)
)

_DEFAULT_IGNORABLE_CODE_POINTS = frozenset(
    cp for lo, hi in DEFAULT_IGNORABLE_RANGES for cp in range(lo, hi + 1)
)


def is_default_ignorable(ch: str) -> bool:
    """True if the single character *ch* is a Unicode 13.0.0 default-ignorable."""
    return len(ch) == 1 and ord(ch) in _DEFAULT_IGNORABLE_CODE_POINTS


# --------------------------------------------------------------------------- #
# Policy constants.
# --------------------------------------------------------------------------- #
# Verbatim from SYSTEM_PROMPT rule 5 in backend/analyze.py:
#   'NEVER use "based on", "I checked", "looking at", "my read", or any
#    tool-narration filler.'
BANNED_TOOL_NARRATION_PHRASES = ("based on", "I checked", "looking at", "my read")

# Coach-authored free-text fields that ARE scanned. The rewrite text
# (suggestions[i].text) and any top-level "rewrite" are intentionally excluded.
COACH_AUTHORED_TEXT_FIELDS = ("perception", "subtext", "risk_reason")
_RISK_REASON_FIELD = "risk_reason"
RISK_REASON_MAX_WORDS = 12

BANNED_TOOL_NARRATION_CODE = "banned_tool_narration"
RISK_REASON_WORD_LIMIT_CODE = "risk_reason_word_limit"


@dataclass(frozen=True)
class Finding:
    """One report-only hygiene finding. Never raised; only collected."""

    field: str   # "perception" | "subtext" | "risk_reason" | "suggestions[i].rationale"
    code: str    # BANNED_TOOL_NARRATION_CODE | RISK_REASON_WORD_LIMIT_CODE
    detail: str  # canonical banned phrase, or a word-count explanation


# --------------------------------------------------------------------------- #
# Deterministic normalization.
# --------------------------------------------------------------------------- #
def _fold(text: str) -> str:
    """Deterministic compatibility caseless fold: NFKC(casefold(NFKC(text))).

    Default-ignorables survive this fold (they have no case mapping, and any
    NFKC decomposition of a DICP member -- e.g. U+FFA0 -> U+3164 -- maps to
    another DICP member), so seam/obfuscation reasoning is preserved.
    """
    return unicodedata.normalize(
        "NFKC", unicodedata.normalize("NFKC", text).casefold()
    )


def _is_default_ignorable_cp(ch: str) -> bool:
    return ord(ch) in _DEFAULT_IGNORABLE_CODE_POINTS


def _is_hard_separator(ch: str) -> bool:
    """A *real* separator: whitespace or Unicode dash punctuation (Pd).

    Disjoint from the default-ignorable set (DICP excludes White_Space and
    contains no Pd members), so a hard separator is never an ignorable.
    """
    return ch.isspace() or unicodedata.category(ch) == "Pd"


def _is_word_char(ch: str) -> bool:
    """True if *ch* continues a token: a letter/digit, or a combining mark
    (categories Mn/Mc/Me) that attaches to the preceding base. Default-ignorables
    are excluded -- they are transparent, not token content.

    Used only by the strict outer-boundary test, so that neither a
    default-ignorable nor a bare combining mark can, on its own, fabricate a
    phrase edge inside a larger token; a true string edge or any real separator
    (whitespace, dash, other punctuation, or a symbol) still can.
    """
    if ord(ch) in _DEFAULT_IGNORABLE_CODE_POINTS:
        return False
    return ch.isalnum() or unicodedata.category(ch) in ("Mn", "Mc", "Me")


# Precompute folded (words-tuple, canonical-string) pairs once.
def _phrase_words(phrase: str) -> "tuple[str, ...]":
    return tuple(_fold(phrase).split())


_BANNED_PHRASES: "tuple[tuple[tuple[str, ...], str], ...]" = tuple(
    (_phrase_words(phrase), " ".join(_phrase_words(phrase)))
    for phrase in BANNED_TOOL_NARRATION_PHRASES
)


def _match_phrase_at(folded: str, start: int, words: "tuple[str, ...]") -> int:
    """Try to match *words* beginning at content index *start*.

    Lenient, phrase-INTERNAL rules apply here:
      * default-ignorables may appear between the characters of a word;
      * an inter-word seam is one-or-more soft separators (ignorable OR
        whitespace OR dash) -- an *empty* seam (glued tokens) does not match.

    Returns the exclusive end index on success, or -1.
    """
    n = len(folded)
    i = start
    for w_index, word in enumerate(words):
        if w_index > 0:
            seam = 0
            while i < n and (
                _is_default_ignorable_cp(folded[i]) or _is_hard_separator(folded[i])
            ):
                i += 1
                seam += 1
            if seam == 0:
                return -1
        for c_index, wc in enumerate(word):
            if w_index > 0 or c_index > 0:
                while i < n and _is_default_ignorable_cp(folded[i]):
                    i += 1
            if i >= n or folded[i] != wc:
                return -1
            i += 1
    return i


def _left_boundary_ok(folded: str, start: int) -> bool:
    """Outer start boundary (strict): valid at a true string edge, or when the
    nearest non-ignorable character to the left does not continue the token
    (i.e. is not a letter/digit/combining mark)."""
    j = start - 1
    while j >= 0 and _is_default_ignorable_cp(folded[j]):
        j -= 1
    if j < 0:
        return True  # a true string edge lies beyond the ignorables
    return not _is_word_char(folded[j])


def _right_boundary_ok(folded: str, end: int) -> bool:
    """Outer end boundary (strict): valid at a true string edge, or when the
    nearest non-ignorable character to the right does not continue the token
    (i.e. is not a letter/digit/combining mark)."""
    n = len(folded)
    j = end
    while j < n and _is_default_ignorable_cp(folded[j]):
        j += 1
    if j >= n:
        return True
    return not _is_word_char(folded[j])


def _banned_phrases_in(text: str) -> "list[str]":
    """Canonical banned phrases present in *text*, in policy order (deduped)."""
    folded = _fold(text)
    n = len(folded)
    found: "list[str]" = []
    for words, canonical in _BANNED_PHRASES:
        first = words[0][0]
        for start in range(n):
            if folded[start] != first:
                continue
            end = _match_phrase_at(folded, start, words)
            if end != -1 and _left_boundary_ok(folded, start) and _right_boundary_ok(
                folded, end
            ):
                found.append(canonical)
                break
    return found


def _count_words(text: str) -> int:
    """Count Unicode words: whitespace-delimited tokens containing a letter or
    digit. Default-ignorables are removed first so hidden characters neither
    split nor pad the count; NFC keeps accented Latin (and other scripts)
    coherent. Standalone punctuation (e.g. a lone dash) is not a word.
    """
    stripped = "".join(ch for ch in text if not _is_default_ignorable_cp(ch))
    normalized = unicodedata.normalize("NFC", stripped)
    return sum(1 for token in normalized.split() if any(c.isalnum() for c in token))


def _coerce_text(value: Any) -> Optional[str]:
    """Defensive read: None stays None (skip); non-str is coerced via str()."""
    if value is None:
        return None
    return value if isinstance(value, str) else str(value)


def scan_coach_output(analysis: Any, *, enabled: bool = False) -> "list[Finding]":
    """Return report-only hygiene findings for a coach payload.

    Hard default off: with ``enabled`` left False this is inert and returns an
    empty list for *any* input, including malformed payloads. Never raises and
    never mutates *analysis*.
    """
    if not enabled:
        return []
    if not isinstance(analysis, Mapping):
        return []

    findings: "list[Finding]" = []

    for field in COACH_AUTHORED_TEXT_FIELDS:
        text = _coerce_text(analysis.get(field))
        if text is None:
            continue
        for canonical in _banned_phrases_in(text):
            findings.append(Finding(field, BANNED_TOOL_NARRATION_CODE, canonical))
        if field == _RISK_REASON_FIELD:
            count = _count_words(text)
            if count > RISK_REASON_MAX_WORDS:
                findings.append(
                    Finding(
                        _RISK_REASON_FIELD,
                        RISK_REASON_WORD_LIMIT_CODE,
                        f"{count} words exceeds limit {RISK_REASON_MAX_WORDS}",
                    )
                )

    suggestions = analysis.get("suggestions")
    if isinstance(suggestions, Sequence) and not isinstance(suggestions, (str, bytes)):
        for index, suggestion in enumerate(suggestions):
            if not isinstance(suggestion, Mapping):
                continue
            # Scan ONLY the rationale; never the rewrite text.
            text = _coerce_text(suggestion.get("rationale"))
            if text is None:
                continue
            label = f"suggestions[{index}].rationale"
            for canonical in _banned_phrases_in(text):
                findings.append(Finding(label, BANNED_TOOL_NARRATION_CODE, canonical))

    return findings
