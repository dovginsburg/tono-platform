"""Public validators — total, fail-closed, never probe caller mapping keys.

Each validator decides validity by ``type(x) is <OurModel>`` identity plus a
read of the already-normalized ``valid`` bit. A raw dict (hostile-keyed or
not) fails the identity check immediately, so no key is ever hashed, compared,
looked up, or enumerated. That makes every validator total for hostile exact
dict keys: they can never raise.
"""

from __future__ import annotations

from ._models import (
    Entitlement,
    EvaluationContext,
    ReleaseConfig,
    ReleaseRule,
    _get,
)
from ._normalize import norm_flag


def is_valid_config(obj):
    return type(obj) is ReleaseConfig and _get(obj, 0) is True


def is_valid_rule(obj):
    return type(obj) is ReleaseRule and _get(obj, 0) is True


def is_valid_context(obj):
    return type(obj) is EvaluationContext and _get(obj, 0) is True


def is_valid_entitlement(obj):
    return type(obj) is Entitlement and _get(obj, 0) is True


def is_valid_flag_name(x):
    return norm_flag(x) is not None
