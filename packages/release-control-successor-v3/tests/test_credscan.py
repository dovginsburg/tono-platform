"""Bounded, in-memory, no-I/O credential scan."""

from __future__ import annotations

import unittest

import tonoit_release_control as rc

from _hostile import (
    RaisingValue,
    fake_aws_key,
    fake_private_key_header,
    fake_token_assignment,
)


class CredScanTests(unittest.TestCase):
    def test_clean_lines_have_no_findings(self):
        res = rc.scan_credentials(["def evaluate(cfg, flag, ctx):", "return True"])
        self.assertEqual(res["findings"], 0)
        self.assertFalse(res["truncated"])

    def test_detects_aws_key(self):
        res = rc.scan_credentials(["value = " + fake_aws_key()])
        self.assertGreaterEqual(res["findings"], 1)

    def test_detects_private_key_header(self):
        res = rc.scan_credentials([fake_private_key_header()])
        self.assertGreaterEqual(res["findings"], 1)

    def test_detects_token_assignment(self):
        res = rc.scan_credentials([fake_token_assignment()])
        self.assertGreaterEqual(res["findings"], 1)

    def test_result_is_scalar_only(self):
        res = rc.scan_credentials(["x"])
        self.assertIs(type(res), dict)
        for value in res.values():
            self.assertIn(type(value), (bool, int))

    def test_bounded_line_count(self):
        many = ["clean"] * 100000
        res = rc.scan_credentials(many, max_lines=1000)
        self.assertLessEqual(res["scanned"], 1000)
        self.assertTrue(res["truncated"])

    def test_bounded_findings(self):
        secrets = [fake_aws_key()] * 5000
        res = rc.scan_credentials(secrets, max_findings=10)
        self.assertLessEqual(res["findings"], 10)
        self.assertTrue(res["truncated"])

    def test_hostile_inputs_never_raise(self):
        for bad in (None, 123, object(), {"a": 1}, [RaisingValue()], [object(), 5]):
            with self.subTest(inp=type(bad)):
                res = rc.scan_credentials(bad)
                self.assertIs(type(res), dict)
                self.assertEqual(res["findings"], 0)

    def test_long_line_is_truncated_for_work_bound(self):
        res = rc.scan_credentials(["a" * 1000000], max_line_len=128)
        self.assertIs(type(res), dict)
        self.assertEqual(res["scanned"], 1)


if __name__ == "__main__":
    unittest.main()
