"""Verifiable reviewer-authority attestations.

The point of this module is the thing Mira (t_e64e4dfb) insisted on: a candidate
cannot *self-assert* that it was reviewed. An enum role string, an arbitrary
reviewer name, or a ``human_reviewed = True`` boolean prove nothing -- anyone can
type them. Authority has to be **bound**, and the binding has to be
**verifiable** against something the candidate does not control.

An attestation here binds, under one signature:

* a **reviewer authority** identified by ``authority_id`` -- verified by an
  HMAC-SHA256 signature against a key supplied by the *caller* (the deploying
  environment), never by the candidate. The candidate cannot mint authority.
* the **locale / language pair** it reviewed;
* the **exact content hash** of the messages it reviewed (recomputed here, so a
  single edit to the candidate voids the attestation);
* the **scope** of keys it covers;
* the **decision** (only ``APPROVE_FOR_REVIEW`` is affirmative);
* the **issue time** (rejected if in the future or too old);
* and it is checked against a caller-supplied **revocation list**.

Even a fully valid attestation only means "a human reviewer with real authority
MAY now adjudicate this" -- it is *never* a shipping approval. This module holds
no keys and grants no authority of its own; it only checks evidence shape and
the cryptographic binding. Pure standard library; no side effects on import.
"""

from __future__ import annotations

import datetime as _dt
import hashlib
import hmac
import json
from typing import Any, Dict, Iterable, Mapping, NamedTuple, Optional, Sequence, Tuple

from . import canonical


# Decision vocabulary. Only APPROVE_FOR_REVIEW is affirmative; the others are
# authentic-but-withholding outcomes.
DECISION_APPROVE = "APPROVE_FOR_REVIEW"
DECISION_REJECT = "REJECT"
DECISION_ABSTAIN = "ABSTAIN"
KNOWN_DECISIONS = frozenset({DECISION_APPROVE, DECISION_REJECT, DECISION_ABSTAIN})

# Fields that are covered by the signature (everything that matters). Order is
# irrelevant: we serialize with sort_keys.
_SIGNED_FIELDS = (
    "attestation_id",
    "authority_id",
    "reviewer_identity",
    "reviewer_credentials",
    "source",
    "target",
    "content_hash",
    "scope",
    "decision",
    "issued_at",
)

_REQUIRED_FIELDS = _SIGNED_FIELDS + ("signature",)

DEFAULT_MAX_AGE_SECONDS = 365 * 24 * 3600  # one year


# Verification outcomes and how evaluate.py maps them.
OUTCOME_VALID = "VALID"                 # -> ELIGIBLE_FOR_REVIEW
OUTCOME_MALFORMED = "MALFORMED"         # -> NOT_ELIGIBLE  (bad shape / blank creds)
OUTCOME_FORGED = "FORGED"               # -> NOT_ELIGIBLE  (bad sig / wrong binding)
OUTCOME_OUT_OF_SCOPE = "OUT_OF_SCOPE"   # -> NOT_ELIGIBLE  (scope misses keys)
OUTCOME_FUTURE = "FUTURE"               # -> NOT_ELIGIBLE  (issued in the future)
OUTCOME_WITHHELD = "WITHHELD"           # -> PRE_REVIEW    (authentic, not approved)
OUTCOME_STALE = "STALE"                 # -> PRE_REVIEW    (revoked / expired)

_NOT_ELIGIBLE_OUTCOMES = frozenset(
    {OUTCOME_MALFORMED, OUTCOME_FORGED, OUTCOME_OUT_OF_SCOPE, OUTCOME_FUTURE}
)
_PRE_REVIEW_OUTCOMES = frozenset({OUTCOME_WITHHELD, OUTCOME_STALE})


class AttestationCheck(NamedTuple):
    outcome: str
    reason: str

    @property
    def is_valid(self) -> bool:
        return self.outcome == OUTCOME_VALID

    @property
    def hard_reject(self) -> bool:
        """True if the outcome should force NOT_ELIGIBLE (a forgery attempt)."""
        return self.outcome in _NOT_ELIGIBLE_OUTCOMES


def canonical_content_hash(messages: Any) -> str:
    """Deterministic SHA-256 (hex) of a candidate's messages."""
    blob = json.dumps(
        messages, sort_keys=True, ensure_ascii=False, separators=(",", ":")
    )
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def _signing_bytes(fields: Mapping[str, Any]) -> bytes:
    payload = {}
    for name in _SIGNED_FIELDS:
        value = fields.get(name)
        if name == "scope":
            # Scope is a set-like; sign the sorted canonical form so ordering
            # cannot change the signature or smuggle duplicates.
            value = sorted(str(k) for k in (value or ()))
        payload[name] = value
    return json.dumps(
        payload, sort_keys=True, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")


def sign(key: bytes, fields: Mapping[str, Any]) -> str:
    """Produce the HMAC-SHA256 signature for *fields* under *key*.

    Signing requires possession of an authority key. That key lives in the
    deploying environment's registry, never in this repository -- this helper
    only defines the canonicalization so that a real authority (and the test
    harness, with throwaway keys) computes exactly what :func:`verify` checks.
    """
    return hmac.new(key, _signing_bytes(fields), hashlib.sha256).hexdigest()


def _parse_iso8601(value: str) -> Optional[_dt.datetime]:
    if not isinstance(value, str) or not value:
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = _dt.datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None  # require an explicit offset -- no ambiguous local time
    return parsed


def _nonblank_str(value: Any) -> bool:
    return isinstance(value, str) and value.strip() != ""


def verify(
    attestation: Any,
    *,
    messages: Any,
    language_pair: Tuple[str, str],
    scoped_keys: Iterable[str],
    authority_registry: Mapping[str, bytes],
    evaluation_time: _dt.datetime,
    revocation_list: Sequence[str] = (),
    max_age_seconds: int = DEFAULT_MAX_AGE_SECONDS,
) -> AttestationCheck:
    """Verify *attestation* binds real authority to exactly this content.

    Returns an :class:`AttestationCheck`; never raises for hostile input.
    """
    if not isinstance(attestation, Mapping):
        return AttestationCheck(OUTCOME_MALFORMED, "attestation is not a mapping")

    # ---- 1. shape ----
    for field in _REQUIRED_FIELDS:
        if field not in attestation:
            return AttestationCheck(OUTCOME_MALFORMED, "missing field: %s" % field)
    for field in (
        "attestation_id",
        "authority_id",
        "reviewer_identity",
        "reviewer_credentials",
        "source",
        "target",
        "content_hash",
        "decision",
        "issued_at",
        "signature",
    ):
        if not _nonblank_str(attestation[field]):
            return AttestationCheck(
                OUTCOME_MALFORMED, "blank or non-string field: %s" % field
            )
    scope = attestation.get("scope")
    if not isinstance(scope, (list, tuple)) or not all(
        isinstance(k, str) for k in scope
    ):
        return AttestationCheck(OUTCOME_MALFORMED, "scope must be a list of strings")

    # ---- 2. decision vocabulary ----
    decision = attestation["decision"]
    if decision not in KNOWN_DECISIONS:
        return AttestationCheck(OUTCOME_MALFORMED, "unknown decision: %r" % decision)

    # ---- 3. time parseable ----
    issued_at = _parse_iso8601(attestation["issued_at"])
    if issued_at is None:
        return AttestationCheck(
            OUTCOME_MALFORMED, "issued_at is not tz-aware ISO 8601"
        )

    # ---- 4. authority + signature (before trusting any signed field) ----
    authority_id = attestation["authority_id"]
    key = authority_registry.get(authority_id) if authority_registry else None
    if key is None:
        return AttestationCheck(
            OUTCOME_FORGED, "authority not in registry: %r" % authority_id
        )
    expected = sign(key, attestation)
    if not hmac.compare_digest(expected, str(attestation["signature"])):
        return AttestationCheck(OUTCOME_FORGED, "signature mismatch")

    # ---- 5. content binding ----
    recomputed = canonical_content_hash(messages)
    if not hmac.compare_digest(recomputed, str(attestation["content_hash"])):
        return AttestationCheck(OUTCOME_FORGED, "content hash does not match messages")

    # ---- 6. language pair ----
    if (attestation["source"], attestation["target"]) != tuple(language_pair):
        return AttestationCheck(OUTCOME_FORGED, "attested language pair mismatch")

    # ---- 7. scope covers the keys under review ----
    missing = set(scoped_keys) - set(scope)
    if missing:
        return AttestationCheck(
            OUTCOME_OUT_OF_SCOPE,
            "scope omits key(s): %s" % ", ".join(sorted(missing)),
        )

    # ---- 8. not future-dated ----
    if issued_at > evaluation_time:
        return AttestationCheck(OUTCOME_FUTURE, "issued in the future")

    # ---- 9. not revoked ----
    if attestation["attestation_id"] in set(revocation_list):
        return AttestationCheck(OUTCOME_STALE, "attestation revoked")

    # ---- 10. not expired ----
    age = (evaluation_time - issued_at).total_seconds()
    if age > max_age_seconds:
        return AttestationCheck(OUTCOME_STALE, "attestation expired")

    # ---- 11. affirmative decision ----
    if decision != DECISION_APPROVE:
        return AttestationCheck(OUTCOME_WITHHELD, "decision is %s" % decision)

    return AttestationCheck(OUTCOME_VALID, "verifiable authority attestation")
