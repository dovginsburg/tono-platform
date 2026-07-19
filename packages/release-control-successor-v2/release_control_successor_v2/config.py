"""Trusted input types for release-control evaluation.

All four types are immutable and constructed through sanitizing factories that
accept *exact* built-in containers only.  Subclasses, custom mappings /
sequences, hostile objects, ``bool``-as-``int``, non-finite / huge numbers, and
accessors that raise are all rejected or dropped, failing closed (off).

This module performs no I/O.
"""
from __future__ import annotations

from types import MappingProxyType
from typing import Any, Optional, Tuple

from ._safety import Immutable, coerce_bool, coerce_int_in_range

# Finite bounds.  Anything outside these is treated as malformed (dropped).
MAX_EPOCH_SECONDS = 4102444800     # 2100-01-01T00:00:00Z
MAX_TTL_SECONDS = 315360000        # 10 years
MAX_VERSION = 1 << 31              # generous, finite ceiling for build/schema
MAX_COHORT_LEN = 256
MAX_CAPABILITY_LEN = 64

_CAP_ALPHABET = frozenset(
    "abcdefghijklmnopqrstuvwxyz"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "0123456789_.-"
)

_SENTINEL_INVALID = object()


def valid_capability_name(name: Any) -> bool:
    """True iff ``name`` is an exact, non-empty, bounded, safe-charset ``str``."""
    if type(name) is not str:
        return False
    if not (1 <= len(name) <= MAX_CAPABILITY_LEN):
        return False
    return all(character in _CAP_ALPHABET for character in name)


def _optional_bound(mapping: dict, key: str, low: int, high: int) -> Any:
    """Return ``None`` if ``key`` is absent (explicitly unbounded on that side),
    the exact ``int`` if present and in range, or the invalid sentinel if the
    key is present but malformed (so the caller drops the whole rule)."""
    if key not in mapping:
        return None
    value = mapping[key]
    if type(value) is int and low <= value <= high:
        return value
    return _SENTINEL_INVALID


def _coerce_allowlist(mapping: dict) -> Tuple[str, ...]:
    """Return a deterministic tuple of exact cohort strings.

    A missing or malformed allowlist yields the empty tuple (the fail-closed,
    smaller-allowlist direction).  Non-``str`` / oversized entries are dropped.
    """
    raw = mapping.get("allowlist")
    if raw is None:
        return ()
    if type(raw) not in (list, tuple):
        return ()
    kept = set()
    for item in raw:
        if type(item) is str and 1 <= len(item) <= MAX_COHORT_LEN:
            kept.add(item)
    return tuple(sorted(kept))


class ReleaseRule(Immutable):
    """A single validated rollout rule for one capability."""

    __slots__ = (
        "_capability",
        "_percentage",
        "_allowlist",
        "_min_build",
        "_max_build",
        "_min_schema",
        "_max_schema",
        "_issued_at",
        "_ttl_seconds",
    )

    def __init__(
        self,
        capability: str,
        percentage: int,
        allowlist: Tuple[str, ...],
        min_build: Optional[int],
        max_build: Optional[int],
        min_schema: Optional[int],
        max_schema: Optional[int],
        issued_at: int,
        ttl_seconds: int,
    ) -> None:
        # Trusted internal constructor: every argument is pre-validated by
        # :meth:`from_mapping`.
        self._set("_capability", capability)
        self._set("_percentage", percentage)
        self._set("_allowlist", allowlist)
        self._set("_min_build", min_build)
        self._set("_max_build", max_build)
        self._set("_min_schema", min_schema)
        self._set("_max_schema", max_schema)
        self._set("_issued_at", issued_at)
        self._set("_ttl_seconds", ttl_seconds)

    @classmethod
    def from_mapping(cls, capability: Any, mapping: Any) -> "Optional[ReleaseRule]":
        """Build a rule from an *exact* ``dict``; return ``None`` if anything is
        missing, wrong-typed, or out of range (unknown flag -> fail closed)."""
        if not valid_capability_name(capability):
            return None
        if type(mapping) is not dict:
            return None

        percentage = coerce_int_in_range(mapping.get("percentage"), 0, 100, -1)
        if percentage < 0:
            return None

        issued_at = coerce_int_in_range(
            mapping.get("issued_at"), 0, MAX_EPOCH_SECONDS, -1
        )
        if issued_at < 0:
            return None

        # TTL must be strictly positive: zero / negative / bool / non-finite /
        # huge / wrong-type all fall outside [1, MAX_TTL_SECONDS].
        ttl_seconds = coerce_int_in_range(
            mapping.get("ttl_seconds"), 1, MAX_TTL_SECONDS, -1
        )
        if ttl_seconds < 0:
            return None

        min_build = _optional_bound(mapping, "min_build", 0, MAX_VERSION)
        max_build = _optional_bound(mapping, "max_build", 0, MAX_VERSION)
        min_schema = _optional_bound(mapping, "min_schema", 0, MAX_VERSION)
        max_schema = _optional_bound(mapping, "max_schema", 0, MAX_VERSION)
        if _SENTINEL_INVALID in (min_build, max_build, min_schema, max_schema):
            return None

        allowlist = _coerce_allowlist(mapping)

        return cls(
            capability,
            percentage,
            allowlist,
            min_build,
            max_build,
            min_schema,
            max_schema,
            issued_at,
            ttl_seconds,
        )

    @property
    def capability(self) -> str:
        return self._capability

    @property
    def percentage(self) -> int:
        return self._percentage

    @property
    def allowlist(self) -> Tuple[str, ...]:
        return self._allowlist


class ReleaseConfig(Immutable):
    """An immutable, validated flag -> rule store.

    The evaluation engine deliberately does **not** call :meth:`get` (a
    subclass could override it); it asserts the exact type and reads the
    private validated store directly.  :meth:`get` exists only for inspection.
    """

    __slots__ = ("_rules",)

    def __init__(self, mapping: Any = None) -> None:
        rules = {}
        if type(mapping) is dict:
            for key in list(mapping.keys()):
                if not valid_capability_name(key):
                    continue
                rule = ReleaseRule.from_mapping(key, mapping[key])
                if rule is not None:
                    rules[key] = rule
        # Read-only view: neither the caller nor later code can mutate the store.
        self._set("_rules", MappingProxyType(rules))

    def get(self, flag: Any) -> "Optional[ReleaseRule]":
        if type(flag) is not str:
            return None
        return self._rules.get(flag)

    def __contains__(self, flag: Any) -> bool:
        return type(flag) is str and flag in self._rules


class Entitlement(Immutable):
    """A pre-existing authorization to attempt a capability.

    Release control may *restrict* an authorized capability but can never
    create authorization.  Construction accepts an exact ``list`` / ``tuple`` /
    ``set`` / ``frozenset`` of exact capability strings; anything else (a dict
    claiming authorization, a subclass, a hostile object) authorizes nothing.
    """

    __slots__ = ("_authorized",)

    def __init__(self, capabilities: Any = None) -> None:
        authorized = set()
        if type(capabilities) in (list, tuple, set, frozenset):
            for item in capabilities:
                if valid_capability_name(item):
                    authorized.add(item)
        self._set("_authorized", frozenset(authorized))

    def authorizes(self, capability: Any) -> bool:
        return type(capability) is str and capability in self._authorized

    @property
    def authorized(self) -> "frozenset":
        return self._authorized


class EvaluationContext(Immutable):
    """The runtime facts required to evaluate a rollout.

    Every fact is supplied by the caller as plain data; the engine performs no
    environment / clock / filesystem access.  ``ready`` fails closed to
    ``False``; ``kill_switch`` fails closed to ``True`` (killed).  Malformed
    numeric facts set ``numbers_valid`` to ``False``, which the engine treats
    as malformed input (deny).
    """

    __slots__ = (
        "_build",
        "_schema",
        "_now",
        "_cohort",
        "_ready",
        "_kill_switch",
        "_numbers_valid",
    )

    def __init__(
        self,
        build: Any,
        schema: Any,
        now: Any,
        cohort: Any,
        ready: Any,
        kill_switch: Any,
    ) -> None:
        build_value = coerce_int_in_range(build, 0, MAX_VERSION, -1)
        schema_value = coerce_int_in_range(schema, 0, MAX_VERSION, -1)
        now_value = coerce_int_in_range(now, 0, MAX_EPOCH_SECONDS, -1)
        self._set("_build", build_value)
        self._set("_schema", schema_value)
        self._set("_now", now_value)
        self._set(
            "_cohort",
            cohort if (type(cohort) is str and len(cohort) <= MAX_COHORT_LEN) else "",
        )
        self._set("_ready", coerce_bool(ready, False))
        self._set("_kill_switch", coerce_bool(kill_switch, True))
        self._set(
            "_numbers_valid",
            build_value >= 0 and schema_value >= 0 and now_value >= 0,
        )

    @property
    def build(self) -> int:
        return self._build

    @property
    def schema(self) -> int:
        return self._schema

    @property
    def now(self) -> int:
        return self._now

    @property
    def cohort(self) -> str:
        return self._cohort

    @property
    def ready(self) -> bool:
        return self._ready

    @property
    def kill_switch(self) -> bool:
        return self._kill_switch

    @property
    def numbers_valid(self) -> bool:
        return self._numbers_valid
