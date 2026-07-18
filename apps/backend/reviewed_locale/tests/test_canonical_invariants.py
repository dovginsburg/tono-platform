"""Pin the foundation's constants to the REAL Tono source.

The canonical pytest locale suite (``apps/backend/tests/test_coach_contract.py``)
imports ``backend.analyze``, which needs ``httpx`` -- not installed in this
stdlib-only environment, so that suite cannot execute here. Instead we re-derive
the canonical facts straight from source (``ast`` for Python, text for the web
copy) and assert the foundation matches. If the product changes a price or an
axis, these tests fail instead of the foundation silently drifting.
"""

from __future__ import annotations

import ast
import pathlib
import unittest

from backend.reviewed_locale import canonical

_ROOT = pathlib.Path(__file__).resolve().parents[4]
_ANALYZE = _ROOT / "apps" / "backend" / "analyze.py"
_WEB = _ROOT / "apps" / "web" / "src" / "app"


def _ast_literal(py_path: pathlib.Path, name: str):
    tree = ast.parse(py_path.read_text(encoding="utf-8"))
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == name:
                    return ast.literal_eval(node.value)
    raise AssertionError("%s not found in %s" % (name, py_path))


class CoachAxesPinned(unittest.TestCase):
    def test_axes_match_analyze_source(self):
        real = _ast_literal(_ANALYZE, "CANONICAL_COACH_AXES")
        self.assertEqual(tuple(real), canonical.COACH_AXES)

    def test_axis_keys_derive_from_axes(self):
        self.assertEqual(
            canonical.COACH_AXIS_KEYS,
            tuple("coach.axis.%s" % a for a in canonical.COACH_AXES),
        )


class PricingPinned(unittest.TestCase):
    """Every canonical price token must actually appear in the web pricing copy."""

    def _web_text(self) -> str:
        chunks = []
        for path in _WEB.rglob("*.tsx"):
            try:
                chunks.append(path.read_text(encoding="utf-8"))
            except OSError:
                continue
        return "\n".join(chunks)

    def test_prices_present_in_web_copy(self):
        text = self._web_text()
        for token in (
            canonical.PRICE_MONTHLY,
            canonical.PRICE_ANNUAL,
            canonical.PRICE_ANNUAL_SAVINGS,
        ):
            self.assertIn(token, text, "price %r not found in web copy" % token)

    def test_trial_length_present(self):
        self.assertIn("7-day free trial", self._web_text())

    def test_urgency_tag_present_in_contact(self):
        contact = (_WEB / "contact" / "page.tsx").read_text(encoding="utf-8")
        self.assertIn(canonical.URGENCY_TAG, contact)


class CriticalKeyContractIsConsistent(unittest.TestCase):
    def test_all_axis_keys_are_critical(self):
        for key in canonical.COACH_AXIS_KEYS:
            self.assertIn(key, canonical.CRITICAL_KEYS)

    def test_price_keys_reference_only_canonical_tokens(self):
        by_key = canonical.SPEC_BY_KEY
        self.assertEqual(by_key["pricing.monthly"].required_tokens, (canonical.PRICE_MONTHLY,))
        self.assertEqual(by_key["pricing.annual"].required_tokens, (canonical.PRICE_ANNUAL,))
        self.assertEqual(
            by_key["pricing.annual_savings"].required_tokens,
            (canonical.PRICE_ANNUAL_SAVINGS,),
        )

    def test_monthly_and_annual_forbid_each_other(self):
        by_key = canonical.SPEC_BY_KEY
        self.assertIn(canonical.PRICE_ANNUAL, by_key["pricing.monthly"].forbidden_tokens)
        self.assertIn(canonical.PRICE_MONTHLY, by_key["pricing.annual"].forbidden_tokens)


if __name__ == "__main__":
    unittest.main(verbosity=2)
