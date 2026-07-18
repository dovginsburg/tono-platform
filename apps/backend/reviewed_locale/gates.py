"""Mechanical (Sherlock t_80f35f58) gates for a reviewed-locale candidate.

These gates validate *shape and invariants* only. They are deliberately exact
where translation-invariant facts are at stake (prices, trial length, the
literal urgency tag, interpolation placeholders, safety) and deliberately silent
about genuine bilingual fidelity, which no regex can judge -- that is why a
passing candidate is only ever routed to *human* review, never approved.

Pure standard library; no side effects on import.
"""

from __future__ import annotations

import re
from typing import Any, Dict, Iterable, List, Mapping, NamedTuple, Tuple

from . import canonical, textnorm


class GateFailure(NamedTuple):
    gate: str
    detail: str


# C0 (incl. tab/newline), DEL, and C1 controls are all disallowed in display
# strings. Reviewed-locale copy is plain text; structure must be explicit markup.
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f-\x9f]")

# A price token like "$39.99" must not be immediately followed by another digit
# or a further decimal group -- "$39.990" and "$39.99.5" are NOT "$39.99".
_PLACEHOLDER_RE = re.compile(r"\{[^{}]*\}")


# --------------------------------------------------------------------------
# Message-form iteration
# --------------------------------------------------------------------------
def iter_forms(value: Any) -> List[Tuple[str, str]]:
    """Yield ``(form_name, text)`` for a message value.

    * plain ``str`` -> one unnamed form;
    * ``{"plural": {<cldr-category>: str, ...}}``;
    * ``{"select":  {<variant>: str, ...}}``.

    Raises :class:`ValueError` for any other shape (fail closed).
    """
    if isinstance(value, str):
        return [("", value)]
    if isinstance(value, Mapping):
        if set(value.keys()) == {"plural"} and isinstance(value["plural"], Mapping):
            forms = value["plural"]
            kind = "plural"
        elif set(value.keys()) == {"select"} and isinstance(value["select"], Mapping):
            forms = value["select"]
            kind = "select"
        else:
            raise ValueError("message dict must be a single {'plural'|'select': {...}}")
        out: List[Tuple[str, str]] = []
        for name, text in forms.items():
            if not isinstance(name, str) or not name:
                raise ValueError("%s form name must be a non-empty string" % kind)
            if not isinstance(text, str):
                raise ValueError("%s form %r must map to a string" % (kind, name))
            out.append((name, text))
        if not out:
            raise ValueError("%s message has no forms" % kind)
        return out
    raise ValueError("message value must be a string or a plural/select mapping")


# --------------------------------------------------------------------------
# Exact token matching -- the "not substring" rule.
# --------------------------------------------------------------------------
def price_present(text: str, price: str) -> bool:
    """Exact price presence: '$39.99' but not inside '$39.990' / '$139.99'."""
    return re.search(re.escape(price) + r"(?![\d.])", text) is not None


def integer_present(text: str, number: str) -> bool:
    """Standalone integer: '7' in '7-day' but not in '17', '70', or '$7.89'."""
    return re.search(r"(?<![\d$.,])" + re.escape(number) + r"(?!\d)", text) is not None


def token_present(text: str, token: str) -> bool:
    """Dispatch a required/forbidden token to the right exactness rule."""
    if re.fullmatch(r"\$\d+\.\d+", token):
        return price_present(text, token)
    if token.isdigit():
        return integer_present(text, token)
    return token in text  # literals like "[URGENT]", "/mo", "/yr"


# --------------------------------------------------------------------------
# Individual gates
# --------------------------------------------------------------------------
def gate_controls(messages: Mapping[str, Any]) -> List[GateFailure]:
    failures: List[GateFailure] = []
    for key, value in messages.items():
        try:
            forms = iter_forms(value)
        except ValueError:
            continue  # shape handled by gate_shape
        for form_name, text in forms:
            if _CONTROL_RE.search(text):
                failures.append(
                    GateFailure(
                        "controls",
                        "control character in %s%s"
                        % (key, "/" + form_name if form_name else ""),
                    )
                )
    return failures


def gate_shape(messages: Mapping[str, Any]) -> List[GateFailure]:
    """Every message must be a well-formed string or plural/select mapping."""
    failures: List[GateFailure] = []
    for key, value in messages.items():
        try:
            iter_forms(value)
        except ValueError as exc:
            failures.append(GateFailure("shape", "%s: %s" % (key, exc)))
    return failures


def gate_critical_keys(messages: Mapping[str, Any]) -> List[GateFailure]:
    missing = canonical.CRITICAL_KEYS - set(messages.keys())
    return [
        GateFailure("critical_keys", "missing critical key: %s" % key)
        for key in sorted(missing)
    ]


def gate_fallback_parity(
    messages: Mapping[str, Any], base_messages: Mapping[str, Any]
) -> List[GateFailure]:
    """Base-locale fallback parity: every critical key the base defines must be
    present in the candidate, so nothing silently falls back to English."""
    failures: List[GateFailure] = []
    for key in sorted(canonical.CRITICAL_KEYS):
        if key in base_messages and key not in messages:
            failures.append(
                GateFailure("fallback_parity", "candidate omits base key: %s" % key)
            )
    return failures


def gate_plural_forms(messages: Mapping[str, Any]) -> List[GateFailure]:
    """CLDR plural messages: valid categories, 'other' present; plural-declared
    keys must actually be provided in plural form."""
    failures: List[GateFailure] = []
    for spec in canonical.CRITICAL_KEY_SPECS:
        if not spec.is_plural or spec.key not in messages:
            continue
        value = messages[spec.key]
        if not (isinstance(value, Mapping) and set(value.keys()) == {"plural"}):
            failures.append(
                GateFailure("plural", "%s must be a {'plural': {...}} message" % spec.key)
            )
            continue
        categories = value["plural"]
        if not isinstance(categories, Mapping) or not categories:
            failures.append(GateFailure("plural", "%s has no plural forms" % spec.key))
            continue
        unknown = set(categories.keys()) - canonical.CLDR_PLURAL_CATEGORIES
        if unknown:
            failures.append(
                GateFailure(
                    "plural",
                    "%s has unknown CLDR categories: %s"
                    % (spec.key, ", ".join(sorted(unknown))),
                )
            )
        if canonical.CLDR_REQUIRED_CATEGORY not in categories:
            failures.append(
                GateFailure("plural", "%s missing required 'other' form" % spec.key)
            )
    return failures


def gate_select_forms(messages: Mapping[str, Any]) -> List[GateFailure]:
    """Select messages must carry an 'other' fallback branch."""
    failures: List[GateFailure] = []
    for key, value in messages.items():
        if isinstance(value, Mapping) and set(value.keys()) == {"select"}:
            branches = value["select"]
            if isinstance(branches, Mapping) and "other" not in branches:
                failures.append(
                    GateFailure("select", "%s select message missing 'other' branch" % key)
                )
    return failures


def gate_invariant_tokens(messages: Mapping[str, Any]) -> List[GateFailure]:
    """Required locale-invariant tokens present, forbidden tokens absent -- on
    EVERY form. This is the exact pricing / cadence-drift gate."""
    failures: List[GateFailure] = []
    for spec in canonical.CRITICAL_KEY_SPECS:
        if spec.key not in messages:
            continue
        try:
            forms = iter_forms(messages[spec.key])
        except ValueError:
            continue
        for form_name, text in forms:
            label = spec.key + ("/" + form_name if form_name else "")
            for token in spec.required_tokens:
                if not token_present(text, token):
                    failures.append(
                        GateFailure(
                            "invariant",
                            "%s must preserve %r" % (label, token),
                        )
                    )
            for token in spec.forbidden_tokens:
                if token_present(text, token):
                    failures.append(
                        GateFailure(
                            "invariant",
                            "%s must not contain %r (cadence/price drift)"
                            % (label, token),
                        )
                    )
    return failures


def gate_interpolation(messages: Mapping[str, Any]) -> List[GateFailure]:
    """Required placeholders present in EVERY form; no unknown placeholders; no
    unbalanced braces."""
    failures: List[GateFailure] = []
    for spec in canonical.CRITICAL_KEY_SPECS:
        if spec.key not in messages:
            continue
        try:
            forms = iter_forms(messages[spec.key])
        except ValueError:
            continue
        allowed = spec.required_placeholders
        for form_name, text in forms:
            label = spec.key + ("/" + form_name if form_name else "")
            found = _PLACEHOLDER_RE.findall(text)
            # unbalanced braces: strip valid tokens, any brace left is a defect
            residue = _PLACEHOLDER_RE.sub("", text)
            if "{" in residue or "}" in residue:
                failures.append(
                    GateFailure("interpolation", "%s has unbalanced braces" % label)
                )
            for token in found:
                if token not in allowed:
                    failures.append(
                        GateFailure(
                            "interpolation",
                            "%s has unexpected placeholder %s" % (label, token),
                        )
                    )
            for token in allowed:
                if token not in text:
                    failures.append(
                        GateFailure(
                            "interpolation",
                            "%s missing required placeholder %s" % (label, token),
                        )
                    )
    return failures


def gate_brace_balance(messages: Mapping[str, Any]) -> List[GateFailure]:
    """No message form may contain an unbalanced/nested interpolation brace --
    a general safety net beyond the required-placeholder checks on critical keys."""
    failures: List[GateFailure] = []
    for key, value in messages.items():
        try:
            forms = iter_forms(value)
        except ValueError:
            continue
        for form_name, text in forms:
            residue = _PLACEHOLDER_RE.sub("", text)
            if "{" in residue or "}" in residue:
                label = key + ("/" + form_name if form_name else "")
                failures.append(
                    GateFailure("interpolation", "%s has unbalanced braces" % label)
                )
    return failures


def gate_forbidden_safety(messages: Mapping[str, Any]) -> List[GateFailure]:
    """Obfuscation-resistant rejection of clinical/crisis tokens anywhere."""
    failures: List[GateFailure] = []
    for key, value in messages.items():
        try:
            forms = iter_forms(value)
        except ValueError:
            continue
        for form_name, text in forms:
            label = key + ("/" + form_name if form_name else "")
            skel = textnorm.word_skeleton(text)  # compute once per form
            runs = set(textnorm.digit_runs(text))
            for token in canonical.FORBIDDEN_WORD_TOKENS:
                if token in skel:
                    failures.append(
                        GateFailure(
                            "forbidden_safety",
                            "%s contains forbidden clinical token %r" % (label, token),
                        )
                    )
            for token in canonical.FORBIDDEN_NUMERIC_TOKENS:
                if token in runs:
                    failures.append(
                        GateFailure(
                            "forbidden_safety",
                            "%s contains forbidden crisis number %r" % (label, token),
                        )
                    )
    return failures


def gate_coach_axis_group(messages: Mapping[str, Any]) -> List[GateFailure]:
    """The four axis labels must be complete, non-empty, and pairwise distinct."""
    failures: List[GateFailure] = []
    labels: Dict[str, str] = {}
    for key in canonical.COACH_AXIS_KEYS:
        value = messages.get(key)
        if not isinstance(value, str) or not value.strip():
            failures.append(
                GateFailure("coach_labels", "%s must be a non-empty label" % key)
            )
        else:
            labels[key] = value.strip()
    seen: Dict[str, str] = {}
    for key, text in labels.items():
        folded = text.casefold()
        if folded in seen:
            failures.append(
                GateFailure(
                    "coach_labels",
                    "%s and %s share the same label -- axes collapsed"
                    % (seen[folded], key),
                )
            )
        else:
            seen[folded] = key
    return failures


# --------------------------------------------------------------------------
# Orchestrator
# --------------------------------------------------------------------------
def run_mechanical_gates(
    messages: Mapping[str, Any], base_messages: Mapping[str, Any]
) -> List[GateFailure]:
    """Run every mechanical gate; return the accumulated failures (empty=pass)."""
    failures: List[GateFailure] = []
    failures += gate_shape(messages)
    failures += gate_critical_keys(messages)
    failures += gate_fallback_parity(messages, base_messages)
    failures += gate_controls(messages)
    failures += gate_plural_forms(messages)
    failures += gate_select_forms(messages)
    failures += gate_invariant_tokens(messages)
    failures += gate_interpolation(messages)
    failures += gate_brace_balance(messages)
    failures += gate_forbidden_safety(messages)
    failures += gate_coach_axis_group(messages)
    return failures
