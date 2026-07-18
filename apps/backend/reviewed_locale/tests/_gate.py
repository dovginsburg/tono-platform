"""Implementation-under-test selector.

Defaults to the real reviewed-locale package. The RED gate run (see
``controller-artifacts/``) points the SAME hostile suite at a disposable
pre-remediation *naive* baseline by exporting::

    REVIEWED_LOCALE_GATE=<module exposing evaluate_candidate + STATUS_*>

so the tests demonstrably fail against the pre-remediation behavior and pass
against the remediated package. In normal (committed) runs the env var is unset
and this resolves to ``backend.reviewed_locale``.
"""

from __future__ import annotations

import importlib
import os

_IMPL = os.environ.get("REVIEWED_LOCALE_GATE", "backend.reviewed_locale")
_module = importlib.import_module(_IMPL)

evaluate_candidate = _module.evaluate_candidate
STATUS_NOT_ELIGIBLE = _module.STATUS_NOT_ELIGIBLE
STATUS_PRE_REVIEW = _module.STATUS_PRE_REVIEW
STATUS_ELIGIBLE_FOR_REVIEW = _module.STATUS_ELIGIBLE_FOR_REVIEW

GATE_IMPL = _IMPL
