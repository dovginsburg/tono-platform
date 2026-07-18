"""RED gates reconstructed from Sherlock review t_80f35f58 (mechanical).

Each test encodes one mandated hostile requirement:

* exact pricing semantics -- '$39.990' and cadence drift must FAIL (not the
  substring-containment that the rejected candidate used);
* required interpolation placeholders in EVERY plural/select form;
* forbidden safety tokens robust to punctuation / Unicode obfuscation;
* valid RFC 5646 / BCP-47 extlang prefixes -- 'en-yue' must FAIL;
* disallowed C0 control characters rejected;
* blank reviewer identity / credentials rejected.

These are reconstructed independently from the documented findings (the rejected
candidate is treated as immutable hostile input and is not copied). They are RED
against a pre-remediation naive baseline and GREEN against the remediated
package -- see ``_gate.REVIEWED_LOCALE_GATE`` and controller-artifacts.
"""

from __future__ import annotations

import unittest

from backend.reviewed_locale import canonical, gates
from backend.reviewed_locale.tests import _fixtures as fx
from backend.reviewed_locale.tests._gate import (
    STATUS_NOT_ELIGIBLE,
    evaluate_candidate,
)


def _evaluate(candidate):
    return evaluate_candidate(
        candidate,
        authority_registry=fx.TEST_REGISTRY,
        evaluation_time=fx.EVAL_TIME,
    )


def _reject_for(candidate, gate_name):
    d = _evaluate(candidate)
    return d, [f for f in d.gate_failures if f.startswith(gate_name + ":")]


class ExactPricingSemantics(unittest.TestCase):
    """'$39.990' or cadence drift must fail -- exactness, not substring."""

    def test_extra_trailing_digit_is_not_the_price(self):
        cand = fx.valid_candidate(
            messages=fx.mutate_messages(pricing__annual="Pro is $39.990/yr.")
        )
        d, hits = _reject_for(cand, "invariant")
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)
        self.assertTrue(hits, "$39.990 must not satisfy the $39.99 invariant")

    def test_decimal_group_drift_is_not_the_price(self):
        cand = fx.valid_candidate(
            messages=fx.mutate_messages(pricing__monthly="Pro is $3.990/mo.")
        )
        d, hits = _reject_for(cand, "invariant")
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)
        self.assertTrue(hits)

    def test_price_swap_between_cadences_fails(self):
        # Monthly copy carrying the annual price is cadence/price drift.
        cand = fx.valid_candidate(
            messages=fx.mutate_messages(pricing__monthly="Pro is $39.99/mo.")
        )
        d, hits = _reject_for(cand, "invariant")
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)
        self.assertTrue(hits)

    def test_cadence_marker_drift_fails(self):
        # Monthly copy carrying an annual cadence marker.
        cand = fx.valid_candidate(
            messages=fx.mutate_messages(pricing__monthly="Pro is $3.99/yr.")
        )
        d, hits = _reject_for(cand, "invariant")
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)
        self.assertTrue(hits)

    def test_trial_length_drift_fails(self):
        cand = fx.valid_candidate(
            messages=fx.mutate_messages(pricing__trial="Start a 30-day free trial.")
        )
        d, hits = _reject_for(cand, "invariant")
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)
        self.assertTrue(hits)

    def test_missing_price_token_fails(self):
        cand = fx.valid_candidate(
            messages=fx.mutate_messages(pricing__annual="Pro is a great deal.")
        )
        d, hits = _reject_for(cand, "invariant")
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)
        self.assertTrue(hits)

    def test_urgent_tag_must_be_verbatim(self):
        cand = fx.valid_candidate(
            messages=fx.mutate_messages(contact__urgent_tag="Tag it urgent, please.")
        )
        d, hits = _reject_for(cand, "invariant")
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)
        self.assertTrue(hits, "[URGENT] literal tag must be preserved")


class InterpolationPlaceholders(unittest.TestCase):
    """Required placeholders in EVERY plural/select form."""

    def test_plural_other_form_missing_placeholder_fails(self):
        cand = fx.valid_candidate(
            messages=fx.mutate_messages(
                coach__rewrites_count={
                    "plural": {"one": "{count} rewrite", "other": "rewrites"}
                }
            )
        )
        d, hits = _reject_for(cand, "interpolation")
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)
        self.assertTrue(hits, "a plural form dropping {count} must fail")

    def test_plural_form_with_unexpected_placeholder_fails(self):
        cand = fx.valid_candidate(
            messages=fx.mutate_messages(
                coach__rewrites_count={
                    "plural": {
                        "one": "{count} rewrite",
                        "other": "{count} {oops} rewrites",
                    }
                }
            )
        )
        d, hits = _reject_for(cand, "interpolation")
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)
        self.assertTrue(hits)

    def test_unbalanced_braces_fail(self):
        cand = fx.valid_candidate(
            messages=fx.mutate_messages(
                coach__rewrites_count={
                    "plural": {"one": "{count} rewrite", "other": "{count rewrites"}
                }
            )
        )
        d, hits = _reject_for(cand, "interpolation")
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)
        self.assertTrue(hits)

    def test_select_forms_are_each_checked(self):
        # Select handling primitive: every branch is a form the gate must see.
        msg = {"select": {"a": "{name} sent", "b": "sent", "other": "{name} sent"}}
        forms = gates.iter_forms(msg)
        dropped = [name for name, text in forms if "{name}" not in text]
        self.assertIn("b", dropped)
        self.assertEqual(len(forms), 3)


class ForbiddenSafetyTokens(unittest.TestCase):
    """Clinical / crisis tokens rejected even under obfuscation."""

    OBFUSCATIONS = [
        "Reach the s.u.i.c.i.d.e line",           # dotted
        "Reach the s-u-i-c-i-d-e line",           # hyphenated
        "Call sui​cide help",  # zero-width
        "Cyrillic ѕuісіdе line",    # homoglyphs
        "Dial 9-8-8 now",                          # spaced number
        "Dial ９８８ now",             # fullwidth 988
        "self­harm resources",                # soft hyphen
        "p0is0n c0ntr0l center",                   # leetspeak
    ]

    def test_obfuscated_forbidden_tokens_rejected(self):
        for payload in self.OBFUSCATIONS:
            cand = fx.valid_candidate(
                messages=fx.mutate_messages(
                    pricing__recurrence_disclaimer=(
                        "Auto-renews at $3.99/mo or $39.99/yr after the 7-day "
                        "trial unless cancelled. " + payload
                    )
                )
            )
            d, hits = _reject_for(cand, "forbidden_safety")
            self.assertEqual(
                d.status, STATUS_NOT_ELIGIBLE, "not rejected: %r" % payload
            )
            self.assertTrue(hits, "no forbidden-safety hit for %r" % payload)

    def test_benign_number_is_not_a_false_positive(self):
        # 1988 must NOT trip the 988 crisis-number guard.
        cand = fx.valid_candidate(
            messages=fx.mutate_messages(
                coach__axis__warmer="Warmer since 1988"
            )
        )
        d = _evaluate(cand)
        self.assertNotIn(
            "forbidden_safety",
            " ".join(d.gate_failures),
            "1988 should not trip the 988 guard",
        )


class ExtlangPrefixValidation(unittest.TestCase):
    """RFC 5646 extlang prefix: en-yue must fail; zh-yue is fine."""

    def test_en_yue_is_invalid(self):
        cand = fx.valid_candidate(locale="en-yue")
        d = _evaluate(cand)
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)
        self.assertTrue(any("locale tag" in r for r in d.reasons))

    def test_unknown_extlang_is_invalid(self):
        cand = fx.valid_candidate(locale="en-zzz")
        d = _evaluate(cand)
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)

    def test_private_use_only_is_invalid(self):
        cand = fx.valid_candidate(locale="x-private")
        d = _evaluate(cand)
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)

    def test_malformed_tag_is_invalid(self):
        for bad in ("en--GB", "en-", "-en", "en_GB"):
            cand = fx.valid_candidate(locale=bad)
            d = _evaluate(cand)
            self.assertEqual(d.status, STATUS_NOT_ELIGIBLE, "accepted %r" % bad)


class ControlCharacterRejection(unittest.TestCase):
    def test_c0_control_in_message_rejected(self):
        cand = fx.valid_candidate(
            messages=fx.mutate_messages(
                coach__axis__clearer="Clear\x07er"  # BEL
            )
        )
        d, hits = _reject_for(cand, "controls")
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)
        self.assertTrue(hits)

    def test_c1_control_in_message_rejected(self):
        cand = fx.valid_candidate(
            messages=fx.mutate_messages(coach__axis__funnier="Fun\x85nier")
        )
        d, hits = _reject_for(cand, "controls")
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)
        self.assertTrue(hits)


class BlankReviewerRejection(unittest.TestCase):
    """Blank reviewer identity / credentials rejected (shape floor)."""

    def test_blank_identity_rejected(self):
        msgs = fx.valid_messages()
        att = fx.make_attestation(msgs, identity="   ")
        cand = fx.valid_candidate(messages=msgs, with_attestation=False)
        cand["attestation"] = att
        d = _evaluate(cand)
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)
        self.assertTrue(any("attestation" in r for r in d.reasons))

    def test_blank_credentials_rejected(self):
        msgs = fx.valid_messages()
        att = fx.make_attestation(msgs, credentials="")
        cand = fx.valid_candidate(messages=msgs, with_attestation=False)
        cand["attestation"] = att
        d = _evaluate(cand)
        self.assertEqual(d.status, STATUS_NOT_ELIGIBLE)


if __name__ == "__main__":
    unittest.main(verbosity=2)
