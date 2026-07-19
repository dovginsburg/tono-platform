"""Repro class 1 — RollbackReceipt equality/hash-mimic caller-object leak.

A hostile object whose equality/hash mimic an allowed rollback mode must never
be retained or emitted.  The receipt must store the canonical enum member (or
the inert safe default), and its serialized output must pass the package
validator and contain built-in finite scalars only.
"""
import unittest

from release_control_successor_v2 import (
    RollbackMode,
    RollbackReceipt,
    validate_rollback_receipt,
)
from tests.hostile import EqualityHashMimic


class RollbackReceiptLeakTest(unittest.TestCase):
    def test_equality_hash_mimic_is_not_retained_or_emitted(self):
        hostile = EqualityHashMimic(RollbackMode.HALT, value="halt")
        receipt = RollbackReceipt(mode=hostile, capability_class=None, reason=None)

        # If the hostile object had been retained, mutating it here would change
        # the serialized output — proving a live caller-object reference leaked.
        hostile.value = "LEAKED-CALLER-SECRET"

        payload = receipt.to_dict()
        self.assertEqual(payload["mode"], "none")
        self.assertNotIn("LEAKED-CALLER-SECRET", list(payload.values()))
        self.assertIs(type(payload["mode"]), str)
        self.assertTrue(validate_rollback_receipt(payload))
        # The canonical inert member is retained, never the hostile object.
        self.assertIs(receipt.mode, RollbackMode.NONE)

    def test_mimic_of_valid_value_still_coerced_to_inert_default(self):
        # Even when the mimic would emit a *valid* mode string, retaining a
        # foreign object is forbidden; it must coerce to the inert default.
        hostile = EqualityHashMimic(RollbackMode.REVERT, value="revert")
        receipt = RollbackReceipt(hostile, None, None)
        self.assertIs(receipt.mode, RollbackMode.NONE)
        self.assertEqual(receipt.to_dict()["mode"], "none")

    def test_real_mode_is_preserved(self):
        receipt = RollbackReceipt(RollbackMode.HALT, None, None)
        self.assertIs(receipt.mode, RollbackMode.HALT)
        self.assertEqual(receipt.to_dict()["mode"], "halt")
        self.assertTrue(validate_rollback_receipt(receipt.to_dict()))


if __name__ == "__main__":
    unittest.main()
