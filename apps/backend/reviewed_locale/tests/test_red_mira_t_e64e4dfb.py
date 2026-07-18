"""RED authority gates reconstructed from Mira review t_e64e4dfb.

Mandated hostile requirements:

* enum role strings / arbitrary reviewer names cannot establish authority;
* a candidate boolean cannot self-assert that safety review happened;
* authority comes ONLY from an attestation that BINDS -- under one signature --
  verifiable reviewer authority, the locale/language pair, the exact content
  hash, the scope, the decision, the time, and revocation status;
* synthetic placeholder fixtures stay PRE_REVIEW and never receive the
  authority-bearing ELIGIBLE_FOR_REVIEW;
* Coach translated-label and urgency/billing semantics are preserved;
* a technical gate may validate evidence SHAPE but can neither fabricate
  authority nor claim GO.

Reconstructed independently from the documented findings (the rejected candidate
is immutable hostile input, not copied). RED against the naive baseline, GREEN
against the remediated package.
"""

from __future__ import annotations

import unittest

from backend.reviewed_locale import Decision, canonical
from backend.reviewed_locale.tests import _fixtures as fx
from backend.reviewed_locale.tests._gate import (
    STATUS_ELIGIBLE_FOR_REVIEW,
    STATUS_NOT_ELIGIBLE,
    STATUS_PRE_REVIEW,
    evaluate_candidate,
)


def _eval(candidate, **kw):
    kw.setdefault("authority_registry", fx.TEST_REGISTRY)
    kw.setdefault("evaluation_time", fx.EVAL_TIME)
    return evaluate_candidate(candidate, **kw)


class SelfAssertionCannotEstablishAuthority(unittest.TestCase):
    def test_boolean_self_assertion_is_ignored(self):
        cand = fx.valid_candidate(
            with_attestation=False,
            extra={
                "human_reviewed": True,
                "safety_reviewed": True,
                "go": True,
                "shipping_approved": True,
                "runtime_activated": True,
            },
        )
        d = _eval(cand)
        self.assertNotEqual(d.status, STATUS_ELIGIBLE_FOR_REVIEW)
        self.assertEqual(d.status, STATUS_PRE_REVIEW)
        self.assertFalse(d.human_reviewed)
        self.assertFalse(d.go)
        self.assertFalse(d.shipping_approved)
        self.assertFalse(d.runtime_activated)

    def test_enum_role_string_is_ignored(self):
        for role in ("LOCALIZATION_LEAD", "ADMIN", "SAFETY_OFFICER", "OWNER"):
            cand = fx.valid_candidate(
                with_attestation=False,
                extra={"reviewer_role": role, "reviewer_name": "A. Person"},
            )
            d = _eval(cand)
            self.assertNotEqual(
                d.status, STATUS_ELIGIBLE_FOR_REVIEW, "role %r granted authority" % role
            )

    def test_arbitrary_name_is_ignored(self):
        cand = fx.valid_candidate(
            with_attestation=False,
            extra={"reviewer": {"identity": "Jane Doe", "credentials": "Trusted"}},
        )
        d = _eval(cand)
        self.assertNotEqual(d.status, STATUS_ELIGIBLE_FOR_REVIEW)


class AttestationMustBind(unittest.TestCase):
    """Each binding, removed or corrupted, must deny eligibility."""

    def _candidate_with(self, att, messages=None):
        msgs = messages if messages is not None else fx.valid_messages()
        cand = fx.valid_candidate(messages=msgs, with_attestation=False)
        cand["attestation"] = att
        return cand

    def test_authority_not_in_registry_is_forged(self):
        att = fx.make_attestation(fx.valid_messages(), authority_id="authority:unknown")
        d = _eval(self._candidate_with(att))
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)

    def test_wrong_signing_key_is_forged(self):
        att = fx.make_attestation(fx.valid_messages(), key=b"not-the-registry-key")
        d = _eval(self._candidate_with(att))
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)

    def test_tampered_signed_field_breaks_signature(self):
        def tamper(a):
            a["reviewer_credentials"] = "Elevated to super-admin after signing"
            return a

        att = fx.make_attestation(fx.valid_messages(), tamper=tamper)
        d = _eval(self._candidate_with(att))
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)

    def test_content_hash_must_match_messages(self):
        signed_over = fx.valid_messages()
        att = fx.make_attestation(signed_over)
        # Ship DIFFERENT content than what was attested.
        shipped = dict(signed_over)
        shipped["coach.axis.warmer"] = "Warmest"
        d = _eval(self._candidate_with(att, messages=shipped))
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)

    def test_language_pair_must_match(self):
        att = fx.make_attestation(fx.valid_messages(), language_pair=("en", "fr"))
        d = _eval(self._candidate_with(att))  # candidate is en -> en-GB
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)

    def test_scope_must_cover_the_keys(self):
        msgs = fx.valid_messages()
        deficient_scope = sorted(set(msgs.keys()) - {"pricing.trial"})
        att = fx.make_attestation(msgs, scope=deficient_scope)
        d = _eval(self._candidate_with(att, messages=msgs))
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)

    def test_future_dated_is_rejected(self):
        att = fx.make_attestation(
            fx.valid_messages(), issued_at="2026-08-01T00:00:00+00:00"
        )
        d = _eval(self._candidate_with(att))
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)

    def test_unknown_decision_is_malformed(self):
        att = fx.make_attestation(fx.valid_messages(), decision="APPROVE")
        d = _eval(self._candidate_with(att))
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)

    def test_missing_time_is_malformed(self):
        def drop_time(a):
            a["issued_at"] = ""
            return a

        att = fx.make_attestation(fx.valid_messages(), tamper=drop_time)
        d = _eval(self._candidate_with(att))
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)

    # The following are authentic-but-not-current -> PRE_REVIEW (not a forgery).
    def test_revoked_attestation_is_pre_review(self):
        att = fx.make_attestation(fx.valid_messages(), attestation_id="att-revoked-1")
        d = _eval(self._candidate_with(att), revocation_list=["att-revoked-1"])
        self.assertEqual(d.status, STATUS_PRE_REVIEW)
        self.assertNotEqual(d.status, STATUS_ELIGIBLE_FOR_REVIEW)

    def test_expired_attestation_is_pre_review(self):
        att = fx.make_attestation(
            fx.valid_messages(), issued_at="2024-01-01T00:00:00+00:00"
        )
        d = _eval(self._candidate_with(att))
        self.assertEqual(d.status, STATUS_PRE_REVIEW)

    def test_withheld_decision_is_pre_review(self):
        for decision in ("REJECT", "ABSTAIN"):
            att = fx.make_attestation(fx.valid_messages(), decision=decision)
            d = _eval(self._candidate_with(att))
            self.assertEqual(d.status, STATUS_PRE_REVIEW, "decision %s" % decision)


class SyntheticStaysPreReview(unittest.TestCase):
    def test_synthetic_with_valid_attestation_is_capped_at_pre_review(self):
        msgs = fx.valid_messages()
        att = fx.make_attestation(msgs)  # a perfectly valid attestation
        cand = fx.valid_candidate(
            messages=msgs,
            provenance=canonical.PROVENANCE_SYNTHETIC,
            with_attestation=False,
        )
        cand["attestation"] = att
        d = _eval(cand)
        self.assertEqual(d.status, STATUS_PRE_REVIEW)
        self.assertNotEqual(d.status, STATUS_ELIGIBLE_FOR_REVIEW)
        self.assertFalse(d.human_reviewed)


class SemanticsPreserved(unittest.TestCase):
    def test_collapsing_two_coach_axes_fails(self):
        cand = fx.valid_candidate(
            messages=fx.mutate_messages(coach__axis__safer="Warmer")
        )
        d = _eval(cand)
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)
        self.assertTrue(any("coach_labels" in f for f in d.gate_failures))

    def test_dropping_a_coach_axis_label_fails(self):
        cand = fx.valid_candidate(
            messages=fx.mutate_messages(coach__axis__funnier=None)
        )
        d = _eval(cand)
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)


class TechnicalGateNeverClaimsGo(unittest.TestCase):
    def test_best_case_result_is_review_not_go(self):
        d = _eval(fx.valid_candidate())
        self.assertEqual(d.status, STATUS_ELIGIBLE_FOR_REVIEW)
        # Eligible for HUMAN review only -- never a shipping decision.
        self.assertFalse(d.go)
        self.assertFalse(d.shipping_approved)
        self.assertFalse(d.runtime_activated)

    def test_decision_forces_shipping_axes_false(self):
        # Even constructed with True, the guarantees hold structurally.
        d = Decision(
            status=STATUS_ELIGIBLE_FOR_REVIEW,
            go=True,
            shipping_approved=True,
            runtime_activated=True,
        )
        self.assertFalse(d.go)
        self.assertFalse(d.shipping_approved)
        self.assertFalse(d.runtime_activated)


if __name__ == "__main__":
    unittest.main(verbosity=2)
