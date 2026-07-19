"""Hostile regression 2: hostile-keyed dicts never make constructors raise.

Exact built-in dicts with hash-collision/raising-eq keys, hash-raising keys,
and hash-changing keys must never make ``ReleaseConfig`` / ``ReleaseRule``
constructors raise. Malformed/custom mappings fail closed and cannot enable
any known or unknown flag.
"""

from __future__ import annotations

import unittest

import tonoit_release_control as rc

from _hostile import (
    CountingKey,
    ExplodingItems,
    HashChangingKey,
    HashRaisesLaterKey,
    RaisingEqKey,
    RaisingValue,
    StrSubclassKey,
)


def _hostile_dicts():
    return [
        ("raising_eq", {RaisingEqKey(): True}),
        ("hash_raises_later", {HashRaisesLaterKey(): True}),
        ("hash_changing", {HashChangingKey(): True}),
        ("str_subclass_key", {StrSubclassKey("beta"): True}),
        ("hostile_value", {"beta": RaisingValue()}),
        ("mixed_str_and_hostile", {"beta": True, RaisingEqKey(): True}),
    ]


class HostileDictConstructorTests(unittest.TestCase):
    def test_releaseconfig_never_raises_on_hostile_flags(self):
        for label, payload in _hostile_dicts():
            with self.subTest(case=label):
                cfg = rc.ReleaseConfig(flags=payload)  # must not raise
                self.assertTrue(rc.is_valid_config(cfg))

    def test_releaserule_from_mapping_never_raises(self):
        for label, payload in _hostile_dicts():
            with self.subTest(case=label):
                rule = rc.ReleaseRule.from_mapping(payload)  # must not raise
                self.assertFalse(rule.valid)

    def test_releaserule_hostile_allowlist_never_raises(self):
        # A dict where a list/set is expected is malformed -> empty allowlist.
        rule = rc.ReleaseRule("beta", allowlist={RaisingEqKey(): True})
        self.assertEqual(len(rule.allowlist), 0)

    def test_custom_mapping_fails_closed(self):
        cfg = rc.ReleaseConfig(flags=ExplodingItems())  # not an exact dict
        self.assertTrue(rc.is_valid_config(cfg))
        ctx = rc.EvaluationContext("s", now=1000.0)
        self.assertFalse(rc.is_released(cfg, "beta", ctx))

    def test_hostile_dict_enables_nothing(self):
        ctx = rc.EvaluationContext("subject", now=1000.0)
        for label, payload in _hostile_dicts():
            with self.subTest(case=label):
                cfg = rc.ReleaseConfig(flags=payload)
                # Neither the genuine-looking "beta" nor any unknown flag enabled.
                self.assertFalse(rc.is_released(cfg, "beta", ctx))
                self.assertFalse(rc.is_released(cfg, "anything", ctx))

    def test_mixed_map_does_not_enable_genuine_key(self):
        # A dict carrying a hostile key alongside a genuine str key is malformed
        # as a whole and must not enable the genuine "beta" flag.
        cfg = rc.ReleaseConfig(flags={"beta": True, RaisingEqKey(): True})
        ctx = rc.EvaluationContext("subject", now=1000.0)
        self.assertFalse(rc.is_released(cfg, "beta", ctx))

    def test_clean_flag_map_still_works(self):
        cfg = rc.ReleaseConfig(flags={"beta": True})
        ctx = rc.EvaluationContext("subject", now=1000.0)
        self.assertTrue(rc.is_released(cfg, "beta", ctx))

    def test_constructor_does_not_rehash_caller_keys(self):
        payload = {CountingKey(): True}
        CountingKey.reset()
        rc.ReleaseConfig(flags=payload)
        rc.ReleaseRule.from_mapping(payload)
        self.assertEqual(CountingKey.hashes, 0)
        self.assertEqual(CountingKey.eqs, 0)


if __name__ == "__main__":
    unittest.main()
