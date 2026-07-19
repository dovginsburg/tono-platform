"""Lexical hygiene checks for coach-authored prose — a default-off, ship-later guard.

The structural Coach contract (``analyze.enforce_coach_contract``) validates the
*shape* of a ``ToneAnalysis``: that every requested axis is present, ordered,
de-duplicated, non-blank, and preserves the user's semantic intent. It
deliberately does not inspect the coach's own explanatory prose for the
output-hygiene rules that ``analyze.SYSTEM_PROMPT`` instructs the model to
follow. Those rules are, today, *unverified*: if a provider drifts (a model
swap, a prompt edit, a bad day) and emits generic-LLM narration such as
"Based on your message, this reads as cold.", it ships to the user unchecked —
the exact "generic-LLM English" the product's system prompt forbids.

This module is a small, dependency-free (stdlib-only) validator for two of
those documented rules. It is imported by nothing in the tree today — a hard
default-off boundary. Adopt it later by either:
  * wiring ``scan_coach_output`` into ``enforce_coach_contract`` to fail closed
    (raise ``CoachContractError`` when violations are found), or
  * calling it from a QA / monitoring job to alert on provider drift without
    changing user-facing behavior.

It only inspects fields the coach authors from scratch — ``perception``,
``subtext``, ``risk_reason``, and each suggestion's ``rationale``. It never
inspects a suggestion's rewrite ``text``, which legitimately echoes the user's
own words (a user drafting "I'm looking at the report" must not be flagged for
"looking at").

Rules enforced (see ``analyze.SYSTEM_PROMPT``):
  R5  no tool-narration filler ("based on", "I checked", "looking at",
      "my read") in coach-authored prose.
  R10 ``risk_reason`` is a short phrase of at most 12 words.

Rules deliberately NOT enforced here (documented, but not safely checkable in
stdlib without false positives):
  R1  one-sentence ceiling — "one sentence" means one bubble/clause, not one
      terminal mark. The product's own warmer rewrite is "Hey! <draft>", which
      a naive terminal-punctuation counter would wrongly reject. Needs
      clause-level analysis.
  R6  <=3 emoji in ``perception`` — reliable emoji grapheme-cluster counting
      (ZWJ sequences, skin-tone modifiers, variation selectors) is not
      available in the standard library.
"""

from __future__ import annotations

import re
from collections.abc import Mapping
from typing import Any, List, NamedTuple

# Tool-narration filler the coach must never emit (analyze.SYSTEM_PROMPT, rule 5).
# Stored canonical-lowercase; matching is case-insensitive.
TOOL_NARRATION_PHRASES: tuple = ("based on", "i checked", "looking at", "my read")

# analyze.SYSTEM_PROMPT rule 10: "one short phrase <=12 words".
RISK_REASON_MAX_WORDS = 12

# Fields the coach authors as free prose (never the user's own words). These are
# safe to scan for banned filler; a suggestion's rewrite ``text`` is not.
COACH_PROSE_FIELDS: tuple = ("perception", "subtext", "risk_reason")


def _compile(phrase: str) -> "re.Pattern[str]":
    # Word-boundary anchored, whitespace-flexible: "based on" matches
    # "Based  on" but not the substring inside "databased online".
    body = r"\s+".join(re.escape(word) for word in phrase.split())
    return re.compile(rf"\b{body}\b", re.IGNORECASE)


_PHRASE_PATTERNS = tuple((phrase, _compile(phrase)) for phrase in TOOL_NARRATION_PHRASES)

_WORD_RE = re.compile(r"[0-9A-Za-z]+(?:['’][0-9A-Za-z]+)*")


class Violation(NamedTuple):
    """A single hygiene finding. ``rule`` is one of ``tool_narration`` or
    ``risk_reason_length``; ``field`` is the dotted location of the offending
    text (e.g. ``perception`` or ``suggestions[0].rationale``)."""

    field: str
    rule: str
    detail: str


def find_tool_narration(text: Any) -> List[str]:
    """Return the banned tool-narration phrases present in ``text``.

    Case-insensitive, word-boundary aware, de-duplicated, ordered by first
    appearance. Non-string input yields an empty list.
    """
    if not isinstance(text, str) or not text:
        return []
    hits: list = []  # (first_index, canonical_phrase)
    for phrase, pattern in _PHRASE_PATTERNS:
        match = pattern.search(text)
        if match is not None:
            hits.append((match.start(), phrase))
    hits.sort(key=lambda pair: pair[0])
    return [phrase for _, phrase in hits]


def count_words(text: Any) -> int:
    """Count word tokens (alphanumeric runs; contractions count once).

    Punctuation-only tokens such as an em dash are not words.
    """
    if not isinstance(text, str):
        return 0
    return len(_WORD_RE.findall(text))


def risk_reason_exceeds_ceiling(text: Any, max_words: int = RISK_REASON_MAX_WORDS) -> bool:
    """True if ``text`` has more than ``max_words`` words (rule 10)."""
    return count_words(text) > max_words


def scan_coach_output(
    result: Any,
    *,
    max_risk_reason_words: int = RISK_REASON_MAX_WORDS,
) -> List[Violation]:
    """Scan a coach result mapping for hygiene violations.

    Accepts the plain ``dict`` that ``enforce_coach_contract`` returns (no
    pydantic dependency). Non-mapping input, or a mapping missing these fields,
    yields an empty list — the function never raises on malformed input so a
    monitor can call it defensively.
    """
    if not isinstance(result, Mapping):
        return []

    violations: List[Violation] = []

    for field in COACH_PROSE_FIELDS:
        value = result.get(field)
        if isinstance(value, str):
            for phrase in find_tool_narration(value):
                violations.append(
                    Violation(
                        field,
                        "tool_narration",
                        f"coach prose contains banned tool-narration filler: {phrase!r}",
                    )
                )

    risk_reason = result.get("risk_reason")
    if isinstance(risk_reason, str) and risk_reason.strip():
        words = count_words(risk_reason)
        if words > max_risk_reason_words:
            violations.append(
                Violation(
                    "risk_reason",
                    "risk_reason_length",
                    f"risk_reason has {words} words; ceiling is {max_risk_reason_words}",
                )
            )

    suggestions = result.get("suggestions")
    if isinstance(suggestions, list):
        for index, suggestion in enumerate(suggestions):
            if not isinstance(suggestion, Mapping):
                continue
            rationale = suggestion.get("rationale")
            if isinstance(rationale, str):
                for phrase in find_tool_narration(rationale):
                    violations.append(
                        Violation(
                            f"suggestions[{index}].rationale",
                            "tool_narration",
                            f"rationale contains banned tool-narration filler: {phrase!r}",
                        )
                    )

    return violations


def is_clean(result: Any, *, max_risk_reason_words: int = RISK_REASON_MAX_WORDS) -> bool:
    """Convenience: True when ``scan_coach_output`` finds no violations."""
    return not scan_coach_output(result, max_risk_reason_words=max_risk_reason_words)
