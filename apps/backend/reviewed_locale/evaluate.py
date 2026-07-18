"""Fail-closed evaluation of a reviewed-locale candidate.

``evaluate_candidate`` is the one public entry point. It is *total* (never
raises for hostile input -- any surprise becomes ``NOT_ELIGIBLE``) and it can
never emit a shipping decision: ``go``, ``shipping_approved`` and
``runtime_activated`` are forced ``False`` on every result, by construction.

Terminal states
---------------
* ``NOT_ELIGIBLE``        -- a mechanical gate failed, the tag is invalid, or an
  attestation is malformed / forged / out-of-scope / future-dated. Fail closed.
* ``PRE_REVIEW``          -- mechanically clean, but not (yet) eligible for
  routing to a human reviewer: a synthetic placeholder, an absent attestation,
  or an authentic-but-withholding / stale attestation.
* ``ELIGIBLE_FOR_REVIEW`` -- mechanically clean AND carrying a verifiable
  authority attestation bound to exactly this content. Means only "a human with
  real authority MAY now adjudicate this." It is NOT an approval and NOT a GO.

Candidate self-assertions (``human_reviewed``, ``reviewer_role``, ``go``,
``approved`` ...) are never read for the decision. Authority comes only from a
verified attestation (see :mod:`attestation`).
"""

from __future__ import annotations

import datetime as _dt
from dataclasses import dataclass, field
from typing import Any, Mapping, Optional, Sequence, Tuple

from . import attestation as _att
from . import bcp47, canonical, gates

STATUS_NOT_ELIGIBLE = "NOT_ELIGIBLE"
STATUS_PRE_REVIEW = "PRE_REVIEW"
STATUS_ELIGIBLE_FOR_REVIEW = "ELIGIBLE_FOR_REVIEW"


@dataclass(frozen=True)
class Decision:
    """Immutable result. The three shipping booleans are forced False."""

    status: str
    locale: str = ""
    base_locale: str = ""
    human_reviewed: bool = False
    reasons: Tuple[str, ...] = ()
    gate_failures: Tuple[str, ...] = ()
    attestation_outcome: Optional[str] = None
    # Shipping axes -- hard-wired False; see __post_init__.
    go: bool = False
    shipping_approved: bool = False
    runtime_activated: bool = False

    def __post_init__(self) -> None:
        # Defense in depth: no code path -- not even a future bug -- may let this
        # module claim GO / shipping approval / runtime activation.
        object.__setattr__(self, "go", False)
        object.__setattr__(self, "shipping_approved", False)
        object.__setattr__(self, "runtime_activated", False)

    @property
    def eligible_for_review(self) -> bool:
        return self.status == STATUS_ELIGIBLE_FOR_REVIEW


def _reject(locale: str, base_locale: str, reasons, gate_failures=(), outcome=None) -> Decision:
    return Decision(
        status=STATUS_NOT_ELIGIBLE,
        locale=locale,
        base_locale=base_locale,
        human_reviewed=False,
        reasons=tuple(reasons),
        gate_failures=tuple(gate_failures),
        attestation_outcome=outcome,
    )


def evaluate_candidate(
    candidate: Any,
    *,
    authority_registry: Optional[Mapping[str, bytes]] = None,
    revocation_list: Sequence[str] = (),
    evaluation_time: Optional[_dt.datetime] = None,
    max_age_seconds: int = _att.DEFAULT_MAX_AGE_SECONDS,
) -> Decision:
    """Evaluate *candidate*; always returns a :class:`Decision`, never raises."""
    try:
        return _evaluate(
            candidate,
            authority_registry=authority_registry or {},
            revocation_list=tuple(revocation_list or ()),
            evaluation_time=evaluation_time,
            max_age_seconds=max_age_seconds,
        )
    except Exception as exc:  # fail closed on ANYTHING unexpected
        return _reject("", "", ["internal error, fail closed: %s" % type(exc).__name__])


def _evaluate(
    candidate: Any,
    *,
    authority_registry: Mapping[str, bytes],
    revocation_list: Tuple[str, ...],
    evaluation_time: Optional[_dt.datetime],
    max_age_seconds: int,
) -> Decision:
    if not isinstance(candidate, Mapping):
        return _reject("", "", ["candidate must be a mapping"])

    locale = candidate.get("locale")
    base_locale = candidate.get("base_locale")
    loc_s = locale if isinstance(locale, str) else ""
    base_s = base_locale if isinstance(base_locale, str) else ""

    # --- locale tags (BCP-47 / RFC 5646, incl. extlang prefix) ---
    tag_reasons = []
    if not bcp47.is_valid(loc_s):
        tag_reasons.append("invalid locale tag: %r" % locale)
    if not bcp47.is_valid(base_s):
        tag_reasons.append("invalid base_locale tag: %r" % base_locale)
    if tag_reasons:
        return _reject(loc_s, base_s, tag_reasons)

    # --- provenance must be declared and known ---
    provenance = candidate.get("provenance")
    if provenance not in canonical.ALLOWED_PROVENANCE:
        return _reject(loc_s, base_s, ["unknown or missing provenance: %r" % provenance])

    # --- messages ---
    messages = candidate.get("messages")
    if not isinstance(messages, Mapping) or not all(
        isinstance(k, str) for k in messages.keys()
    ):
        return _reject(loc_s, base_s, ["messages must be a mapping with string keys"])

    base_messages = candidate.get("base_messages", {})
    if not isinstance(base_messages, Mapping):
        return _reject(loc_s, base_s, ["base_messages must be a mapping"])

    # --- mechanical gates (Sherlock) ---
    failures = gates.run_mechanical_gates(messages, base_messages)
    if failures:
        return _reject(
            loc_s,
            base_s,
            ["mechanical gate failure"],
            gate_failures=["%s: %s" % (f.gate, f.detail) for f in failures],
        )

    # --- authority (Mira). Self-asserted fields are never consulted. ---
    language_pair = (base_s, loc_s)
    attestation = candidate.get("attestation")

    if provenance == canonical.PROVENANCE_SYNTHETIC:
        # Hard cap: synthetic/placeholder fixtures never leave PRE_REVIEW.
        return Decision(
            status=STATUS_PRE_REVIEW,
            locale=loc_s,
            base_locale=base_s,
            human_reviewed=False,
            reasons=("synthetic placeholder fixture -- non-shipping, PRE_REVIEW only",),
        )

    if attestation is None:
        return Decision(
            status=STATUS_PRE_REVIEW,
            locale=loc_s,
            base_locale=base_s,
            human_reviewed=False,
            reasons=("no reviewer-authority attestation -- PRE_REVIEW",),
        )

    eval_time = evaluation_time or _dt.datetime.now(_dt.timezone.utc)
    check = _att.verify(
        attestation,
        messages=messages,
        language_pair=language_pair,
        scoped_keys=set(messages.keys()),
        authority_registry=authority_registry,
        evaluation_time=eval_time,
        revocation_list=revocation_list,
        max_age_seconds=max_age_seconds,
    )

    if check.is_valid:
        return Decision(
            status=STATUS_ELIGIBLE_FOR_REVIEW,
            locale=loc_s,
            base_locale=base_s,
            human_reviewed=True,
            reasons=(
                "mechanically clean + verifiable authority attestation; "
                "eligible for HUMAN review only (not approved, not GO)",
            ),
            attestation_outcome=check.outcome,
        )

    if check.hard_reject:
        return _reject(
            loc_s,
            base_s,
            ["attestation rejected: %s" % check.reason],
            outcome=check.outcome,
        )

    # Authentic but withholding, or stale/revoked -> back to PRE_REVIEW.
    return Decision(
        status=STATUS_PRE_REVIEW,
        locale=loc_s,
        base_locale=base_s,
        human_reviewed=False,
        reasons=("attestation not affirmative/current: %s" % check.reason,),
        attestation_outcome=check.outcome,
    )
