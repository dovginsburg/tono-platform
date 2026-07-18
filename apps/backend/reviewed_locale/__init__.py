"""Reviewed-locale foundation (inert, default-off, imported by nothing).

This package is a *gate*, not a feature. It decides whether a proposed localized
message bundle is mechanically sound and carries verifiable reviewer authority --
so that a human approver can then adjudicate it. It ships no translations, wires
into no server/dispatcher/config, performs no I/O, and activates nothing.

Importing it has no side effects. Nothing in the running product imports it; it
exists so that when reviewed locales are added, they are gated honestly.

Public API:
    evaluate_candidate(candidate, *, authority_registry=..., revocation_list=...,
                       evaluation_time=..., max_age_seconds=...) -> Decision
    Decision
    STATUS_NOT_ELIGIBLE / STATUS_PRE_REVIEW / STATUS_ELIGIBLE_FOR_REVIEW

The result's ``go`` / ``shipping_approved`` / ``runtime_activated`` are always
False by construction: a technical gate can validate evidence shape, but it can
neither fabricate bilingual/legal/product authority nor declare a shipping GO.
"""

from __future__ import annotations

from . import attestation, bcp47, canonical, gates, textnorm
from .evaluate import (
    STATUS_ELIGIBLE_FOR_REVIEW,
    STATUS_NOT_ELIGIBLE,
    STATUS_PRE_REVIEW,
    Decision,
    evaluate_candidate,
)

__version__ = "0.0.0-inert"

__all__ = [
    "evaluate_candidate",
    "Decision",
    "STATUS_NOT_ELIGIBLE",
    "STATUS_PRE_REVIEW",
    "STATUS_ELIGIBLE_FOR_REVIEW",
    "attestation",
    "bcp47",
    "canonical",
    "gates",
    "textnorm",
    "__version__",
]
