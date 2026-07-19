"""RED repros: malformed exact-type tuple-backed instances.

Every public validator must return ``False`` for empty, short and forged
tuple-backed instances -- never raise, never falsely accept.
"""

from __future__ import annotations

import math
import unittest

import tonoit_release_control_v5 as rc

from ._helpers import (
    CallTrap,
    HashTrap,
    empty_instance,
    forged_instance,
    short_instance,
)


VALIDATORS = (
    rc.is_valid_release_config,
    rc.is_valid_evaluation_context,
    rc.is_valid_audit_receipt,
)

MODELS = (rc.ReleaseConfig, rc.EvaluationContext, rc.AuditReceipt)


class TestMalformedRejected(unittest.TestCase):
    def test_empty_tuple_new_rejected_by_every_validator(self):
        # tuple.__new__(Model, ()) -- the canonical malformed instance.
        for model in MODELS:
            inst = empty_instance(model)
            for validator in VALIDATORS:
                self.assertIs(validator(inst), False)

    def test_short_tuples_rejected(self):
        for model in MODELS:
            for n in range(0, 3):
                inst = short_instance(model, [0] * n)
                for validator in VALIDATORS:
                    self.assertIs(validator(inst), False)

    def test_forged_tuples_with_wrong_types_rejected(self):
        # Right arity for each real validator, but garbage contents.
        garbage = ["x", None, object(), CallTrap(), HashTrap(), [], {}, 1.5]
        for model in MODELS:
            inst = forged_instance(model, garbage[: len(model._fields)])
            for validator in VALIDATORS:
                self.assertIs(validator(inst), False)

    def test_validators_never_raise_on_hostile_input(self):
        hostile = [
            None,
            object(),
            (),
            [],
            {},
            "not-a-model",
            123,
            empty_instance(rc.ReleaseConfig),
            forged_instance(rc.ReleaseConfig, [HashTrap()] * len(rc.ReleaseConfig._fields)),
        ]
        for validator in VALIDATORS:
            for h in hostile:
                try:
                    result = validator(h)
                except Exception as exc:  # noqa: BLE001 - test asserts totality
                    self.fail(f"{validator.__name__} raised on {h!r}: {exc!r}")
                self.assertIsInstance(result, bool)

    def test_foreign_tuple_not_falsely_accepted(self):
        # A plain tuple of the right length/values is not a model instance.
        self.assertIs(rc.is_valid_release_config(("n", True, False, 1, 1, 1.0, 500, frozenset())), False)
        self.assertIs(rc.is_valid_evaluation_context((1, 1, True, 1.0, 0.0, "c")), False)

    def test_nan_inf_scalars_rejected(self):
        cfg = forged_instance(
            rc.ReleaseConfig,
            ["n", True, False, 1, 1, math.inf, 500, frozenset()],
        )
        self.assertIs(rc.is_valid_release_config(cfg), False)
        cfg2 = forged_instance(
            rc.ReleaseConfig,
            ["n", True, False, 1, 1, math.nan, 500, frozenset()],
        )
        self.assertIs(rc.is_valid_release_config(cfg2), False)

    def test_canonical_config_is_valid(self):
        # Sanity: a genuine instance is accepted (no false negatives).
        self.assertIs(rc.is_valid_release_config(rc.CANONICAL_CONFIG), True)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
