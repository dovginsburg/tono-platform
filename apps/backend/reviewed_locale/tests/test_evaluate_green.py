"""GREEN behavior: the remediated foundation accepts what it should, denies what
it should, is totally fail-closed, and never claims GO."""

from __future__ import annotations

import unittest

from backend.reviewed_locale import (
    STATUS_ELIGIBLE_FOR_REVIEW,
    STATUS_NOT_ELIGIBLE,
    STATUS_PRE_REVIEW,
    bcp47,
    canonical,
    evaluate_candidate,
)
from backend.reviewed_locale.tests import _fixtures as fx


def _eval(candidate, **kw):
    kw.setdefault("authority_registry", fx.TEST_REGISTRY)
    kw.setdefault("evaluation_time", fx.EVAL_TIME)
    return evaluate_candidate(candidate, **kw)


class HappyPath(unittest.TestCase):
    def test_clean_and_attested_is_eligible_for_review(self):
        d = _eval(fx.valid_candidate())
        self.assertEqual(d.status, STATUS_ELIGIBLE_FOR_REVIEW)
        self.assertTrue(d.human_reviewed)
        self.assertFalse(d.go or d.shipping_approved or d.runtime_activated)

    def test_extra_self_asserted_fields_do_not_change_a_valid_result(self):
        # A valid attestation is present; junk self-assertions are simply ignored.
        cand = fx.valid_candidate(extra={"go": True, "human_reviewed": False})
        d = _eval(cand)
        self.assertEqual(d.status, STATUS_ELIGIBLE_FOR_REVIEW)
        self.assertFalse(d.go)

    def test_valid_across_several_locales(self):
        for locale in ("es-419", "zh-Hant", "zh-yue", "pt-BR", "fr-CA"):
            self.assertTrue(bcp47.is_valid(locale), locale)
            d = _eval(fx.valid_candidate(locale=locale))
            self.assertEqual(d.status, STATUS_ELIGIBLE_FOR_REVIEW, locale)


class PreReview(unittest.TestCase):
    def test_synthetic_is_pre_review(self):
        d = _eval(fx.valid_candidate(provenance=canonical.PROVENANCE_SYNTHETIC))
        self.assertEqual(d.status, STATUS_PRE_REVIEW)

    def test_no_attestation_is_pre_review(self):
        d = _eval(fx.valid_candidate(with_attestation=False))
        self.assertEqual(d.status, STATUS_PRE_REVIEW)


class FailClosed(unittest.TestCase):
    """evaluate_candidate is total: hostile inputs deny, never raise."""

    HOSTILE = [
        None,
        [],
        "not a mapping",
        123,
        {},
        {"locale": "en"},
        {"locale": "en", "base_locale": "en", "provenance": "HUMAN_TRANSLATED"},
        {"locale": "en", "base_locale": "en", "provenance": "HUMAN_TRANSLATED", "messages": None},
        {"locale": "en", "base_locale": "en", "provenance": "???", "messages": {}},
    ]

    def test_hostile_inputs_are_not_eligible_and_do_not_raise(self):
        for bad in self.HOSTILE:
            d = _eval(bad)
            self.assertEqual(d.status, STATUS_NOT_ELIGIBLE, repr(bad))
            self.assertFalse(d.go or d.shipping_approved or d.runtime_activated)

    def test_hostile_attestation_types_do_not_raise(self):
        for att in ("string", 123, [], {"partial": "att"}, {"signature": "x"}):
            cand = fx.valid_candidate(with_attestation=False)
            cand["attestation"] = att
            d = _eval(cand)
            self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)

    def test_missing_registry_denies_but_does_not_raise(self):
        d = evaluate_candidate(fx.valid_candidate(), evaluation_time=fx.EVAL_TIME)
        # No registry supplied -> authority cannot be verified -> not eligible.
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)


class NeverClaimsGo(unittest.TestCase):
    def test_no_status_ever_sets_shipping_axes(self):
        candidates = [
            fx.valid_candidate(),
            fx.valid_candidate(provenance=canonical.PROVENANCE_SYNTHETIC),
            fx.valid_candidate(with_attestation=False),
            {"garbage": True},
        ]
        for cand in candidates:
            d = _eval(cand)
            self.assertFalse(d.go)
            self.assertFalse(d.shipping_approved)
            self.assertFalse(d.runtime_activated)


if __name__ == "__main__":
    unittest.main(verbosity=2)
