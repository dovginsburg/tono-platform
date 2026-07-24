#!/usr/bin/env python3
"""Focused tests for immutable build SHA resolution."""
from __future__ import annotations

import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import prepare_provenance


LOWER_SHA = "0123456789abcdef0123456789abcdef01234567"
UPPER_SHA = LOWER_SHA.upper()
OTHER_SHA = "fedcba9876543210fedcba9876543210fedcba98"


class ResolveShaTests(unittest.TestCase):
    def test_vercel_sha_works_without_git_metadata(self) -> None:
        with (
            mock.patch.dict(os.environ, {"VERCEL_GIT_COMMIT_SHA": UPPER_SHA}, clear=True),
            mock.patch.object(prepare_provenance.subprocess, "check_output") as git,
        ):
            self.assertEqual(prepare_provenance.resolve_sha(), LOWER_SHA)
            git.assert_not_called()

    def test_explicit_and_environment_priority(self) -> None:
        cases = (
            (
                UPPER_SHA,
                {
                    "TONO_CANONICAL_SHA": OTHER_SHA,
                    "VERCEL_GIT_COMMIT_SHA": OTHER_SHA,
                    "GITHUB_SHA": OTHER_SHA,
                },
                LOWER_SHA,
            ),
            (
                None,
                {
                    "TONO_CANONICAL_SHA": UPPER_SHA,
                    "VERCEL_GIT_COMMIT_SHA": OTHER_SHA,
                    "GITHUB_SHA": OTHER_SHA,
                },
                LOWER_SHA,
            ),
            (
                None,
                {"VERCEL_GIT_COMMIT_SHA": UPPER_SHA, "GITHUB_SHA": OTHER_SHA},
                LOWER_SHA,
            ),
            (None, {"GITHUB_SHA": UPPER_SHA}, LOWER_SHA),
        )
        for explicit, environment, expected in cases:
            with self.subTest(explicit=explicit, environment=environment):
                with mock.patch.dict(os.environ, environment, clear=True):
                    self.assertEqual(prepare_provenance.resolve_sha(explicit), expected)

    def test_malformed_environment_sha_fails_closed(self) -> None:
        with mock.patch.dict(
            os.environ,
            {"VERCEL_GIT_COMMIT_SHA": "not-a-sha", "GITHUB_SHA": OTHER_SHA},
            clear=True,
        ):
            with self.assertRaisesRegex(ValueError, "40-character hexadecimal"):
                prepare_provenance.resolve_sha()

    def test_missing_environment_and_git_sha_fails_closed(self) -> None:
        with (
            mock.patch.dict(os.environ, {}, clear=True),
            mock.patch.object(
                prepare_provenance.subprocess,
                "check_output",
                side_effect=subprocess.CalledProcessError(128, ["git"]),
            ),
        ):
            with self.assertRaisesRegex(ValueError, "40-character hexadecimal"):
                prepare_provenance.resolve_sha()

    def test_local_git_fallback(self) -> None:
        with (
            mock.patch.dict(os.environ, {}, clear=True),
            mock.patch.object(
                prepare_provenance.subprocess,
                "check_output",
                return_value=UPPER_SHA + "\n",
            ) as git,
        ):
            self.assertEqual(prepare_provenance.resolve_sha(), LOWER_SHA)
            git.assert_called_once()


if __name__ == "__main__":
    unittest.main()
