"""Default-OFF Coach output-hygiene validator (standard library only).

This module inspects a Coach ``ToneAnalysis`` payload for two SYSTEM_PROMPT
violations and *reports* them; it never mutates, rewrites, or raises. It has no
runtime wiring anywhere in the app and is imported only by its focused test.

What it checks (only in coach-authored prose):
  * Banned tool-narration phrases -- "based on", "I checked", "looking at",
    "my read" (SYSTEM_PROMPT rule 5) -- in ``perception``, ``subtext``,
    ``risk_reason`` and ``suggestions[].rationale``.
  * ``risk_reason`` must be <= 12 Unicode words (SYSTEM_PROMPT rule 10).

What it never touches:
  * The rewrite ``suggestions[].text`` field is never read or scanned; the
    validator is report-only and must not see, let alone rewrite, rewrites.

Public-safety contract (do not weaken):
  ``validate_coach_output`` is an *unconditional never-raises boundary* for
  arbitrary Python objects -- not merely JSON-decoded/plain containers.
  Malformed payloads, Mapping implementations whose ``.get`` raises, hostile
  iterables/containers, and values whose ``__str__`` raises all yield inert/safe
  results instead of escaping. Defensive reads catch ``Exception`` (the family
  hostile data raises) and deliberately let genuine process-control exceptions
  (``KeyboardInterrupt``/``SystemExit``/``GeneratorExit`` -- ``BaseException``
  but not ``Exception``) propagate, so the boundary never swallows them.

Evasion resistance:
  Matching folds text with a deterministic NFKC + casefold and is transparent to
  Unicode Default_Ignorable_Code_Points (DICP), pinned to an explicit range
  table for Unicode 13.0.0 (exactly 4,173 code points -- the property, not
  category Cf, so U+034F, U+FE0F and U+E0100 are covered). Ignorables may vanish
  inside a phrase word and may satisfy the inter-word seam, but they never
  fabricate an outer phrase boundary inside a larger benign token
  ("rebased on", "based online", "my reading" are not matches).

Unicode provenance:
  version 13.0.0; source
  https://www.unicode.org/Public/13.0.0/ucd/DerivedCoreProperties.txt
  (SHA-256 recorded in ``UNICODE_DICP_SOURCE_SHA256``).
"""

from __future__ import annotations

import bisect
import unicodedata
from dataclasses import dataclass
from typing import Any, List, Optional, Tuple

__all__ = [
    "Finding",
    "validate_coach_output",
    "banned_phrases_in_text",
    "risk_reason_word_count",
    "default_ignorable_codepoints",
    "iter_default_ignorable_codepoints",
    "BANNED_TOOL_NARRATION_PHRASES",
    "RISK_REASON_WORD_LIMIT",
    "DEFAULT_IGNORABLE_RANGES",
    "UNICODE_VERSION",
    "UNICODE_DICP_SOURCE_URL",
    "UNICODE_DICP_SOURCE_SHA256",
    "UNICODE_DICP_COUNT",
]

# --- Unicode provenance ----------------------------------------------------
UNICODE_VERSION = "13.0.0"
UNICODE_DICP_SOURCE_URL = (
    "https://www.unicode.org/Public/13.0.0/ucd/DerivedCoreProperties.txt"
)
UNICODE_DICP_SOURCE_SHA256 = (
    "a5d45f59b39deaab3c72ce8c1a2e212a5e086dff11b1f9d5bb0e352642e82248"
)
UNICODE_DICP_COUNT = 4173

# Default_Ignorable_Code_Point ranges (inclusive) for Unicode 13.0.0. Parsed
# from the official DerivedCoreProperties.txt; 17 ranges expand to exactly
# 4,173 code points. This is the property table, NOT category Cf: U+034F is Mn
# and U+FE00..U+FE0F / U+E0100.. are variation selectors.
DEFAULT_IGNORABLE_RANGES: Tuple[Tuple[int, int], ...] = (
    (0x00AD, 0x00AD), (0x034F, 0x034F), (0x061C, 0x061C), (0x115F, 0x1160),
    (0x17B4, 0x17B5), (0x180B, 0x180E), (0x200B, 0x200F), (0x202A, 0x202E),
    (0x2060, 0x206F), (0x3164, 0x3164), (0xFE00, 0xFE0F), (0xFEFF, 0xFEFF),
    (0xFFA0, 0xFFA0), (0xFFF0, 0xFFF8), (0x1BCA0, 0x1BCA3), (0x1D173, 0x1D17A),
    (0xE0000, 0xE0FFF),
)

# Banned tool-narration phrases, verbatim from SYSTEM_PROMPT rule 5.
BANNED_TOOL_NARRATION_PHRASES: Tuple[str, ...] = (
    "based on", "I checked", "looking at", "my read",
)

RISK_REASON_WORD_LIMIT = 12

# Coach-authored prose fields scanned for banned phrases. The rewrite ``text``
# field is intentionally absent and is never read.
_COACH_TEXT_FIELDS = ("perception", "subtext", "risk_reason")

_RANGE_STARTS = tuple(a for a, _ in DEFAULT_IGNORABLE_RANGES)
_RANGE_ENDS = tuple(b for _, b in DEFAULT_IGNORABLE_RANGES)


def _is_default_ignorable(cp: int) -> bool:
    i = bisect.bisect_right(_RANGE_STARTS, cp) - 1
    return i >= 0 and cp <= _RANGE_ENDS[i]


def iter_default_ignorable_codepoints():
    """Yield every DICP code point from the explicit range table."""
    for a, b in DEFAULT_IGNORABLE_RANGES:
        for cp in range(a, b + 1):
            yield cp


def default_ignorable_codepoints() -> frozenset:
    """Return the DICP set (exactly 4,173 code points for Unicode 13.0.0)."""
    return frozenset(iter_default_ignorable_codepoints())


# --- Deterministic folding and character classification --------------------

def _fold(s: str) -> str:
    """Deterministic caseless/compatibility fold: NFKC(casefold(NFKC(s))).

    Default-ignorable code points survive folding (normalization never strips
    them), so intra-word/seam obfuscation is preserved for the matcher to see.
    """
    return unicodedata.normalize(
        "NFKC", unicodedata.normalize("NFKC", s).casefold()
    )


_WORD, _SEP, _IGN, _OTHER = 1, 2, 3, 4


def _classify(ch: str) -> int:
    cp = ord(ch)
    # DICP is checked first: some ignorables (e.g. U+3164 HANGUL FILLER) are
    # otherwise alphanumeric, and U+034F is a combining mark. They must be
    # treated as invisible, never as word characters.
    if _is_default_ignorable(cp):
        return _IGN
    if ch.isalnum():
        return _WORD
    if ch.isspace():
        return _SEP
    if unicodedata.category(ch) == "Pd" or cp == 0x2212:
        return _SEP  # Unicode dash separators (Pd + MINUS SIGN)
    return _OTHER


# --- Boundary-aware, ignorable-transparent phrase matcher ------------------
#
# A phrase is two tokens separated by one seam. Within a token, ignorables are
# transparent (deleted). At the seam, whitespace / dash / ignorables all count
# as separators. Outer boundaries are "real": ignorables adjacent to the phrase
# are skipped and the nearest real character (or string edge) decides the
# boundary, so an ignorable can never carve a phrase out of a larger token.

def _match_token(folded: str, cls: list, i: int, token: str) -> int:
    j = i
    for k, tch in enumerate(token):
        if k > 0:  # intra-token: absorb ignorables between characters
            while j < len(folded) and cls[j] == _IGN:
                j += 1
        if j >= len(folded) or folded[j] != tch:
            return -1
        j += 1
    return j


def _match_seam(folded: str, cls: list, j: int) -> int:
    start = j
    while j < len(folded) and cls[j] in (_SEP, _IGN):
        j += 1
    return j if j > start else -1  # require at least one separator


def _left_is_boundary(cls: list, i: int) -> bool:
    j = i - 1
    while j >= 0 and cls[j] == _IGN:
        j -= 1
    return j < 0 or cls[j] != _WORD


def _right_is_boundary(folded: str, cls: list, j: int) -> bool:
    n = len(folded)
    while j < n and cls[j] == _IGN:
        j += 1
    return j >= n or cls[j] != _WORD


def _contains_phrase(folded: str, cls: list, tokens: list) -> bool:
    first = tokens[0]
    head = first[0]
    for i in range(len(folded)):
        if folded[i] != head or cls[i] != _WORD:
            continue
        if not _left_is_boundary(cls, i):
            continue
        j = _match_token(folded, cls, i, first)
        if j < 0:
            continue
        ok = True
        for token in tokens[1:]:
            s = _match_seam(folded, cls, j)
            if s < 0:
                ok = False
                break
            nxt = _match_token(folded, cls, s, token)
            if nxt < 0:
                ok = False
                break
            j = nxt
        if ok and _right_is_boundary(folded, cls, j):
            return True
    return False


_FOLDED_PHRASE_TOKENS = tuple(
    (phrase, _fold(phrase).split(" "))
    for phrase in BANNED_TOOL_NARRATION_PHRASES
)


def banned_phrases_in_text(text: Any) -> Tuple[str, ...]:
    """Return the banned phrases present in ``text``. Never raises."""
    try:
        s = _safe_str(text)
        if s is None:
            return ()
        folded = _fold(s)
        cls = [_classify(c) for c in folded]
        return tuple(
            phrase for phrase, tokens in _FOLDED_PHRASE_TOKENS
            if _contains_phrase(folded, cls, tokens)
        )
    except Exception:
        return ()


def risk_reason_word_count(text: Any) -> int:
    """Count Unicode words (whitespace-separated after NFKC). Never raises."""
    try:
        s = _safe_str(text)
        if s is None:
            return 0
        return len(_fold(s).split())
    except Exception:
        return 0


# --- Findings --------------------------------------------------------------

@dataclass(frozen=True)
class Finding:
    field: str
    code: str
    detail: str
    phrase: Optional[str] = None
    word_count: Optional[int] = None


# --- Hostile-safe coercion and reads ---------------------------------------
#
# Every helper below contains Exception (the family hostile payloads raise) and
# returns an inert sentinel instead of escaping. Process-control exceptions are
# BaseException-not-Exception and intentionally propagate.

def _safe_str(value: Any) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, str):
        return value
    try:
        return str(value)
    except Exception:
        return None


def _read(getter, key: str) -> Any:
    try:
        return getter(key)
    except Exception:
        return None


def _mapping_getter(payload: Any):
    try:
        get = getattr(payload, "get", None)
    except Exception:
        return None
    if not callable(get):
        return None

    def _get(key):
        return get(key)

    return _get


def _iter_items(obj: Any) -> list:
    if obj is None or isinstance(obj, (str, bytes, bytearray)):
        return []
    try:
        return list(obj)
    except Exception:
        return []


# --- Scanning --------------------------------------------------------------

def _scan_string(text: str, label: str, findings: List[Finding],
                 check_word_limit: bool) -> None:
    try:
        for phrase in banned_phrases_in_text(text):
            findings.append(Finding(
                field=label, code="banned_tool_narration",
                detail="contains banned tool-narration phrase %r" % (phrase,),
                phrase=phrase,
            ))
        if check_word_limit:
            count = risk_reason_word_count(text)
            if count > RISK_REASON_WORD_LIMIT:
                findings.append(Finding(
                    field=label, code="risk_reason_too_long",
                    detail="risk_reason has %d words (limit %d)"
                           % (count, RISK_REASON_WORD_LIMIT),
                    word_count=count,
                ))
    except Exception:
        return


def _scan_text_field(getter, key: str, label: str, findings: List[Finding],
                     check_word_limit: bool = False) -> None:
    value = _read(getter, key)
    if value is None:
        return
    text = _safe_str(value)
    if text is None:
        return
    _scan_string(text, label, findings, check_word_limit)


def _scan(payload: Any, findings: List[Finding]) -> None:
    getter = _mapping_getter(payload)
    if getter is None:
        return
    _scan_text_field(getter, "perception", "perception", findings)
    _scan_text_field(getter, "subtext", "subtext", findings)
    _scan_text_field(getter, "risk_reason", "risk_reason", findings,
                     check_word_limit=True)
    suggestions = _read(getter, "suggestions")
    for idx, item in enumerate(_iter_items(suggestions)):
        item_getter = _mapping_getter(item)
        if item_getter is None:
            continue
        # Only ``rationale`` is coach prose; the rewrite ``text`` is never read.
        _scan_text_field(item_getter, "rationale",
                         "suggestions[%d].rationale" % idx, findings)


def validate_coach_output(payload: Any, *, enabled: bool = False) -> List[Finding]:
    """Report Coach output-hygiene findings for ``payload``.

    Hard default-off: with ``enabled=False`` (the default) this returns ``[]``
    without inspecting anything. With ``enabled=True`` it returns a list of
    :class:`Finding`. It never raises for any Python object (see the module
    docstring's public-safety contract) and never mutates ``payload``.
    """
    findings: List[Finding] = []
    if not enabled:
        return findings
    try:
        _scan(payload, findings)
    except Exception:
        # Absolute backstop. Process-control exceptions are not Exception and
        # still propagate; ordinary hostile failures are contained.
        return findings
    return findings
