"""Canonical, source-grounded invariants for the reviewed-locale foundation.

Every value in this module is pinned to a *real* fact in the Tono codebase, so
that a reviewed locale can never silently drift away from what the product
actually charges, calls its tone axes, or promises about urgency and safety.

Provenance (see ``tests/test_canonical_invariants.py``, which re-derives these
from source with ``ast``/text so drift is caught rather than tolerated):

* Coach tone axes -> ``apps/backend/analyze.py`` ``CANONICAL_COACH_AXES``.
* Prices / trial / savings -> ``apps/backend/payments.py`` header and the web
  pricing surfaces (``apps/web/src/app/{page,pricing,terms,about,privacy}.tsx``
  and ``TonoFooter.tsx``): ``$3.99/mo``, ``$39.99/yr``, ``7-day free trial``,
  ``save $7.89``.
* Urgency tag -> ``apps/web/src/app/contact/page.tsx``: subject tag ``[URGENT]``.
* Non-clinical stance -> ``apps/web/src/app/TonoFooter.tsx``: "Crisis / support
  line is intentionally absent -- Tono is not a clinical product." Localized
  copy therefore must never fabricate a crisis/clinical line (forbidden tokens).

This module is pure data. It performs no I/O, imports nothing outside the
standard library's typing, and has no side effects on import.
"""

from __future__ import annotations

from typing import Dict, FrozenSet, Tuple


# --------------------------------------------------------------------------
# Coach tone axes -- canonical order and identity.
# --------------------------------------------------------------------------
# Mirror of backend/analyze.py CANONICAL_COACH_AXES. The order is contractual
# (server.py + slack.py + the web tone chips all render in this order).
COACH_AXES: Tuple[str, ...] = ("warmer", "clearer", "funnier", "safer")


# --------------------------------------------------------------------------
# Pricing invariants -- locale-INVARIANT tokens that must survive translation.
# --------------------------------------------------------------------------
# Numbers and currency do not translate; the words around them do. A reviewed
# locale must preserve these exact tokens verbatim.
PRICE_MONTHLY = "$3.99"
PRICE_ANNUAL = "$39.99"
PRICE_ANNUAL_SAVINGS = "$7.89"
TRIAL_DAYS = "7"  # "7-day free trial" / "never charge until day 8"

# ASCII billing-cadence markers that appear verbatim in the app's own copy.
# We never *require* them (a target language uses its own words), but a message
# scoped to one cadence must never carry the OTHER cadence's ASCII marker --
# that is unambiguous cadence drift regardless of language.
MONTHLY_MARKERS: Tuple[str, ...] = ("/mo", "/month")
ANNUAL_MARKERS: Tuple[str, ...] = ("/yr", "/year")

# Trial-length drift guards: representative wrong trial lengths that must never
# appear where the canonical trial length (7) belongs. Multi-digit so they are
# unambiguous drift, not incidental single digits in surrounding copy.
FORBIDDEN_TRIAL_LENGTHS: Tuple[str, ...] = ("14", "30")


# --------------------------------------------------------------------------
# Urgency mechanism -- a machine-meaningful literal, preserved verbatim.
# --------------------------------------------------------------------------
# The support flow keys on the literal subject tag "[URGENT]". A translation
# that localizes the *word* is fine in prose, but the machine tag itself must
# survive verbatim or the "tag it and we'll see it first" mechanism breaks.
URGENCY_TAG = "[URGENT]"


# --------------------------------------------------------------------------
# Critical message keys -- the contract a reviewed locale must satisfy.
# --------------------------------------------------------------------------
# Tono ships English-only today; this is the foundation that a reviewed locale
# is gated against. Each key declares only what a *mechanical* gate can honestly
# enforce: locale-invariant tokens that must be present, tokens that must be
# absent (cross-cadence / cross-price contamination), and required interpolation
# placeholders. True bilingual fidelity is explicitly out of a technical gate's
# reach and is deferred to human review (which is why the gate never claims GO).


class KeySpec:
    """Per-key mechanical contract. Immutable value object."""

    __slots__ = (
        "key",
        "required_tokens",
        "forbidden_tokens",
        "required_placeholders",
        "is_plural",
        "description",
    )

    def __init__(
        self,
        key: str,
        *,
        required_tokens: Tuple[str, ...] = (),
        forbidden_tokens: Tuple[str, ...] = (),
        required_placeholders: FrozenSet[str] = frozenset(),
        is_plural: bool = False,
        description: str = "",
    ) -> None:
        self.key = key
        self.required_tokens = required_tokens
        self.forbidden_tokens = forbidden_tokens
        self.required_placeholders = required_placeholders
        self.is_plural = is_plural
        self.description = description


CRITICAL_KEY_SPECS: Tuple[KeySpec, ...] = (
    KeySpec(
        "pricing.monthly",
        required_tokens=(PRICE_MONTHLY,),
        forbidden_tokens=(PRICE_ANNUAL, PRICE_ANNUAL_SAVINGS) + ANNUAL_MARKERS,
        description="Monthly Pro price. Must keep $3.99, never the annual price/marker.",
    ),
    KeySpec(
        "pricing.annual",
        required_tokens=(PRICE_ANNUAL,),
        forbidden_tokens=(PRICE_MONTHLY,) + MONTHLY_MARKERS,
        description="Annual Pro price. Must keep $39.99, never the monthly price/marker.",
    ),
    KeySpec(
        "pricing.annual_savings",
        required_tokens=(PRICE_ANNUAL_SAVINGS,),
        description="Annual savings vs monthly. Must keep $7.89.",
    ),
    KeySpec(
        "pricing.trial",
        required_tokens=(TRIAL_DAYS,),
        forbidden_tokens=FORBIDDEN_TRIAL_LENGTHS,
        description="7-day free trial. Trial length must stay 7.",
    ),
    KeySpec(
        "pricing.recurrence_disclaimer",
        required_tokens=(PRICE_MONTHLY, PRICE_ANNUAL, TRIAL_DAYS),
        description="Auto-renew disclaimer: references both prices and the 7-day trial.",
    ),
    KeySpec(
        "coach.axis.warmer",
        description="Translated label for the 'warmer' tone axis.",
    ),
    KeySpec(
        "coach.axis.clearer",
        description="Translated label for the 'clearer' tone axis.",
    ),
    KeySpec(
        "coach.axis.funnier",
        description="Translated label for the 'funnier' tone axis.",
    ),
    KeySpec(
        "coach.axis.safer",
        description="Translated label for the 'safer' tone axis (safety-bearing).",
    ),
    KeySpec(
        "coach.rewrites_count",
        required_placeholders=frozenset({"{count}"}),
        is_plural=True,
        description="Pluralized rewrite count. Every plural form must keep {count}.",
    ),
    KeySpec(
        "contact.urgent_tag",
        required_tokens=(URGENCY_TAG,),
        description="Urgent support mechanism. Literal [URGENT] tag preserved verbatim.",
    ),
)

CRITICAL_KEYS: FrozenSet[str] = frozenset(spec.key for spec in CRITICAL_KEY_SPECS)

# The four axis-label keys form a group that must stay COMPLETE and DISTINCT:
# collapsing two axes onto one translation (or dropping one) destroys the
# "pick the axis that fits the moment" contract.
COACH_AXIS_KEYS: Tuple[str, ...] = tuple(
    "coach.axis.{}".format(axis) for axis in COACH_AXES
)

SPEC_BY_KEY: Dict[str, KeySpec] = {spec.key: spec for spec in CRITICAL_KEY_SPECS}


# --------------------------------------------------------------------------
# Forbidden clinical / crisis tokens.
# --------------------------------------------------------------------------
# Tono is explicitly NOT a clinical product and intentionally ships no crisis
# line. A localized string that fabricates one (directly or via obfuscation)
# makes a safety claim the product cannot stand behind, so it is rejected.
#
# WORD tokens are matched against an obfuscation-resistant "skeleton" (see
# textnorm.py). NUMERIC tokens are matched against separator-tolerant digit
# runs with exact boundaries so "988" fires on "9-8-8" but not on "1988".
FORBIDDEN_WORD_TOKENS: Tuple[str, ...] = (
    "suicide",
    "suicidal",
    "selfharm",
    "poisoncontrol",
    "overdose",
    "crisishotline",
    "crisisline",
    "suicidehotline",
    "crisislifeline",
    "suicidelifeline",
)
FORBIDDEN_NUMERIC_TOKENS: Tuple[str, ...] = ("988", "911")


# --------------------------------------------------------------------------
# CLDR plural categories.
# --------------------------------------------------------------------------
# Valid Unicode CLDR plural category names. 'other' is always required.
CLDR_PLURAL_CATEGORIES: FrozenSet[str] = frozenset(
    {"zero", "one", "two", "few", "many", "other"}
)
CLDR_REQUIRED_CATEGORY = "other"


# --------------------------------------------------------------------------
# Provenance markers.
# --------------------------------------------------------------------------
# Synthetic/placeholder fixtures must be labelled and can NEVER be elevated
# past PRE_REVIEW, no matter what else they carry.
PROVENANCE_SYNTHETIC = "SYNTHETIC_PLACEHOLDER"
PROVENANCE_HUMAN = "HUMAN_TRANSLATED"
ALLOWED_PROVENANCE: FrozenSet[str] = frozenset(
    {PROVENANCE_SYNTHETIC, PROVENANCE_HUMAN}
)
