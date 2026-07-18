"""Shared test scaffolding for the reviewed-locale foundation.

IMPORTANT: everything here is *synthetic test scaffolding*. It contains no
production translations and is wired to nothing. Message text is English
placeholder copy chosen only to preserve the locale-invariant tokens (prices,
the 7-day trial, the [URGENT] tag, {count}) so the gates can be exercised. The
signing key below is a throwaway constant with zero real-world authority; it
exists only to demonstrate that verification accepts a correctly-bound
attestation and rejects everything else.
"""

from __future__ import annotations

import copy
import datetime as _dt
from typing import Any, Callable, Dict, Optional, Tuple

from backend.reviewed_locale import canonical
from backend.reviewed_locale.attestation import canonical_content_hash, sign

# A throwaway HMAC key. NOT a secret, NOT real authority -- test-only.
THROWAWAY_TEST_KEY = b"throwaway-test-authority-key::not-a-secret::exercise-only"
TEST_AUTHORITY_ID = "authority:test-localization-board"
TEST_REGISTRY: Dict[str, bytes] = {TEST_AUTHORITY_ID: THROWAWAY_TEST_KEY}

# Deterministic evaluation clock (== the task's "today"), and an issue time a
# few days before it so a valid attestation is neither future-dated nor stale.
EVAL_TIME = _dt.datetime(2026, 7, 18, 12, 0, 0, tzinfo=_dt.timezone.utc)
ISSUED_AT = "2026-07-10T00:00:00+00:00"

BASE_LOCALE = "en"
TARGET_LOCALE = "en-GB"
LANGUAGE_PAIR: Tuple[str, str] = (BASE_LOCALE, TARGET_LOCALE)


def valid_messages() -> Dict[str, Any]:
    """A mechanically-clean message bundle covering every critical key."""
    return {
        "pricing.monthly": "Pro is $3.99/mo.",
        "pricing.annual": "Pro is $39.99/yr.",
        "pricing.annual_savings": "Save $7.89 a year with annual.",
        "pricing.trial": "Start a 7-day free trial.",
        "pricing.recurrence_disclaimer": (
            "Auto-renews at $3.99/mo or $39.99/yr after the 7-day trial "
            "unless cancelled."
        ),
        "coach.axis.warmer": "Warmer",
        "coach.axis.clearer": "Clearer",
        "coach.axis.funnier": "Funnier",
        "coach.axis.safer": "Safer",
        "coach.rewrites_count": {
            "plural": {"one": "{count} rewrite", "other": "{count} rewrites"}
        },
        "contact.urgent_tag": "For anything urgent, tag the subject [URGENT].",
    }


def make_attestation(
    messages: Dict[str, Any],
    language_pair: Tuple[str, str] = LANGUAGE_PAIR,
    *,
    decision: str = "APPROVE_FOR_REVIEW",
    issued_at: str = ISSUED_AT,
    scope: Optional[list] = None,
    attestation_id: str = "att-0001",
    identity: str = "Reviewer One",
    credentials: str = "Board-certified en<->en-GB reviewer, cert #42",
    authority_id: str = TEST_AUTHORITY_ID,
    key: bytes = THROWAWAY_TEST_KEY,
    tamper: Optional[Callable[[Dict[str, Any]], Dict[str, Any]]] = None,
) -> Dict[str, Any]:
    """Build a signed attestation. ``tamper`` mutates the dict AFTER signing, so
    tampering with any signed field breaks the signature (that is the point)."""
    fields = {
        "attestation_id": attestation_id,
        "authority_id": authority_id,
        "reviewer_identity": identity,
        "reviewer_credentials": credentials,
        "source": language_pair[0],
        "target": language_pair[1],
        "content_hash": canonical_content_hash(messages),
        "scope": scope if scope is not None else sorted(messages.keys()),
        "decision": decision,
        "issued_at": issued_at,
    }
    signature = sign(key, fields)
    attestation = dict(fields)
    attestation["signature"] = signature
    if tamper is not None:
        attestation = tamper(attestation)
    return attestation


def valid_candidate(
    *,
    provenance: str = canonical.PROVENANCE_HUMAN,
    with_attestation: bool = True,
    messages: Optional[Dict[str, Any]] = None,
    locale: str = TARGET_LOCALE,
    base_locale: str = BASE_LOCALE,
    extra: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Assemble a full candidate. ``extra`` merges in additional keys (e.g. the
    self-asserted booleans a hostile candidate might try to smuggle in)."""
    msgs = messages if messages is not None else valid_messages()
    candidate: Dict[str, Any] = {
        "locale": locale,
        "base_locale": base_locale,
        "provenance": provenance,
        "messages": msgs,
        "base_messages": valid_messages(),
    }
    if with_attestation:
        candidate["attestation"] = make_attestation(msgs, (base_locale, locale))
    if extra:
        candidate.update(extra)
    return candidate


def mutate_messages(**overrides: Any) -> Dict[str, Any]:
    """Return a copy of the valid message bundle with keys replaced/removed.

    Pass ``key=None`` to delete a key, or ``key=<value>`` to replace it.
    """
    msgs = copy.deepcopy(valid_messages())
    for key, value in overrides.items():
        real_key = key.replace("__", ".")
        if value is None:
            msgs.pop(real_key, None)
        else:
            msgs[real_key] = value
    return msgs
