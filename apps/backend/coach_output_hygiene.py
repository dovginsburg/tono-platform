"""Default-off Coach output-hygiene validator (standalone, stdlib-only).

This module is a *fresh successor* validator for the Tono backend Coach. It is
imported by nothing in the running app -- it ships default-off / dormant and is
exercised only by focused tests. Nothing here is wired into ``server.py``,
``slack.py``, or ``analyze.py``; adopting it later is an explicit, separate
step.

What it does
------------
It inspects the coach-authored free-text fields of a ToneAnalysis-shaped
payload and *reports* two classes of hygiene problem. It never rewrites,
redacts, truncates, or otherwise mutates the coach's text -- it only returns a
list of :class:`HygieneFinding` describing what it saw.

  1. ``banned_tool_narration`` -- a SYSTEM_PROMPT rule-5 tool-narration phrase
     appears in ``perception``, ``subtext``, ``risk_reason``, or a suggestion's
     ``rationale``. The banned set is copied verbatim from
     ``apps/backend/analyze.py`` SYSTEM_PROMPT rule 5 ("NEVER use 'based on',
     'I checked', 'looking at', 'my read', or any tool-narration filler"). It
     is kept as a local constant so this module stays standalone (importing
     ``analyze`` would drag in FastAPI / pydantic / httpx).
  2. ``risk_reason_too_long`` -- ``risk_reason`` exceeds the SYSTEM_PROMPT
     rule-10 ceiling of 12 words.

Deterministic Unicode semantics (stdlib ``unicodedata`` only)
-------------------------------------------------------------
* Caseless / compatibility fold: ``NFKC -> str.casefold -> NFKC`` (a fixed
  three-step normalization, idempotent for the inputs here). Fullwidth and
  other compatibility forms fold to ASCII; case is normalized.
* A "word" (for the risk_reason ceiling) is a maximal run of non-whitespace
  that contains at least one alphanumeric character (Unicode ``str.isalnum``)
  or combining mark (general category ``M*``); pure-punctuation runs (a lone
  ``--`` / ``...``) are not words. Default-ignorable format characters are
  stripped first, then the text is split on Unicode whitespace. Combining marks
  stay attached, so accented Latin is one word; whitespace-separated Cyrillic
  or CJK tokens count as one word each.
* Narration separators, by strength:
    - HARD (a definite word boundary): Unicode whitespace (``str.isspace()``)
      or dash punctuation (general category ``Pd``).
    - SOFT (an *optional* boundary -- may act as a boundary or vanish):
      default-ignorable format characters (general category ``Cf`` -- zero-width
      space/joiner/non-joiner, BOM/ZWNBSP, soft hyphen, word joiner, bidi
      controls, ...).
    - NONE: adjacent content characters with nothing between them.
  The MINUS SIGN U+2212 is category ``Sm`` and is deliberately NOT a dash
  separator. A banned phrase is detected when, after removing separators to get
  a contiguous letter string, its concatenated words align to that string with
  a HARD-or-SOFT boundary before the phrase, after it, and at every inter-word
  seam, and with no HARD separator inside any phrase word. Because every ``Cf``
  is an *optional* boundary, obfuscation is caught wherever the zero-width
  characters land -- at a seam ("based<ZWSP>on"), inside a word
  ("ba<ZWSP>sed on"), or both at once ("ba<ZWSP>sed<ZWSP>on") -- while a truly
  glued token ("basedon") and substrings of longer real words ("rebased",
  "reading") are not flagged.

Known, deliberate limitations (documented, not bugs)
----------------------------------------------------
* Dash punctuation is an equivalent separator by spec, so a hyphen compound can
  match ("my read-only" -> reports "my read"). Space-joined non-phrases
  ("my reading") stay clean.
* Combining-mark obfuscation ("b<U+0301>ased on") is out of the ``Cf`` scope
  and is not caught; the tradeoff keeps accented Latin one word.
* U+2212 MINUS SIGN (``Sm``) is not a dash separator ("looking<U+2212>at" is
  clean).
"""

from __future__ import annotations

import unicodedata
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any, List

# SYSTEM_PROMPT rule-10 ceiling for ``risk_reason``.
MAX_RISK_REASON_WORDS = 12

# Verbatim from apps/backend/analyze.py SYSTEM_PROMPT rule 5. Local copy keeps
# this module standalone; the canonical form (as written to the user) is
# preserved so a finding can name the exact phrase.
BANNED_TOOL_NARRATION_PHRASES = (
    "based on",
    "I checked",
    "looking at",
    "my read",
)

# Coach-authored free-text fields scanned for banned phrases. Each suggestion's
# ``rationale`` is scanned additionally (see :func:`check_coach_output`).
COACH_AUTHORED_TEXT_FIELDS = ("perception", "subtext", "risk_reason")


@dataclass(frozen=True)
class HygieneFinding:
    """A single, read-only hygiene observation. Carries no rewrite/replacement."""

    field: str
    code: str
    detail: str
    phrase: str = ""
    word_count: int = 0


# --- Unicode primitives ----------------------------------------------------

def fold_text(text: str) -> str:
    """Compatibility caseless fold: ``NFKC -> casefold -> NFKC``."""
    text = unicodedata.normalize("NFKC", text)
    text = text.casefold()
    return unicodedata.normalize("NFKC", text)


def _is_ignorable(ch: str) -> bool:
    """Default-ignorable format separator: Unicode general category ``Cf``."""
    return unicodedata.category(ch) == "Cf"


def _is_dash(ch: str) -> bool:
    """Dash punctuation: Unicode general category ``Pd`` (U+2212 is ``Sm``)."""
    return unicodedata.category(ch) == "Pd"


def _strip_ignorable(text: str) -> str:
    return "".join(ch for ch in text if not _is_ignorable(ch))


def _is_word_token(token: str) -> bool:
    """A token counts as a word if it carries a letter/digit or combining mark."""
    return any(ch.isalnum() or unicodedata.category(ch).startswith("M") for ch in token)


def count_words(text: Any) -> int:
    """Unicode-safe word count = number of word-bearing whitespace runs.

    Non-strings count as zero (defensive). Default-ignorable format characters
    are removed first so a zero-width character can neither fabricate nor hide a
    boundary; the remainder is split on Unicode whitespace and pure-punctuation
    runs are ignored.
    """
    if not isinstance(text, str):
        return 0
    return sum(1 for token in _strip_ignorable(text).split() if _is_word_token(token))


# --- separator-aware phrase matching ---------------------------------------

_NONE, _SOFT, _HARD = 0, 1, 2


def _scan(folded: str):
    """Reduce folded text to its content letters plus inter-letter boundaries.

    Returns ``(letters, gaps)`` where ``letters`` is the content string with all
    separators removed and ``gaps[i]`` is the strongest separator immediately
    before ``letters[i]`` (``gaps[len(letters)]`` is the trailing gap):
    ``_HARD`` for whitespace/dash, ``_SOFT`` for default-ignorable ``Cf`` only,
    ``_NONE`` for directly-adjacent content.
    """
    letters: List[str] = []
    gaps: List[int] = []
    pending = _NONE
    for ch in folded:
        if ch.isspace() or _is_dash(ch):
            pending = _HARD
        elif _is_ignorable(ch):
            if pending != _HARD:
                pending = _SOFT
        else:
            gaps.append(pending)
            letters.append(ch)
            pending = _NONE
    gaps.append(pending)
    return "".join(letters), gaps


def _is_boundary(gaps: List[int], n: int, i: int) -> bool:
    # Start and end are always boundaries; internally any HARD or SOFT gap is one.
    return i == 0 or i == n or gaps[i] != _NONE


def _phrase_present(letters: str, gaps: List[int], words) -> bool:
    concat = "".join(words)
    m, n = len(concat), len(letters)
    if m == 0 or m > n:
        return False
    seams = set()
    offset = 0
    for word in words[:-1]:
        offset += len(word)
        seams.add(offset)  # inter-word boundary offsets, relative to a match
    start = 0
    while True:
        p = letters.find(concat, start)
        if p < 0:
            return False
        if _is_boundary(gaps, n, p) and _is_boundary(gaps, n, p + m):
            ok = all(_is_boundary(gaps, n, p + seam) for seam in seams)
            if ok:
                for i in range(1, m):
                    if i not in seams and gaps[p + i] == _HARD:
                        ok = False  # a real separator splits this phrase word
                        break
            if ok:
                return True
        start = p + 1


# Phrases pre-folded into their word lists (plain ASCII constants).
_BANNED_PHRASE_WORDS = tuple(
    (phrase, tuple(fold_text(phrase).split()))
    for phrase in BANNED_TOOL_NARRATION_PHRASES
)


def find_banned_phrases(text: Any) -> List[str]:
    """Return banned phrases present in ``text``, in canonical order.

    Matching is whole-word and separator-aware (see the module docstring), so
    zero-width obfuscation is caught wherever it lands while substrings of
    longer real words are not reported.
    """
    if not isinstance(text, str) or not text:
        return []
    letters, gaps = _scan(fold_text(text))
    found: List[str] = []
    for phrase, words in _BANNED_PHRASE_WORDS:
        if _phrase_present(letters, gaps, words):
            found.append(phrase)
    return found


# --- field-level checks ----------------------------------------------------

def check_field_text(text: Any, field_name: str) -> List[HygieneFinding]:
    """Report banned tool-narration phrases in one text field (report-only)."""
    findings: List[HygieneFinding] = []
    if not isinstance(text, str):
        return findings
    for phrase in find_banned_phrases(text):
        findings.append(
            HygieneFinding(
                field=field_name,
                code="banned_tool_narration",
                detail="{0} contains banned tool-narration phrase {1!r}".format(field_name, phrase),
                phrase=phrase,
            )
        )
    return findings


def check_risk_reason_length(text: Any, field_name: str = "risk_reason") -> List[HygieneFinding]:
    """Report a ``risk_reason`` that exceeds the 12-word ceiling (report-only)."""
    if not isinstance(text, str):
        return []
    words = count_words(text)
    if words <= MAX_RISK_REASON_WORDS:
        return []
    return [
        HygieneFinding(
            field=field_name,
            code="risk_reason_too_long",
            detail="{0} has {1} words (limit {2})".format(field_name, words, MAX_RISK_REASON_WORDS),
            word_count=words,
        )
    ]


def check_coach_output(result: Any) -> List[HygieneFinding]:
    """Validate coach-authored text; return an ordered list of findings.

    Report-only: ``result`` is never mutated and no rewrite is produced. An
    empty list means clean. A non-mapping payload yields a single
    ``malformed_payload`` finding rather than raising; non-string fields and
    wrongly-shaped suggestions are skipped (type/schema enforcement is the
    coach contract's job, not this validator's).
    """
    if not isinstance(result, Mapping):
        return [
            HygieneFinding(
                field="<payload>",
                code="malformed_payload",
                detail="coach output is not a mapping",
            )
        ]

    findings: List[HygieneFinding] = []
    findings += check_field_text(result.get("perception"), "perception")
    findings += check_field_text(result.get("subtext"), "subtext")
    findings += check_field_text(result.get("risk_reason"), "risk_reason")
    findings += check_risk_reason_length(result.get("risk_reason"), "risk_reason")

    suggestions = result.get("suggestions")
    if isinstance(suggestions, Sequence) and not isinstance(suggestions, (str, bytes)):
        for index, item in enumerate(suggestions):
            if isinstance(item, Mapping):
                findings += check_field_text(
                    item.get("rationale"), "suggestions[{0}].rationale".format(index)
                )
    return findings


def is_clean(result: Any) -> bool:
    """True iff :func:`check_coach_output` reports nothing."""
    return not check_coach_output(result)
