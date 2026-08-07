"""Focused tests for the Coach output-hygiene validator.

Written with the stdlib :mod:`unittest` framework so the suite runs with no
third-party installs (``python3 -m unittest`` and, when present, ``pytest``).

This is the *only* module permitted to import ``backend.coach_output_hygiene``
(import-isolation contract). The complete-property Unicode sweep reads the
official Unicode 13.0.0 ``DerivedCoreProperties.txt`` that lives, untracked, in
``controller-artifacts/``; the authoritative expected set is parsed here,
independently of the implementation's pinned table.
"""

from __future__ import annotations

import ast
import copy
import hashlib
import pathlib
import sys
import unittest

# ``pythonpath = ..`` (pytest.ini) puts ``apps/`` on the path so ``backend`` is
# importable. Replicate that for a bare ``python3 -m unittest`` invocation.
_TESTS_DIR = pathlib.Path(__file__).resolve().parent
_BACKEND_DIR = _TESTS_DIR.parent
_APPS_DIR = _BACKEND_DIR.parent
_REPO_ROOT = _APPS_DIR.parent
if str(_APPS_DIR) not in sys.path:
    sys.path.insert(0, str(_APPS_DIR))

from backend.coach_output_hygiene import (  # noqa: E402
    BANNED_TOOL_NARRATION_CODE,
    BANNED_TOOL_NARRATION_PHRASES,
    COACH_AUTHORED_TEXT_FIELDS,
    DEFAULT_IGNORABLE_RANGES,
    DERIVED_CORE_PROPERTIES_SHA256,
    DERIVED_CORE_PROPERTIES_URL,
    Finding,
    RISK_REASON_MAX_WORDS,
    RISK_REASON_WORD_LIMIT_CODE,
    UNICODE_VERSION,
    is_default_ignorable,
    scan_coach_output,
)

MODULE_PATH = _BACKEND_DIR / "coach_output_hygiene.py"

# Representative default-ignorable code points exercised throughout.
ZWSP = "​"          # ZERO WIDTH SPACE (Cf)
ZWNJ = "‌"          # ZERO WIDTH NON-JOINER (Cf)
CGJ = "͏"           # COMBINING GRAPHEME JOINER (Mn, non-Cf)
VS16 = "️"          # VARIATION SELECTOR-16 (Mn, non-Cf)
VS17 = "\U000e0100"      # VARIATION SELECTOR-17 (Mn, non-Cf, astral)
# A *non*-default-ignorable combining mark (Mn, non-composing): token content,
# NOT transparent -- so it must not be able to fabricate an outer phrase edge.
COMBINING_MARK = "͙"  # COMBINING ASTERISK BELOW


def _analysis(**overrides):
    """A structurally complete, hygienically clean coach payload."""
    base = {
        "risk_level": "low",
        "perception": "Lands cleanly here.",
        "subtext": "calm and neutral",
        "risk_reason": "Direct ask with a deadline.",
        "suggestions": [
            {
                "axis": "warmer",
                "text": "Hey, could you help me with this when you get a sec?",
                "rationale": "adds a warm opener",
                "risk_after": "low",
            }
        ],
        "flags": [],
    }
    base.update(overrides)
    return base


def _with_rationale(rationale):
    return _analysis(
        suggestions=[
            {"axis": "warmer", "text": "Could you help with this?", "rationale": rationale}
        ]
    )


def _codes(findings):
    return sorted(f.code for f in findings)


def _phrases_for_field(findings, field):
    return {
        f.detail
        for f in findings
        if f.code == BANNED_TOOL_NARRATION_CODE and f.field == field
    }


def _impl_member_set():
    members = set()
    for lo, hi in DEFAULT_IGNORABLE_RANGES:
        members.update(range(lo, hi + 1))
    return members


def _parse_official_dicp(path):
    """Independently parse Default_Ignorable_Code_Point from the official file.

    Deliberately does NOT consult the implementation's pinned table.
    """
    members = set()
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        field, _, prop = line.partition(";")
        if prop.strip() != "Default_Ignorable_Code_Point":
            continue
        field = field.strip()
        if ".." in field:
            lo_s, hi_s = field.split("..")
            lo, hi = int(lo_s, 16), int(hi_s, 16)
        else:
            lo = hi = int(field, 16)
        members.update(range(lo, hi + 1))
    return members


class TestHardDefaultOff(unittest.TestCase):
    def test_disabled_by_default_returns_no_findings(self):
        dirty = _analysis(perception="I checked and, based on my read, looking at this…")
        # No keyword at all -> must be inert.
        self.assertEqual(scan_coach_output(dirty), [])

    def test_explicit_disabled_returns_no_findings(self):
        dirty = _analysis(perception="based on the thread")
        self.assertEqual(scan_coach_output(dirty, enabled=False), [])

    def test_enabled_is_required_to_produce_findings(self):
        dirty = _analysis(perception="based on the thread")
        self.assertTrue(scan_coach_output(dirty, enabled=True))

    def test_enabled_is_keyword_only(self):
        with self.assertRaises(TypeError):
            scan_coach_output(_analysis(), True)  # type: ignore[misc]


class TestBannedPhraseDetection(unittest.TestCase):
    def test_each_phrase_detected_in_each_authored_field(self):
        for phrase in BANNED_TOOL_NARRATION_PHRASES:
            for field in COACH_AUTHORED_TEXT_FIELDS:
                payload = _analysis(**{field: f"Well, {phrase} it lands cold."})
                findings = scan_coach_output(payload, enabled=True)
                self.assertIn(
                    phrase.casefold(),
                    {p.casefold() for p in _phrases_for_field(findings, field)},
                    msg=f"{phrase!r} not detected in {field}",
                )

    def test_detected_in_suggestion_rationale_with_indexed_label(self):
        payload = _analysis(
            suggestions=[
                {"axis": "warmer", "text": "Could you help?", "rationale": "clean"},
                {"axis": "clearer", "text": "Please help.", "rationale": "based on the tone"},
            ]
        )
        findings = scan_coach_output(payload, enabled=True)
        self.assertEqual(
            _phrases_for_field(findings, "suggestions[1].rationale"), {"based on"}
        )

    def test_case_insensitive(self):
        payload = _analysis(perception="BASED ON the thread, it reads cold.")
        self.assertEqual(_phrases_for_field(scan_coach_output(payload, enabled=True),
                                            "perception"), {"based on"})

    def test_multiple_phrases_multiple_fields(self):
        payload = _analysis(
            perception="looking at the ask, it is vague",
            subtext="my read is that they are annoyed",
        )
        findings = scan_coach_output(payload, enabled=True)
        self.assertEqual(_phrases_for_field(findings, "perception"), {"looking at"})
        self.assertEqual(_phrases_for_field(findings, "subtext"), {"my read"})

    def test_clean_payload_has_no_findings(self):
        self.assertEqual(scan_coach_output(_analysis(), enabled=True), [])

    def test_returns_finding_instances(self):
        payload = _analysis(perception="based on the thread")
        findings = scan_coach_output(payload, enabled=True)
        self.assertTrue(all(isinstance(f, Finding) for f in findings))


class TestRewriteExclusion(unittest.TestCase):
    def test_rewrite_text_is_never_scanned(self):
        payload = _analysis(
            suggestions=[
                {
                    "axis": "warmer",
                    "text": "Based on our chat, looking at it, my read: I checked twice.",
                    "rationale": "keeps it warm",
                }
            ]
        )
        self.assertEqual(scan_coach_output(payload, enabled=True), [])

    def test_top_level_rewrite_field_is_ignored(self):
        payload = _analysis()
        payload["rewrite"] = "based on the thread, looking at my read"
        self.assertEqual(scan_coach_output(payload, enabled=True), [])

    def test_rationale_flagged_even_when_rewrite_text_dirty(self):
        payload = _analysis(
            suggestions=[
                {
                    "axis": "warmer",
                    "text": "based on everything, here is the rewrite",  # ignored
                    "rationale": "my read is it softens the ask",  # scanned
                }
            ]
        )
        findings = scan_coach_output(payload, enabled=True)
        self.assertEqual(_codes(findings), [BANNED_TOOL_NARRATION_CODE])
        self.assertEqual(
            _phrases_for_field(findings, "suggestions[0].rationale"), {"my read"}
        )


class TestBenignBoundaryControls(unittest.TestCase):
    """Default-ignorable-only gaps must never fabricate outer phrase edges."""

    def test_required_dicp_false_positive_controls_stay_clean(self):
        controls = [
            f"re{ZWSP}based on",         # "rebased on"  -> left edge fabricated
            f"based on{ZWSP}line",       # "based online"-> right edge fabricated
            f"over{ZWSP}looking at",     # "overlooking at"
            f"my read{ZWSP}ing",         # "my reading"
            f"I checked{ZWSP}out",       # "I checkedout"
        ]
        for text in controls:
            payload = _analysis(perception=text)
            self.assertEqual(
                scan_coach_output(payload, enabled=True),
                [],
                msg=f"benign control wrongly flagged: {text!r}",
            )

    def test_ordinary_substring_false_positives_stay_clean(self):
        for text in [
            "rebased on the feature branch",
            "the app is based online now",
            "overlooking at first glance",
            "my reading of the room",
            "I checkedout the repo",
            "unbased opinions abound",
        ]:
            self.assertEqual(
                scan_coach_output(_analysis(subtext=text), enabled=True),
                [],
                msg=f"ordinary substring wrongly flagged: {text!r}",
            )

    def test_genuine_phrase_with_real_separators_is_flagged(self):
        # A true word boundary (space) around the phrase IS the banned phrase.
        self.assertEqual(
            _phrases_for_field(
                scan_coach_output(_analysis(perception="I checked out the repo"),
                                  enabled=True),
                "perception",
            ),
            {"i checked"},
        )


class TestOuterBoundaryPrecision(unittest.TestCase):
    """Non-DICP token content (combining marks) vs. real punctuation edges."""

    def test_bare_combining_mark_does_not_fabricate_left_edge(self):
        # "a͙based on" is visually one token; the mark attaches to 'a'.
        self.assertFalse(is_default_ignorable(COMBINING_MARK))
        self.assertEqual(
            scan_coach_output(_analysis(perception=f"a{COMBINING_MARK}based on it"),
                              enabled=True),
            [],
        )

    def test_bare_combining_mark_does_not_fabricate_right_edge(self):
        # "my read͙s" -> the mark glues into the trailing token.
        self.assertEqual(
            scan_coach_output(_analysis(subtext=f"my read{COMBINING_MARK}s the room"),
                              enabled=True),
            [],
        )

    def test_punctuation_and_symbols_are_real_boundaries(self):
        # Real, visible delimiters DO expose a genuine phrase occurrence.
        cases = {
            "(based on)": "based on",
            "based on.": "based on",
            "“looking at”": "looking at",
            "'my read'": "my read",
            "$based on": "based on",
        }
        for text, phrase in cases.items():
            self.assertEqual(
                _phrases_for_field(
                    scan_coach_output(_analysis(perception=text), enabled=True),
                    "perception",
                ),
                {phrase},
                msg=f"{text!r} should expose {phrase!r}",
            )

    def test_letter_with_combining_mark_then_space_still_flags(self):
        # A real separator after mark-bearing token is still a boundary.
        self.assertEqual(
            _phrases_for_field(
                scan_coach_output(_analysis(perception=f"cafe{COMBINING_MARK} based on it"),
                                  enabled=True),
                "perception",
            ),
            {"based on"},
        )


class TestDefaultIgnorableObfuscation(unittest.TestCase):
    def _flagged(self, text, phrase):
        findings = scan_coach_output(_analysis(perception=text), enabled=True)
        got = {p.casefold() for p in _phrases_for_field(findings, "perception")}
        self.assertIn(phrase.casefold(), got, msg=f"{text!r} should flag {phrase!r}")

    def test_intra_word_and_seam_for_named_representatives(self):
        for d in (CGJ, VS16, VS17, ZWSP, ZWNJ):
            # intra-word obfuscation ("ba<d>sed on")
            self._flagged(f"ba{d}sed on the thread", "based on")
            # inter-word seam with the space replaced by the ignorable
            self._flagged(f"based{d}on the thread", "based on")
            # seam for a multi-token phrase whose words are glued by the ignorable
            self._flagged(f"looking{d}at the ask", "looking at")

    def test_ignorable_between_every_character_is_detected(self):
        d = ZWSP
        obf = d.join("my read")  # m<z>y<z> <z>r... keeps the internal space as a char
        self._flagged(f"So {obf} says otherwise", "my read")

    def test_named_representatives_do_not_fabricate_outer_boundaries(self):
        for d in (CGJ, VS16, VS17):
            for text in (f"re{d}based on it", f"based on{d}line here",
                         f"over{d}looking at it", f"my read{d}ing list",
                         f"I checked{d}out now"):
                self.assertEqual(
                    scan_coach_output(_analysis(perception=text), enabled=True),
                    [],
                    msg=f"{text!r} must stay clean",
                )


class TestSeparators(unittest.TestCase):
    def test_whitespace_variety_between_words(self):
        for sep in (" ", "\t", "\n", "  ", " "):  # incl. no-break space
            payload = _analysis(perception=f"based{sep}on the thread")
            self.assertEqual(
                _phrases_for_field(scan_coach_output(payload, enabled=True),
                                   "perception"),
                {"based on"},
                msg=f"separator {sep!r} not honoured",
            )

    def test_unicode_dash_punctuation_as_seam_and_boundary(self):
        # All category Pd; U+FE58/U+FF0D also exercise NFKC dash folding.
        for dash in ("-", "‐", "–", "—", "﹘", "－"):
            # dash as the inter-word seam
            payload = _analysis(perception=f"based{dash}on the thread")
            self.assertEqual(
                _phrases_for_field(scan_coach_output(payload, enabled=True),
                                   "perception"),
                {"based on"},
                msg=f"dash seam {dash!r} not honoured",
            )
            # dash as a real outer boundary (does NOT glue into a bigger token)
            payload2 = _analysis(perception=f"re{dash}based on it")
            self.assertEqual(
                _phrases_for_field(scan_coach_output(payload2, enabled=True),
                                   "perception"),
                {"based on"},
                msg=f"dash boundary {dash!r} should be a real separator",
            )

    def test_dash_glued_word_is_not_a_false_positive(self):
        # No dash/space at all -> "rebased on" stays one token.
        self.assertEqual(
            scan_coach_output(_analysis(perception="rebased on main"), enabled=True), []
        )


class TestNfkcCasefold(unittest.TestCase):
    def test_fullwidth_compatibility_is_detected(self):
        # Fullwidth Latin normalises (NFKC) to ASCII "based on".
        fullwidth = "ｂａｓｅｄ　ｏｎ"  # incl. ideographic space
        payload = _analysis(perception=f"{fullwidth} the thread")
        self.assertEqual(
            _phrases_for_field(scan_coach_output(payload, enabled=True), "perception"),
            {"based on"},
        )

    def test_uppercase_and_mixed_case(self):
        payload = _analysis(subtext="LoOkInG At the ask")
        self.assertEqual(
            _phrases_for_field(scan_coach_output(payload, enabled=True), "subtext"),
            {"looking at"},
        )

    def test_scan_is_deterministic(self):
        payload = _analysis(perception=f"ba{ZWSP}sed on", subtext="my read here")
        first = scan_coach_output(payload, enabled=True)
        second = scan_coach_output(copy.deepcopy(payload), enabled=True)
        self.assertEqual(first, second)


class TestRiskReasonWordLimit(unittest.TestCase):
    def test_twelve_words_is_ok(self):
        payload = _analysis(risk_reason=" ".join(f"word{i}" for i in range(12)))
        self.assertNotIn(RISK_REASON_WORD_LIMIT_CODE,
                         _codes(scan_coach_output(payload, enabled=True)))

    def test_thirteen_words_is_flagged(self):
        payload = _analysis(risk_reason=" ".join(f"word{i}" for i in range(13)))
        findings = scan_coach_output(payload, enabled=True)
        limit = [f for f in findings if f.code == RISK_REASON_WORD_LIMIT_CODE]
        self.assertEqual(len(limit), 1)
        self.assertEqual(limit[0].field, "risk_reason")

    def test_word_limit_only_applies_to_risk_reason(self):
        long_text = " ".join(f"word{i}" for i in range(30))
        payload = _analysis(perception=long_text, subtext=long_text)
        self.assertNotIn(RISK_REASON_WORD_LIMIT_CODE,
                         _codes(scan_coach_output(payload, enabled=True)))

    def test_accented_latin_word_counting(self):
        twelve = " ".join(["café", "résumé", "naïve", "coöperate", "Zoë", "façade",
                            "piñata", "jalapeño", "über", "déjà", "vu", "señor"])
        self.assertEqual(len(twelve.split()), 12)
        self.assertNotIn(RISK_REASON_WORD_LIMIT_CODE,
                         _codes(scan_coach_output(_analysis(risk_reason=twelve),
                                                  enabled=True)))
        thirteen = twelve + " más"
        self.assertIn(RISK_REASON_WORD_LIMIT_CODE,
                      _codes(scan_coach_output(_analysis(risk_reason=thirteen),
                                               enabled=True)))

    def test_cyrillic_word_counting(self):
        twelve = " ".join(["привет"] * 12)
        self.assertNotIn(RISK_REASON_WORD_LIMIT_CODE,
                         _codes(scan_coach_output(_analysis(risk_reason=twelve),
                                                  enabled=True)))
        thirteen = " ".join(["привет"] * 13)
        self.assertIn(RISK_REASON_WORD_LIMIT_CODE,
                      _codes(scan_coach_output(_analysis(risk_reason=thirteen),
                                               enabled=True)))

    def test_cjk_space_separated_word_counting(self):
        twelve = " ".join(["日本語"] * 12)
        self.assertNotIn(RISK_REASON_WORD_LIMIT_CODE,
                         _codes(scan_coach_output(_analysis(risk_reason=twelve),
                                                  enabled=True)))
        thirteen = " ".join(["中文字"] * 13)
        self.assertIn(RISK_REASON_WORD_LIMIT_CODE,
                      _codes(scan_coach_output(_analysis(risk_reason=thirteen),
                                               enabled=True)))

    def test_lone_punctuation_tokens_do_not_count_as_words(self):
        # A standalone em-dash token between real words must not inflate the count:
        # 12 real words + " — " reads as 13 tokens under a naive whitespace split.
        reason = "one two three four five six — seven eight nine ten eleven twelve"
        self.assertEqual(len(reason.split()), 13)  # naive split over-counts
        self.assertNotIn(RISK_REASON_WORD_LIMIT_CODE,
                         _codes(scan_coach_output(_analysis(risk_reason=reason),
                                                  enabled=True)))
        # ...but 13 genuine words (plus the dash) is still over the limit.
        over = "one two three four five six — seven eight nine ten eleven twelve thirteen"
        self.assertIn(RISK_REASON_WORD_LIMIT_CODE,
                      _codes(scan_coach_output(_analysis(risk_reason=over),
                                               enabled=True)))

    def test_default_ignorables_do_not_change_word_count(self):
        reason = ZWSP.join(["word"] * 12) + " tail"  # 12 glued -> one token + tail
        # 13 visible-looking pieces but only 2 real whitespace tokens.
        self.assertNotIn(RISK_REASON_WORD_LIMIT_CODE,
                         _codes(scan_coach_output(_analysis(risk_reason=reason),
                                                  enabled=True)))


class TestMalformedInput(unittest.TestCase):
    def test_non_mapping_analysis_is_inert(self):
        for bad in (None, "a string", 42, ["list"], object()):
            self.assertEqual(scan_coach_output(bad, enabled=True), [])

    def test_missing_fields_do_not_crash(self):
        self.assertEqual(scan_coach_output({}, enabled=True), [])

    def test_none_and_non_string_fields_are_skipped(self):
        payload = {
            "perception": None,
            "subtext": 12345,
            "risk_reason": None,
            "suggestions": "not-a-list",
        }
        self.assertEqual(scan_coach_output(payload, enabled=True), [])

    def test_suggestions_with_non_dict_items_are_skipped(self):
        payload = _analysis(suggestions=["oops", None, 3, {"rationale": "based on it"}])
        findings = scan_coach_output(payload, enabled=True)
        self.assertEqual(
            _phrases_for_field(findings, "suggestions[3].rationale"), {"based on"}
        )

    def test_rationale_missing_or_none_is_skipped(self):
        payload = _analysis(suggestions=[{"axis": "warmer", "text": "hi"}])
        self.assertEqual(scan_coach_output(payload, enabled=True), [])

    def test_scan_does_not_mutate_input(self):
        payload = _analysis(perception="based on the thread",
                            risk_reason=" ".join(["w"] * 20))
        snapshot = copy.deepcopy(payload)
        scan_coach_output(payload, enabled=True)
        self.assertEqual(payload, snapshot)


class TestImportIsolation(unittest.TestCase):
    def test_module_imports_only_stdlib(self):
        tree = ast.parse(MODULE_PATH.read_text(encoding="utf-8"))
        allowed = {
            "__future__", "unicodedata", "dataclasses", "typing",
            "collections", "collections.abc",
        }
        imported = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    imported.add(alias.name.split(".")[0])
            elif isinstance(node, ast.ImportFrom):
                if node.level:
                    self.fail("relative import found; module must be standalone")
                imported.add((node.module or "").split(".")[0])
        third_party = {"httpx", "fastapi", "pydantic", "starlette", "requests"}
        self.assertEqual(imported & third_party, set())
        self.assertTrue(imported <= {m.split(".")[0] for m in allowed})

    def test_no_other_module_imports_the_validator(self):
        offenders = []
        for py in _REPO_ROOT.rglob("*.py"):
            if py.resolve() in (MODULE_PATH.resolve(), pathlib.Path(__file__).resolve()):
                continue
            if ".git" in py.parts or "controller-artifacts" in py.parts:
                continue
            if "coach_output_hygiene" in py.read_text(encoding="utf-8", errors="ignore"):
                offenders.append(str(py))
        self.assertEqual(offenders, [], msg=f"unexpected importers: {offenders}")

    def test_importing_validator_pulls_no_heavy_deps(self):
        # The validator was already imported at module load; prove the heavy
        # backend stack was not dragged in as a side effect.
        for mod in ("httpx", "fastapi", "pydantic"):
            self.assertNotIn(mod, sys.modules,
                             msg=f"{mod} unexpectedly imported by the validator")


class TestUnicodeTableProvenance(unittest.TestCase):
    def test_version_and_source_constants(self):
        self.assertEqual(UNICODE_VERSION, "13.0.0")
        self.assertIn("13.0.0", DERIVED_CORE_PROPERTIES_URL)
        self.assertTrue(DERIVED_CORE_PROPERTIES_URL.startswith("https://www.unicode.org/"))
        self.assertRegex(DERIVED_CORE_PROPERTIES_SHA256, r"^[0-9a-f]{64}$")

    def test_table_has_exactly_4173_members(self):
        self.assertEqual(len(_impl_member_set()), 4173)

    def test_ranges_are_sorted_and_non_overlapping(self):
        prev_hi = -1
        for lo, hi in DEFAULT_IGNORABLE_RANGES:
            self.assertLessEqual(lo, hi)
            self.assertGreater(lo, prev_hi, msg="ranges must be sorted & disjoint")
            prev_hi = hi

    def test_named_non_cf_representatives_present(self):
        for cp in (0x034F, 0xFE0F, 0xE0100):
            self.assertTrue(is_default_ignorable(chr(cp)))

    def test_is_default_ignorable_rejects_ordinary_characters(self):
        for ch in "based on ABC123 café 日本語—-":
            self.assertFalse(is_default_ignorable(ch), msg=repr(ch))


class TestOfficialUnicodeEquivalenceAndHostileSweep(unittest.TestCase):
    """Complete-property sweep against independently-parsed official data."""

    @classmethod
    def setUpClass(cls):
        cls.official_path = _REPO_ROOT / "controller-artifacts" / "DerivedCoreProperties.txt"
        if not cls.official_path.exists():
            raise unittest.SkipTest(
                "GATE: official Unicode 13.0.0 DerivedCoreProperties.txt is not "
                f"present at {cls.official_path}. Fetch {DERIVED_CORE_PROPERTIES_URL} "
                "into controller-artifacts/ to run the complete-property sweep. "
                "Refusing to invent Unicode data."
            )
        cls.official_members = _parse_official_dicp(cls.official_path)

    def test_source_sha256_matches_pinned_value(self):
        digest = hashlib.sha256(self.official_path.read_bytes()).hexdigest()
        self.assertEqual(digest, DERIVED_CORE_PROPERTIES_SHA256)

    def test_official_set_size_is_4173(self):
        self.assertEqual(len(self.official_members), 4173)

    def test_impl_table_equals_official_set(self):
        self.assertEqual(_impl_member_set(), self.official_members)

    def test_complete_property_hostile_sweep(self):
        # Iterate the OFFICIAL members (independent authority), not the impl table.
        intra_failures = []
        seam_failures = []
        left_fab_failures = []
        right_fab_failures = []
        for cp in sorted(self.official_members):
            d = chr(cp)

            intra = scan_coach_output(_analysis(perception=f"bas{d}ed on the signals"),
                                      enabled=True)
            if "based on" not in _phrases_for_field(intra, "perception"):
                intra_failures.append(cp)

            seam = scan_coach_output(_analysis(perception=f"based{d}on the signals"),
                                     enabled=True)
            if "based on" not in _phrases_for_field(seam, "perception"):
                seam_failures.append(cp)

            left = scan_coach_output(_analysis(perception=f"re{d}based on the signals"),
                                     enabled=True)
            if left:
                left_fab_failures.append(cp)

            right = scan_coach_output(_analysis(perception=f"based on{d}line of work"),
                                      enabled=True)
            if right:
                right_fab_failures.append(cp)

        self.assertEqual(intra_failures, [],
                         msg=f"{len(intra_failures)} members failed intra-word detection")
        self.assertEqual(seam_failures, [],
                         msg=f"{len(seam_failures)} members failed seam detection")
        self.assertEqual(left_fab_failures, [],
                         msg=f"{len(left_fab_failures)} members fabricated a left edge")
        self.assertEqual(right_fab_failures, [],
                         msg=f"{len(right_fab_failures)} members fabricated a right edge")


if __name__ == "__main__":
    unittest.main(verbosity=2)
