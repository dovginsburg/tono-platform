"""Focused, hostile, stdlib-only tests for ``backend.coach_output_hygiene``.

Runnable without any third-party package or network:

    cd apps && python3 -m unittest backend.tests.test_coach_output_hygiene -v

The suite is written as ``unittest`` (not pytest) on purpose: the default-off
hygiene validator is standalone and stdlib-only, so its tests must run under a
bare interpreter with nothing installed.

Source-hygiene rule: every zero-width, format, bidi, combining, or otherwise
invisible / visually-ambiguous probe character is built from a named
``chr(0x...)`` constant, so the *source* stays pure ASCII and reviewable. Only
unambiguously visible glyphs (Cyrillic / CJK letters, precomposed accented
Latin, fullwidth letters, prose em dashes, emoji) appear as literals.

Gate coverage (Sherlock RED -> GREEN):
  * Unicode-safe word counting: accented Latin == one word; 13 Cyrillic and 13
    whitespace-separated CJK words are rejected against the <=12 ceiling.
  * U+200B / U+200C and related default-ignorable format separators must not
    let a banned phrase slip through -- at a word boundary or glued inside a
    word.
  * Whitespace, dash punctuation, and default-ignorable separators between
    phrase words are equivalent narration separators -- while real word
    boundaries are preserved (no substring false positives).
  * Rewrite exclusion, malformed inputs, casefold/NFKC compatibility, clean
    boundaries, and import isolation.
"""

from __future__ import annotations

import ast
import copy
import unittest

from backend import coach_output_hygiene as hy


# --- invisible / ambiguous probe characters (pure-ASCII source) ------------

ZWSP = chr(0x200B)   # ZERO WIDTH SPACE            (Cf)
ZWNJ = chr(0x200C)   # ZERO WIDTH NON-JOINER       (Cf)
ZWJ = chr(0x200D)    # ZERO WIDTH JOINER           (Cf)
BOM = chr(0xFEFF)    # ZERO WIDTH NO-BREAK SPACE   (Cf)
SHY = chr(0x00AD)    # SOFT HYPHEN                 (Cf)
LRE = chr(0x202A)    # LEFT-TO-RIGHT EMBEDDING     (Cf, bidi)
WJ = chr(0x2060)     # WORD JOINER                 (Cf)
IDSP = chr(0x3000)   # IDEOGRAPHIC SPACE           (Zs)
MINUS = chr(0x2212)  # MINUS SIGN                  (Sm, NOT dash punctuation)
ACUTE = chr(0x0301)  # COMBINING ACUTE ACCENT      (Mn)

# Every code point below is Unicode general category Pd (Dash_Punctuation):
# ASCII hyphen, hyphen, non-breaking hyphen, figure/en/em dash, horizontal bar,
# fullwidth hyphen-minus, small hyphen-minus.
DASHES = [chr(c) for c in (0x2D, 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0xFF0D, 0xFE63)]
EMDASH = chr(0x2014)


# --- helpers ---------------------------------------------------------------

def _clean_result() -> dict:
    """A representative, hygienic coach payload (ToneAnalysis-shaped)."""
    return {
        "risk_level": "low",
        "perception": "Lands cleanly. ✅",
        "subtext": "calm, neutral",
        "risk_reason": "Lands cleanly — nothing stands out as risky.",
        "suggestions": [
            {"axis": "warmer", "text": "Hey! ...", "rationale": "Adds a one-line validation before the ask."},
            {"axis": "clearer", "text": "...", "rationale": "Names the ask and a specific deadline."},
            {"axis": "funnier", "text": "...", "rationale": "context doesn't call for humor"},
            {"axis": "safer", "text": "...", "rationale": "Removes anything that could read as guilt or cold."},
        ],
        "flags": [],
    }


def _codes(findings):
    return [f.code for f in findings]


def _fields(findings):
    return [f.field for f in findings]


# --- word counting ---------------------------------------------------------

class TestUnicodeWordCounting(unittest.TestCase):
    def test_accented_latin_precomposed_is_one_word(self):
        self.assertEqual(hy.count_words("café"), 1)  # U+00E9 precomposed

    def test_accented_latin_decomposed_is_one_word(self):
        # "cafe" + U+0301 COMBINING ACUTE ACCENT must not split into two words.
        self.assertEqual(hy.count_words("cafe" + ACUTE), 1)

    def test_accented_latin_phrase_counts_each_word_once(self):
        self.assertEqual(hy.count_words("naïve café résumé"), 3)

    def test_thirteen_cyrillic_words_exceeds_ceiling(self):
        text = " ".join(["слово"] * 13)
        self.assertEqual(hy.count_words(text), 13)
        findings = hy.check_risk_reason_length(text)
        self.assertEqual(_codes(findings), ["risk_reason_too_long"])
        self.assertEqual(findings[0].word_count, 13)

    def test_thirteen_cjk_words_whitespace_separated_exceeds_ceiling(self):
        text = " ".join(["测试"] * 13)  # 13 space-separated CJK tokens
        self.assertEqual(hy.count_words(text), 13)
        self.assertEqual(_codes(hy.check_risk_reason_length(text)), ["risk_reason_too_long"])

    def test_thirteen_cjk_words_ideographic_space_separated(self):
        text = IDSP.join(["漢字"] * 13)  # separated by IDEOGRAPHIC SPACE
        self.assertEqual(hy.count_words(text), 13)
        self.assertEqual(_codes(hy.check_risk_reason_length(text)), ["risk_reason_too_long"])

    def test_cjk_run_without_whitespace_is_one_word(self):
        # 26 CJK code points glued together are ONE word, not 26.
        self.assertEqual(hy.count_words("测试" * 13), 1)

    def test_zero_width_does_not_fabricate_a_word_boundary(self):
        self.assertEqual(hy.count_words("one" + ZWSP + "two"), 1)

    def test_lone_punctuation_run_is_not_counted_as_a_word(self):
        # A spaced em dash is punctuation, not a word, so a 12-word risk_reason
        # that uses one (the coach's own house style) still passes the ceiling.
        self.assertEqual(hy.count_words("Lands cleanly — nothing stands out as risky."), 7)
        twelve_with_dash = "alpha beta gamma delta — epsilon zeta eta theta iota kappa lambda mu"
        self.assertEqual(hy.count_words(twelve_with_dash), 12)
        self.assertEqual(hy.check_risk_reason_length(twelve_with_dash), [])

    def test_twelve_words_is_the_boundary_and_passes(self):
        twelve = " ".join(str(n) for n in range(12))
        self.assertEqual(hy.count_words(twelve), 12)
        self.assertEqual(hy.check_risk_reason_length(twelve), [])

    def test_thirteen_words_is_over_the_boundary_and_fails(self):
        thirteen = " ".join(str(n) for n in range(13))
        self.assertEqual(hy.count_words(thirteen), 13)
        self.assertEqual(_codes(hy.check_risk_reason_length(thirteen)), ["risk_reason_too_long"])


# --- banned phrase detection ----------------------------------------------

class TestBannedPhraseDetection(unittest.TestCase):
    def test_every_banned_phrase_is_detected_in_isolation(self):
        for phrase in hy.BANNED_TOOL_NARRATION_PHRASES:
            self.assertIn(phrase, hy.find_banned_phrases(phrase), phrase)

    def test_banned_phrase_detected_inside_a_sentence(self):
        self.assertEqual(
            hy.find_banned_phrases("Reads warm based on the sign-off."),
            ["based on"],
        )

    def test_clean_text_reports_nothing(self):
        for good in [
            "Lands cleanly — nothing stands out as risky.",
            "Ambiguous ask — no deadline or clear next step.",
            "calm, neutral",
            "",
        ]:
            self.assertEqual(hy.find_banned_phrases(good), [], repr(good))

    def test_detection_is_case_insensitive(self):
        self.assertEqual(hy.find_banned_phrases("BASED ON the tone"), ["based on"])
        self.assertEqual(hy.find_banned_phrases("Looking At the draft"), ["looking at"])

    def test_nfkc_fullwidth_compatibility_forms_are_detected(self):
        # Fullwidth latin + IDEOGRAPHIC SPACE must fold to ASCII "looking at".
        self.assertEqual(hy.find_banned_phrases("ＬＯＯＫＩＮＧ" + IDSP + "ＡＴ"), ["looking at"])
        self.assertEqual(hy.find_banned_phrases("ｂａｓｅｄ ｏｎ"), ["based on"])

    def test_zero_width_space_at_boundary_does_not_bypass(self):
        self.assertEqual(hy.find_banned_phrases("based" + ZWSP + "on the reply"), ["based on"])

    def test_zero_width_nonjoiner_at_boundary_does_not_bypass(self):
        self.assertEqual(hy.find_banned_phrases("based" + ZWNJ + "on the reply"), ["based on"])

    def test_zero_width_joiner_at_boundary_does_not_bypass(self):
        self.assertEqual(hy.find_banned_phrases("looking" + ZWJ + "at the draft"), ["looking at"])

    def test_zero_width_inside_a_word_does_not_bypass(self):
        # Obfuscation glued *inside* a word must still be caught (removal pass).
        self.assertEqual(hy.find_banned_phrases("ba" + ZWSP + "sed on it"), ["based on"])
        self.assertEqual(hy.find_banned_phrases("look" + ZWSP + "ing at it"), ["looking at"])
        self.assertEqual(hy.find_banned_phrases("my re" + ZWSP + "ad of it"), ["my read"])

    def test_combined_boundary_and_intraword_zero_width_does_not_bypass(self):
        # A zero-width character inside a word AND at the seam at the same time
        # must still be caught (single position-aware scan, not two global passes).
        self.assertEqual(hy.find_banned_phrases("ba" + ZWSP + "sed" + ZWSP + "on"), ["based on"])
        self.assertEqual(hy.find_banned_phrases("look" + ZWNJ + "ing" + ZWNJ + "at"), ["looking at"])
        self.assertEqual(hy.find_banned_phrases("my" + ZWSP + "re" + ZWSP + "ad"), ["my read"])
        self.assertEqual(hy.find_banned_phrases("I" + BOM + "chec" + BOM + "ked"), ["I checked"])

    def test_hard_separator_inside_a_word_is_not_a_phrase(self):
        # A real whitespace or dash INSIDE a phrase word breaks it -> no match.
        self.assertEqual(hy.find_banned_phrases("bas ed on"), [])
        self.assertEqual(hy.find_banned_phrases("look ing at"), [])
        self.assertEqual(hy.find_banned_phrases("my rea d"), [])

    def test_bom_soft_hyphen_and_bidi_controls_are_separators(self):
        self.assertEqual(hy.find_banned_phrases("based" + BOM + "on"), ["based on"])
        self.assertEqual(hy.find_banned_phrases("based" + SHY + "on"), ["based on"])
        self.assertEqual(hy.find_banned_phrases("based" + LRE + "on"), ["based on"])
        self.assertEqual(hy.find_banned_phrases("looking" + WJ + "at"), ["looking at"])

    def test_dash_punctuation_is_an_equivalent_separator(self):
        for sep in DASHES:
            self.assertEqual(hy.find_banned_phrases("looking" + sep + "at"), ["looking at"], repr(sep))

    def test_mixed_separators_between_phrase_words(self):
        self.assertEqual(hy.find_banned_phrases("looking " + ZWSP + "-" + EMDASH + " at"), ["looking at"])
        self.assertEqual(hy.find_banned_phrases("based " + EMDASH + ZWSP + " on"), ["based on"])

    def test_word_boundaries_are_preserved_no_substring_false_positive(self):
        for benign in [
            "rebased on the branch",     # 'rebased' != 'based'
            "based online only",         # 'online' != 'on'
            "he checked the note",       # 'he' != 'i'
            "my reading of the room",    # 'reading' != 'read'
            "summary of the thread",     # 'summary' != 'my'
            "overlooking a typo",        # 'overlooking' != 'looking'
        ]:
            self.assertEqual(hy.find_banned_phrases(benign), [], benign)

    def test_glued_without_a_separator_is_not_a_phrase(self):
        for glued in ["basedon", "lookingat", "myread", "icheckedit"]:
            self.assertEqual(hy.find_banned_phrases(glued), [], glued)

    def test_math_minus_sign_is_not_dash_punctuation(self):
        # U+2212 MINUS SIGN is category Sm, not Pd: intentionally NOT a
        # narration separator. Pins the exact separator boundary.
        self.assertEqual(hy.find_banned_phrases("looking" + MINUS + "at"), [])


# --- per-field checks over a full payload ----------------------------------

class TestCoachOutputFields(unittest.TestCase):
    def test_banned_phrase_flagged_in_perception(self):
        r = _clean_result()
        r["perception"] = "Reads warm, based on the sign-off. ✅"
        findings = hy.check_coach_output(r)
        self.assertIn("perception", _fields(findings))
        self.assertTrue(all(f.code != "malformed_payload" for f in findings))

    def test_banned_phrase_flagged_in_subtext(self):
        r = _clean_result()
        r["subtext"] = "looking at how they'll take it"
        self.assertIn("subtext", _fields(hy.check_coach_output(r)))

    def test_banned_phrase_flagged_in_risk_reason(self):
        r = _clean_result()
        r["risk_reason"] = "My read — could feel abrupt."
        codes_by_field = {f.field: f.code for f in hy.check_coach_output(r)}
        self.assertEqual(codes_by_field.get("risk_reason"), "banned_tool_narration")

    def test_banned_phrase_flagged_in_each_suggestion_rationale_with_index(self):
        r = _clean_result()
        r["suggestions"][2]["rationale"] = "based on the light register"
        findings = hy.check_coach_output(r)
        self.assertIn("suggestions[2].rationale", _fields(findings))

    def test_clean_payload_is_clean(self):
        self.assertEqual(hy.check_coach_output(_clean_result()), [])
        self.assertTrue(hy.is_clean(_clean_result()))

    def test_risk_reason_length_flagged_via_full_check(self):
        r = _clean_result()
        r["risk_reason"] = " ".join(["слово"] * 13)  # 13 Cyrillic, no banned phrase
        codes = _codes(hy.check_coach_output(r))
        self.assertIn("risk_reason_too_long", codes)
        self.assertNotIn("banned_tool_narration", codes)

    def test_both_banned_and_too_long_can_be_reported(self):
        r = _clean_result()
        r["risk_reason"] = "based on " + " ".join(str(n) for n in range(13))
        codes = _codes([f for f in hy.check_coach_output(r) if f.field == "risk_reason"])
        self.assertIn("banned_tool_narration", codes)
        self.assertIn("risk_reason_too_long", codes)


# --- malformed inputs (must never raise) -----------------------------------

class TestMalformedInputs(unittest.TestCase):
    def test_none_payload_is_reported_not_raised(self):
        self.assertEqual(_codes(hy.check_coach_output(None)), ["malformed_payload"])

    def test_non_mapping_payloads_are_reported_not_raised(self):
        for bad in ["based on", 123, ["based on"], ("looking at",), 3.14, True]:
            self.assertEqual(_codes(hy.check_coach_output(bad)), ["malformed_payload"], repr(bad))

    def test_string_payload_is_not_scanned_as_fields(self):
        # A bare string must not be treated as a coach field and phrase-scanned.
        self.assertEqual(_codes(hy.check_coach_output("based on it")), ["malformed_payload"])

    def test_non_string_fields_are_skipped_without_error(self):
        r = {"perception": 123, "subtext": None, "risk_reason": ["x"], "suggestions": None, "flags": []}
        self.assertEqual(hy.check_coach_output(r), [])

    def test_suggestions_not_a_list_is_skipped(self):
        for bad in ["nope", 5, None, {"rationale": "based on it"}]:
            r = _clean_result()
            r["suggestions"] = bad
            self.assertNotIn("banned_tool_narration", _codes(hy.check_coach_output(r)))

    def test_suggestion_items_of_wrong_shape_are_skipped(self):
        r = _clean_result()
        r["suggestions"] = [None, 42, "x", {"rationale": 123}, {"rationale": "based on it"}]
        self.assertEqual(_fields(hy.check_coach_output(r)), ["suggestions[4].rationale"])

    def test_empty_dict_is_clean(self):
        self.assertEqual(hy.check_coach_output({}), [])

    def test_count_words_tolerates_non_string(self):
        for bad in [None, 5, [], {}]:
            self.assertEqual(hy.count_words(bad), 0)


# --- rewrite exclusion (report-only) ---------------------------------------

class TestRewriteExclusion(unittest.TestCase):
    def test_input_payload_is_never_mutated(self):
        r = _clean_result()
        r["perception"] = "based on the tone"
        r["risk_reason"] = " ".join(str(n) for n in range(20))
        r["suggestions"][0]["rationale"] = "looking at the ask"
        before = copy.deepcopy(r)
        hy.check_coach_output(r)
        self.assertEqual(r, before)

    def test_module_exposes_no_text_mutating_api(self):
        for forbidden in ["rewrite", "sanitize", "fix", "redact", "scrub",
                          "clean_text", "correct", "strip_banned", "replace"]:
            self.assertFalse(hasattr(hy, forbidden), forbidden)

    def test_finding_carries_no_replacement_text(self):
        import dataclasses
        r = _clean_result()
        r["perception"] = "based on the tone"
        finding = hy.check_coach_output(r)[0]
        field_names = {f.name for f in dataclasses.fields(finding)}
        for leak in {"replacement", "suggested_text", "rewrite", "fixed", "corrected"}:
            self.assertNotIn(leak, field_names)


# --- import isolation / stdlib-only ----------------------------------------

class TestImportIsolation(unittest.TestCase):
    ALLOWED_ROOTS = {"__future__", "unicodedata", "dataclasses", "collections", "typing"}

    def _import_roots(self):
        with open(hy.__file__, "r", encoding="utf-8") as fh:
            tree = ast.parse(fh.read())
        roots = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                roots.update(alias.name.split(".")[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                if node.level == 0 and node.module:
                    roots.add(node.module.split(".")[0])
                elif node.level:  # any relative import would break standalone-ness
                    roots.add("<relative>")
        return roots

    def test_module_imports_only_stdlib(self):
        self.assertTrue(self._import_roots() <= self.ALLOWED_ROOTS, self._import_roots())

    def test_module_does_not_import_the_app_stack(self):
        roots = self._import_roots()
        for banned in ["backend", "analyze", "fastapi", "pydantic", "httpx", "<relative>"]:
            self.assertNotIn(banned, roots, banned)


if __name__ == "__main__":
    unittest.main(verbosity=2)
