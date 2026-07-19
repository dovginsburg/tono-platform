"""Tests for the standalone coach output-hygiene validator.

These are dependency-free (stdlib ``unittest`` only) so they run without the
FastAPI/pydantic/httpx stack — mirroring how the module under test imports
nothing beyond the standard library. They are also collected by the repo's
pytest suite (``unittest.TestCase`` subclasses run under pytest unchanged).

Run standalone, no installs:  (from apps/)
    python3 -m unittest backend.tests.test_coach_output_hygiene -v
"""

from __future__ import annotations

import unittest

from backend.coach_output_hygiene import (
    RISK_REASON_MAX_WORDS,
    TOOL_NARRATION_PHRASES,
    Violation,
    count_words,
    find_tool_narration,
    is_clean,
    risk_reason_exceeds_ceiling,
    scan_coach_output,
)


# A representative CLEAN coach result, mirroring the shape and prose style
# that analyze.mock_analyze / enforce_coach_contract produce. Used to guard
# against false positives: real product output must scan clean.
CLEAN_RESULT = {
    "risk_level": "medium",
    "perception": "The ask is hard to act on without more detail. 🤔",
    "subtext": "wants a reply but won't ask directly",
    "risk_reason": "Ambiguous ask — no deadline or clear next step.",
    "suggestions": [
        {"axis": "warmer", "text": "Hey! Can you send the deck?",
         "rationale": "Adds a one-line validation before the ask."},
        {"axis": "clearer", "text": "Please tell me what you think by Friday.",
         "rationale": "Names the ask and a specific deadline."},
        {"axis": "funnier", "text": "Can you send the deck?",
         "rationale": "context doesn't call for humor"},
        {"axis": "safer", "text": "Following up on my last note about the deck.",
         "rationale": "Removes anything that could be read as guilt or cold."},
    ],
    "flags": ["ambiguous ask"],
}


class FindToolNarrationTests(unittest.TestCase):
    def test_detects_each_documented_phrase(self):
        # Every phrase the system prompt bans (analyze.py rule 5) is detected.
        for phrase in TOOL_NARRATION_PHRASES:
            with self.subTest(phrase=phrase):
                text = f"Well, {phrase} this reads as abrupt."
                self.assertIn(phrase, find_tool_narration(text))

    def test_case_insensitive(self):
        self.assertEqual(find_tool_narration("Based On your message, soften it."),
                         ["based on"])

    def test_word_boundary_no_false_match(self):
        # "based on" as a substring inside larger words must not trigger.
        self.assertEqual(find_tool_narration("I love my databased onlineshop."), [])

    def test_clean_prose_returns_empty(self):
        self.assertEqual(find_tool_narration("Adds a one-line validation before the ask."), [])
        self.assertEqual(find_tool_narration(""), [])

    def test_none_and_non_str_are_safe(self):
        self.assertEqual(find_tool_narration(None), [])  # type: ignore[arg-type]
        self.assertEqual(find_tool_narration(123), [])   # type: ignore[arg-type]

    def test_appearance_order_and_dedup(self):
        text = "Looking at it, my read is that, looking at it again, based on tone."
        self.assertEqual(find_tool_narration(text), ["looking at", "my read", "based on"])


class WordCountTests(unittest.TestCase):
    def test_counts_alnum_words_ignoring_punctuation(self):
        self.assertEqual(count_words("Lands cleanly — nothing stands out as risky."), 7)

    def test_empty_is_zero(self):
        self.assertEqual(count_words("   "), 0)
        self.assertEqual(count_words(None), 0)  # type: ignore[arg-type]

    def test_contractions_count_once(self):
        self.assertEqual(count_words("won't stop"), 2)

    def test_risk_reason_ceiling_boundary(self):
        twelve = " ".join(["word"] * 12)
        thirteen = " ".join(["word"] * 13)
        self.assertFalse(risk_reason_exceeds_ceiling(twelve))
        self.assertTrue(risk_reason_exceeds_ceiling(thirteen))
        self.assertEqual(RISK_REASON_MAX_WORDS, 12)


class ScanCoachOutputTests(unittest.TestCase):
    def test_clean_canonical_output_scans_clean(self):
        self.assertEqual(scan_coach_output(CLEAN_RESULT), [])
        self.assertTrue(is_clean(CLEAN_RESULT))

    def test_flags_filler_in_perception(self):
        bad = {**CLEAN_RESULT, "perception": "Based on your message, this lands cold."}
        violations = scan_coach_output(bad)
        self.assertTrue(any(v.field == "perception" and v.rule == "tool_narration"
                            for v in violations))
        self.assertFalse(is_clean(bad))

    def test_flags_filler_in_subtext_and_risk_reason(self):
        bad = {
            **CLEAN_RESULT,
            "subtext": "looking at it, they seem annoyed",
            "risk_reason": "My read is that this reads as cold.",
        }
        fields = {v.field for v in scan_coach_output(bad) if v.rule == "tool_narration"}
        self.assertIn("subtext", fields)
        self.assertIn("risk_reason", fields)

    def test_flags_filler_in_suggestion_rationale(self):
        bad = {
            **CLEAN_RESULT,
            "suggestions": [
                {"axis": "warmer", "text": "Hey! Can you send the deck?",
                 "rationale": "Based on the tone, this softens the ask."},
            ],
        }
        violations = scan_coach_output(bad)
        self.assertTrue(any(v.field == "suggestions[0].rationale" and v.rule == "tool_narration"
                            for v in violations))

    def test_does_not_flag_filler_in_rewrite_text(self):
        # The rewrite TEXT legitimately echoes the user's own words; a phrase
        # like "looking at" there must NOT be treated as coach filler.
        result = {
            **CLEAN_RESULT,
            "suggestions": [
                {"axis": "warmer", "text": "I'm looking at the report now — thanks!",
                 "rationale": "Adds a warm acknowledgement."},
            ],
        }
        self.assertEqual(scan_coach_output(result), [])

    def test_flags_overlong_risk_reason(self):
        bad = {**CLEAN_RESULT,
               "risk_reason": " ".join(["word"] * 13)}
        violations = scan_coach_output(bad)
        self.assertTrue(any(v.field == "risk_reason" and v.rule == "risk_reason_length"
                            for v in violations))

    def test_non_dict_and_missing_fields_are_safe(self):
        self.assertEqual(scan_coach_output(None), [])       # type: ignore[arg-type]
        self.assertEqual(scan_coach_output("nope"), [])     # type: ignore[arg-type]
        self.assertEqual(scan_coach_output({}), [])
        # suggestions present but not a list, and a non-dict suggestion entry.
        self.assertEqual(scan_coach_output({"suggestions": "x"}), [])
        self.assertEqual(scan_coach_output({"suggestions": ["x", 3]}), [])

    def test_violation_is_namedtuple_with_expected_fields(self):
        bad = {**CLEAN_RESULT, "perception": "Based on tone, soften it."}
        v = scan_coach_output(bad)[0]
        self.assertIsInstance(v, Violation)
        self.assertEqual(v.field, "perception")
        self.assertEqual(v.rule, "tool_narration")
        self.assertIsInstance(v.detail, str)


if __name__ == "__main__":
    unittest.main()
