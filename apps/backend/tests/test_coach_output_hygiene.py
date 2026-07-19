"""Focused tests for the default-OFF Coach output-hygiene validator.

This module is the *only* importer of ``backend.coach_output_hygiene``; the
validator has no runtime wiring anywhere in the app. The tests cover four
independent contracts:

1. Public-safety: ``validate_coach_output`` is an unconditional never-raises
   boundary for *arbitrary* Python objects (hostile ``__str__``, hostile
   ``Mapping.get``, hostile iterables), not merely JSON-decoded containers.

2. Detection: SYSTEM_PROMPT banned tool-narration phrases are found only in
   the coach-authored fields (``perception``, ``subtext``, ``risk_reason`` and
   ``suggestions[].rationale``) and never in the ``text`` rewrite field, plus a
   ``risk_reason`` <= 12 Unicode-word limit.

3. Unicode property: the Default_Ignorable_Code_Point (DICP) table is pinned to
   Unicode 13.0.0 (exactly 4,173 code points) and is evasion-resistant. The
   authoritative expected set is parsed here independently of the module's
   table; when the official UCD file has been fetched into the untracked
   ``controller-artifacts/`` directory the two are proven byte-for-byte equal.

4. Import-isolation: importing the module drags in none of ``httpx``,
   ``fastapi`` or ``pydantic`` -- proven with a clean isolated subprocess so the
   check does not depend on what the surrounding pytest session already loaded.
"""

from __future__ import annotations

import hashlib
import os
import subprocess
import sys
import unicodedata

import pytest

from backend.coach_output_hygiene import (
    BANNED_TOOL_NARRATION_PHRASES,
    DEFAULT_IGNORABLE_RANGES,
    Finding,
    RISK_REASON_WORD_LIMIT,
    UNICODE_DICP_COUNT,
    UNICODE_DICP_SOURCE_SHA256,
    UNICODE_DICP_SOURCE_URL,
    UNICODE_VERSION,
    banned_phrases_in_text,
    default_ignorable_codepoints,
    risk_reason_word_count,
    validate_coach_output,
)


# ---------------------------------------------------------------------------
# Independently-authored expectations (NOT derived from the module's own table)
# ---------------------------------------------------------------------------

# Default_Ignorable_Code_Point ranges for Unicode 13.0.0, parsed by hand from
# https://www.unicode.org/Public/13.0.0/ucd/DerivedCoreProperties.txt . This is
# a deliberately separate literal from the module's DEFAULT_IGNORABLE_RANGES so
# the equality assertions below are a real cross-check, not a tautology.
EXPECTED_DICP_RANGES = (
    (0x00AD, 0x00AD), (0x034F, 0x034F), (0x061C, 0x061C), (0x115F, 0x1160),
    (0x17B4, 0x17B5), (0x180B, 0x180E), (0x200B, 0x200F), (0x202A, 0x202E),
    (0x2060, 0x206F), (0x3164, 0x3164), (0xFE00, 0xFE0F), (0xFEFF, 0xFEFF),
    (0xFFA0, 0xFFA0), (0xFFF0, 0xFFF8), (0x1BCA0, 0x1BCA3), (0x1D173, 0x1D17A),
    (0xE0000, 0xE0FFF),
)

EXPECTED_DICP_COUNT = 4173
EXPECTED_SOURCE_SHA256 = (
    "a5d45f59b39deaab3c72ce8c1a2e212a5e086dff11b1f9d5bb0e352642e82248"
)

ZWSP = "​"   # ZERO WIDTH SPACE
ZWNJ = "‌"   # ZERO WIDTH NON-JOINER
CGJ = "͏"    # COMBINING GRAPHEME JOINER (a DICP that is category Mn, not Cf)
VS16 = "️"   # VARIATION SELECTOR-16
VS17 = "\U000e0100"  # VARIATION SELECTOR-17

_HERE = os.path.dirname(os.path.abspath(__file__))
_APPS_DIR = os.path.dirname(os.path.dirname(_HERE))               # .../apps
_REPO_ROOT = os.path.dirname(_APPS_DIR)                           # repo root
_OFFICIAL_UCD = os.path.join(
    _REPO_ROOT, "controller-artifacts", "DerivedCoreProperties-13.0.0.txt"
)


def _expected_dicp_set():
    out = set()
    for start, end in EXPECTED_DICP_RANGES:
        out.update(range(start, end + 1))
    return out


def _codes(findings):
    return sorted(f.code for f in findings)


def _clean_result(**overrides):
    result = {
        "risk_level": "low",
        "perception": "Reads as a direct, friendly ask.",
        "subtext": "wants a quick reply",
        "risk_reason": "Lands cleanly with a specific next step.",
        "suggestions": [
            {"axis": "warmer", "text": "Hey, could you help me?",
             "rationale": "Adds a soft opener.", "risk_after": "low"},
            {"axis": "clearer", "text": "Can you review this by Friday?",
             "rationale": "Names a deadline.", "risk_after": "low"},
        ],
        "flags": [],
    }
    result.update(overrides)
    return result


# ---------------------------------------------------------------------------
# Hostile fixtures used to prove the never-raises boundary
# ---------------------------------------------------------------------------

class ExplodingStr:
    """A non-string value whose ``str()`` coercion raises."""

    def __repr__(self):  # keep pytest's own assert-introspection safe
        return "<ExplodingStr>"

    def __str__(self):
        raise RuntimeError("hostile __str__")


class ExplodingMapping:
    """A Mapping-like object whose ``.get`` raises on every access."""

    def __repr__(self):
        return "<ExplodingMapping>"

    def get(self, key, default=None):
        raise RuntimeError("hostile .get")


class ExplodingIterable:
    """A container whose ``__iter__`` raises."""

    def __repr__(self):
        return "<ExplodingIterable>"

    def __iter__(self):
        raise RuntimeError("hostile __iter__")


class ExplodingIterator:
    """A container that yields one item then raises from ``__next__``."""

    def __repr__(self):
        return "<ExplodingIterator>"

    def __iter__(self):
        return self

    def __next__(self):
        raise RuntimeError("hostile __next__")


# ===========================================================================
# 1. Public-safety: never-raises boundary (the hostile RED tests)
# ===========================================================================

def test_prior_failure_mode_is_a_real_hazard():
    # Documents the exact failure a naive validator would hit: coercing these
    # hostile values the obvious way raises before any hygiene work happens.
    with pytest.raises(RuntimeError):
        str(ExplodingStr())
    with pytest.raises(RuntimeError):
        ExplodingMapping().get("perception")
    with pytest.raises(RuntimeError):
        list(ExplodingIterable())
    with pytest.raises(RuntimeError):
        list(ExplodingIterator())


@pytest.mark.parametrize("field", ["perception", "subtext", "risk_reason"])
def test_hostile_str_in_text_field_never_raises(field):
    payload = _clean_result(**{field: ExplodingStr()})
    findings = validate_coach_output(payload, enabled=True)
    assert isinstance(findings, list)  # inert result, no escape


def test_hostile_str_in_suggestion_rationale_never_raises():
    payload = _clean_result(suggestions=[
        {"axis": "warmer", "text": "fine", "rationale": ExplodingStr()},
    ])
    findings = validate_coach_output(payload, enabled=True)
    assert isinstance(findings, list)


def test_hostile_mapping_get_raises_at_top_level_never_raises():
    findings = validate_coach_output(ExplodingMapping(), enabled=True)
    assert findings == []


def test_hostile_mapping_get_raises_in_nested_suggestion_never_raises():
    payload = _clean_result(suggestions=[ExplodingMapping()])
    findings = validate_coach_output(payload, enabled=True)
    assert isinstance(findings, list)


def test_hostile_iterable_suggestions_iter_raises_never_raises():
    payload = _clean_result(suggestions=ExplodingIterable())
    findings = validate_coach_output(payload, enabled=True)
    assert isinstance(findings, list)


def test_hostile_iterator_suggestions_next_raises_never_raises():
    payload = _clean_result(suggestions=ExplodingIterator())
    findings = validate_coach_output(payload, enabled=True)
    assert isinstance(findings, list)


@pytest.mark.parametrize("payload", [
    None, 42, 3.14, True, "just a string", b"bytes", ["a", "list"],
    ("a", "tuple"), {"set", "literal"}, object(), Exception("nope"),
    {"perception": 123, "subtext": None, "risk_reason": object(),
     "suggestions": [1, "x", None, object()]},
    {"suggestions": {"not": "a list"}},
    {"suggestions": 5},
])
def test_arbitrary_python_objects_never_raise(payload):
    # The boundary must hold for arbitrary objects, not only plain containers.
    assert isinstance(validate_coach_output(payload, enabled=True), list)


def test_public_helpers_never_raise_on_hostile_input():
    assert banned_phrases_in_text(ExplodingStr()) == ()
    assert banned_phrases_in_text(None) == ()
    assert banned_phrases_in_text(42) == ()
    assert risk_reason_word_count(ExplodingStr()) == 0
    assert risk_reason_word_count(None) == 0


# ===========================================================================
# 2. Default-off + detection surface (which fields are scanned)
# ===========================================================================

def test_hard_default_off_reports_nothing_even_when_violations_exist():
    payload = _clean_result(
        perception="Looking at this, it reads cold.",   # banned "looking at"
        risk_reason=" ".join(["word"] * 20),            # 20 > 12 words
    )
    assert validate_coach_output(payload) == []          # default enabled=False
    assert validate_coach_output(payload, enabled=False) == []


def test_clean_result_produces_no_findings_when_enabled():
    assert validate_coach_output(_clean_result(), enabled=True) == []


@pytest.mark.parametrize("field", ["perception", "subtext", "risk_reason"])
def test_banned_phrase_detected_in_each_coach_authored_text_field(field):
    payload = _clean_result(**{field: "Honestly, based on the tone, be careful."})
    findings = validate_coach_output(payload, enabled=True)
    hits = [f for f in findings if f.code == "banned_tool_narration"]
    assert [f.field for f in hits] == [field]
    assert hits[0].phrase == "based on"


def test_banned_phrase_detected_in_suggestion_rationale():
    payload = _clean_result(suggestions=[
        {"axis": "warmer", "text": "Hey there!",
         "rationale": "My read is that this needs warmth."},   # banned "my read"
    ])
    findings = validate_coach_output(payload, enabled=True)
    hits = [f for f in findings if f.code == "banned_tool_narration"]
    assert len(hits) == 1
    assert hits[0].field == "suggestions[0].rationale"
    assert hits[0].phrase == "my read"


def test_rewrite_text_field_is_never_scanned():
    # A banned phrase inside the rewrite ``text`` must be ignored, while the
    # same phrase in the sibling ``rationale`` must still be reported. This is
    # the load-bearing "never scan or rewrite rewrite text" contract.
    payload = _clean_result(suggestions=[
        {"axis": "warmer",
         "text": "Based on what you said, I checked and looking at my read...",
         "rationale": "I checked the tone."},   # banned "i checked"
    ])
    findings = validate_coach_output(payload, enabled=True)
    hits = [f for f in findings if f.code == "banned_tool_narration"]
    assert len(hits) == 1
    assert hits[0].field == "suggestions[0].rationale"
    assert hits[0].phrase == "I checked"


def test_untracked_fields_are_not_scanned():
    # axis / risk_level / risk_after / flags carry provider-controlled text but
    # are not coach prose; they must not be scanned.
    payload = _clean_result(
        risk_level="based on",
        flags=["looking at", "my read"],
        suggestions=[{"axis": "based on", "text": "x",
                      "rationale": "clean", "risk_after": "my read"}],
    )
    assert validate_coach_output(payload, enabled=True) == []


@pytest.mark.parametrize("variant", [
    "Based On the vibe here.", "BASED ON everything.", "based\ton it",
])
def test_detection_is_case_insensitive_and_nfkc_normalised(variant):
    payload = _clean_result(perception=variant)
    findings = validate_coach_output(payload, enabled=True)
    assert any(f.phrase == "based on" for f in findings)


def test_fullwidth_characters_are_normalised_before_matching():
    # NFKC folds fullwidth Latin to ASCII, so an evasive fullwidth spelling is
    # still caught.
    fullwidth = "ｂａｓｅｄ ｏｎ"  # "based on"
    payload = _clean_result(subtext=fullwidth)
    assert any(f.phrase == "based on"
               for f in validate_coach_output(payload, enabled=True))


# ===========================================================================
# 3a. Unicode provenance and DICP set equality
# ===========================================================================

def test_unicode_provenance_constants_are_pinned():
    assert UNICODE_VERSION == "13.0.0"
    assert UNICODE_DICP_SOURCE_URL == (
        "https://www.unicode.org/Public/13.0.0/ucd/DerivedCoreProperties.txt"
    )
    assert UNICODE_DICP_COUNT == EXPECTED_DICP_COUNT == 4173
    assert UNICODE_DICP_SOURCE_SHA256 == EXPECTED_SOURCE_SHA256


def test_module_dicp_table_matches_independent_expected_set():
    module_set = default_ignorable_codepoints()
    assert isinstance(module_set, frozenset)
    assert len(module_set) == 4173
    assert module_set == _expected_dicp_set()


def test_named_dicp_members_present():
    module_set = default_ignorable_codepoints()
    for cp in (0x034F, 0xFE0F, 0xE0100):
        assert cp in module_set
    # Pinning DICP (not category Cf) is the whole point: U+034F is Mn and
    # U+FE0F/U+E0100 are variation selectors, none of which are Cf.
    assert unicodedata.category("͏") == "Mn"


def test_dicp_table_equals_official_unicode_file_when_present():
    # Strong independence: when the official UCD file has been fetched into the
    # untracked controller-artifacts/ dir we re-parse it here (no network) and
    # prove byte-for-byte equality with the module table. Skips cleanly in
    # clones that do not carry the untracked artifact, so the canonical suite
    # never depends on it.
    if not os.path.exists(_OFFICIAL_UCD):
        pytest.skip("official UCD artifact not present (network-fetched, untracked)")
    raw = open(_OFFICIAL_UCD, "rb").read()
    assert hashlib.sha256(raw).hexdigest() == EXPECTED_SOURCE_SHA256
    official = set()
    for line in raw.decode("utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        field, _, prop = line.partition(";")
        if prop.strip() != "Default_Ignorable_Code_Point":
            continue
        field = field.strip()
        if ".." in field:
            lo, hi = field.split("..")
            official.update(range(int(lo, 16), int(hi, 16) + 1))
        else:
            official.add(int(field, 16))
    assert len(official) == 4173
    assert official == default_ignorable_codepoints()
    assert official == _expected_dicp_set()


# ===========================================================================
# 3b. Evasion resistance: seams, intra-word obfuscation, outer boundaries
# ===========================================================================

@pytest.mark.parametrize("ign", [CGJ, VS16, VS17, ZWSP, ZWNJ], ids=[
    "U+034F", "U+FE0F", "U+E0100", "U+200B", "U+200C",
])
def test_default_ignorable_intra_word_obfuscation_is_detected(ign):
    # An ignorable dropped *inside* a phrase word must not defeat detection.
    payload = _clean_result(perception="This is ba" + ign + "sed on nothing.")
    assert any(f.phrase == "based on"
               for f in validate_coach_output(payload, enabled=True))


@pytest.mark.parametrize("ign", [CGJ, VS16, VS17, ZWSP, ZWNJ], ids=[
    "U+034F", "U+FE0F", "U+E0100", "U+200B", "U+200C",
])
def test_default_ignorable_at_seam_is_detected(ign):
    # An ignorable standing in for the inter-word seam must satisfy the seam.
    payload = _clean_result(risk_reason="reads as based" + ign + "on the opener")
    assert any(f.phrase == "based on"
               for f in validate_coach_output(payload, enabled=True))


@pytest.mark.parametrize("text,expected", [
    ("re" + ZWSP + "based on it", False),        # "rebased on" -> benign token
    ("based on" + ZWSP + "line here", False),    # "based online" -> benign
    ("over" + ZWSP + "looking at sea", False),   # "overlooking at" -> benign
    ("my read" + ZWSP + "ing list", False),      # "my reading" -> benign
    ("I checked" + ZWSP + "out the shop", False),  # "checkedout" -> benign
    (ZWSP + "based on", True),                    # DICP-only outer gap -> caught
    ("based on" + ZWSP, True),                    # DICP-only outer gap -> caught
])
def test_ignorables_never_fabricate_outer_boundaries(text, expected):
    payload = _clean_result(perception=text)
    got = any(f.code == "banned_tool_narration"
              for f in validate_coach_output(payload, enabled=True))
    assert got is expected


@pytest.mark.parametrize("benign", [
    "I rebased the branch on main.",
    "Our based online service is fine.",
    "We are overlooking the bay at dusk.",
    "Add it to my reading list.",
    "Hi, checked the box already.",   # 'i' inside "Hi" must not start "I checked"
    "The looking-glass world.",
])
def test_benign_prose_is_not_flagged(benign):
    payload = _clean_result(subtext=benign)
    assert not any(f.code == "banned_tool_narration"
                   for f in validate_coach_output(payload, enabled=True))


@pytest.mark.parametrize("sep", [
    " ", "\t", "\n", "\r\n", " ", " ", "　",   # whitespace kinds
    "-", "‐", "–", "—", "−",             # unicode dashes
])
def test_whitespace_and_dash_seam_separators_are_detected(sep):
    payload = _clean_result(perception="reads as looking" + sep + "at the ask")
    assert any(f.phrase == "looking at"
               for f in validate_coach_output(payload, enabled=True))


@pytest.mark.parametrize("mark", [
    "́", "̂", "̈", "̣", "̧",   # non-DICP combining marks
])
def test_non_default_ignorable_combining_marks_do_not_transparently_match(mark):
    # Only DICP are transparent. An ordinary combining mark alters/breaks the
    # token, so it must NOT be treated as invisible.
    payload = _clean_result(perception="ba" + mark + "sed on it")
    assert not any(f.code == "banned_tool_narration"
                   for f in validate_coach_output(payload, enabled=True))


@pytest.mark.parametrize("punct", [".", ",", "!", "/", "_", "*", "#"])
def test_ordinary_punctuation_inside_a_token_breaks_the_phrase(punct):
    payload = _clean_result(perception="ba" + punct + "sed on it")
    assert not any(f.code == "banned_tool_narration"
                   for f in validate_coach_output(payload, enabled=True))


# ===========================================================================
# 3c. Exhaustive official-property sweep (91,806 / 16,692 / 33,384)
# ===========================================================================

def test_exhaustive_default_ignorable_property_sweep():
    """Sweep every DICP code point across every insertion position of every
    banned phrase and assert the aggregate outcomes match the official-property
    totals exactly. Cases are generated from the independently-parsed expected
    DICP set, never from the module's own table."""
    dicp = sorted(_expected_dicp_set())
    assert len(dicp) == 4173

    intra = seam = outer = 0
    intra_hit = seam_hit = outer_hit = 0

    for phrase in BANNED_TOOL_NARRATION_PHRASES:
        tokens = phrase.split(" ")
        assert len(tokens) == 2, phrase
        left, right = tokens
        intra_gaps = (
            [("L", g) for g in range(1, len(left))]
            + [("R", g) for g in range(1, len(right))]
        )
        for cp in dicp:
            ch = chr(cp)
            for side, g in intra_gaps:
                if side == "L":
                    text = left[:g] + ch + left[g:] + " " + right
                else:
                    text = left + " " + right[:g] + ch + right[g:]
                intra += 1
                if phrase in banned_phrases_in_text(text):
                    intra_hit += 1
            # seam: the single inter-word space replaced by the ignorable
            seam += 1
            if phrase in banned_phrases_in_text(left + ch + right):
                seam_hit += 1
            # DICP-only outer gap on each side of a phrase at a string edge
            outer += 1
            if phrase in banned_phrases_in_text(ch + phrase):
                outer_hit += 1
            outer += 1
            if phrase in banned_phrases_in_text(phrase + ch):
                outer_hit += 1

    assert (intra, seam, outer) == (91806, 16692, 33384)
    # Every generated evasion is an intra/seam/outer obfuscation that must be
    # caught: full detection across the entire official property.
    assert (intra_hit, seam_hit, outer_hit) == (91806, 16692, 33384)


# ===========================================================================
# 4. risk_reason Unicode word limit (accented Latin, Cyrillic, CJK)
# ===========================================================================

@pytest.mark.parametrize("word", ["word", "café", "мир", "言"], ids=[
    "ascii", "accented-latin", "cyrillic", "cjk",
])
def test_risk_reason_word_limit_boundary_is_twelve(word):
    assert RISK_REASON_WORD_LIMIT == 12
    twelve = " ".join([word] * 12)
    thirteen = " ".join([word] * 13)
    assert risk_reason_word_count(twelve) == 12
    assert risk_reason_word_count(thirteen) == 13

    ok = validate_coach_output(_clean_result(risk_reason=twelve), enabled=True)
    assert not any(f.code == "risk_reason_too_long" for f in ok)

    bad = validate_coach_output(_clean_result(risk_reason=thirteen), enabled=True)
    over = [f for f in bad if f.code == "risk_reason_too_long"]
    assert len(over) == 1
    assert over[0].field == "risk_reason"
    assert over[0].word_count == 13


def test_ideographic_space_is_a_word_separator_after_nfkc():
    # U+3000 IDEOGRAPHIC SPACE folds to U+0020 under NFKC, so CJK reasons that
    # separate words with it are counted correctly.
    reason = "　".join(["語"] * 13)
    assert risk_reason_word_count(reason) == 13
    bad = validate_coach_output(_clean_result(risk_reason=reason), enabled=True)
    assert any(f.code == "risk_reason_too_long" for f in bad)


def test_word_limit_only_applies_to_risk_reason():
    long_text = " ".join(["clean"] * 40)
    findings = validate_coach_output(
        _clean_result(perception=long_text, subtext=long_text), enabled=True
    )
    assert not any(f.code == "risk_reason_too_long" for f in findings)


def test_zero_width_space_does_not_split_a_word_for_counting():
    # An ignorable inside a token does not fabricate a second word.
    assert risk_reason_word_count("one" + ZWSP + "word") == 1


# ===========================================================================
# 5. Import isolation (stdlib-only, order-independent)
# ===========================================================================

def test_importing_module_pulls_in_no_heavy_dependencies():
    # Clean isolated subprocess (python -I): PYTHONPATH/user-site ignored, a
    # fresh sys.modules. This proves importing the validator itself adds none of
    # httpx/fastapi/pydantic, independent of what the current pytest process
    # already imported (test_coach_contract, for instance, imports fastapi).
    code = (
        "import sys\n"
        "sys.path.insert(0, %r)\n"
        "import backend.coach_output_hygiene as m\n"
        "heavy = {'httpx', 'fastapi', 'pydantic'}\n"
        "present = sorted(heavy & set(sys.modules))\n"
        "sys.stdout.write('PRESENT:' + ','.join(present))\n"
        "sys.exit(1 if present else 0)\n"
    ) % _APPS_DIR
    proc = subprocess.run(
        [sys.executable, "-I", "-c", code],
        capture_output=True, text=True,
    )
    assert proc.returncode == 0, (proc.stdout + "\n" + proc.stderr)
    assert proc.stdout.strip() == "PRESENT:"


def test_module_source_imports_only_stdlib():
    import backend.coach_output_hygiene as m
    src = open(m.__file__, "r", encoding="utf-8").read()
    for banned in ("import httpx", "import fastapi", "import pydantic",
                   "from httpx", "from fastapi", "from pydantic"):
        assert banned not in src


def test_findings_are_immutable():
    f = Finding(field="perception", code="banned_tool_narration",
                detail="x", phrase="based on")
    with pytest.raises(Exception):
        f.code = "mutated"  # frozen dataclass
