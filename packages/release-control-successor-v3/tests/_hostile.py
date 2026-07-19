"""Shared hostile test fixtures for the release-control suite.

These objects model adversarial callers. They are deliberately NOT stored in
package source (so the credential scan of source stays clean) and any fake
credential material is assembled at runtime by concatenation, never as a
literal, so it never appears verbatim in a tracked file.
"""

from __future__ import annotations


class RaisingEqKey:
    """Insertable once (constant hash); every equality probe raises.

    A single-entry dict can be built. Any later membership test, lookup, or
    ``set(d.keys())`` on that dict re-triggers ``__eq__`` on collision and
    raises. Safe iteration of ``.items()`` never does.
    """

    __slots__ = ()

    def __hash__(self):
        return 0x5EED

    def __eq__(self, other):
        raise RuntimeError("hostile __eq__ was executed")

    def __ne__(self, other):
        raise RuntimeError("hostile __ne__ was executed")


class HashRaisesLaterKey:
    """Hashes exactly once (insertion); every subsequent hash raises."""

    def __init__(self):
        self._n = 0

    def __hash__(self):
        self._n += 1
        if self._n > 1:
            raise RuntimeError("hostile __hash__ re-executed")
        return 0x1234

    def __eq__(self, other):
        return False


class HashChangingKey:
    """Returns a different hash on every call (violates hash stability)."""

    def __init__(self):
        self._h = 1000

    def __hash__(self):
        self._h += 7
        return self._h

    def __eq__(self, other):
        return False


class CountingKey:
    """Counts hash/eq executions across the class so a test can assert zero."""

    hashes = 0
    eqs = 0

    @classmethod
    def reset(cls):
        cls.hashes = 0
        cls.eqs = 0

    def __hash__(self):
        type(self).hashes += 1
        return 7

    def __eq__(self, other):
        type(self).eqs += 1
        return False


class StrSubclassKey(str):
    """A str subclass with hostile dunders — ``type(x) is str`` must reject it."""

    def __hash__(self):
        return 99

    def __eq__(self, other):
        raise RuntimeError("hostile subclass __eq__ was executed")


class RaisingValue:
    """A value (not a key) whose conversions/truthiness raise (Exception)."""

    __hash__ = None  # unhashable: usable only as a value, never a key

    def __bool__(self):
        raise RuntimeError("hostile __bool__ was executed")

    def __int__(self):
        raise RuntimeError("hostile __int__ was executed")

    def __index__(self):
        raise RuntimeError("hostile __index__ was executed")


class ExplodingIter:
    """An iterable whose ``__iter__`` raises the given exception."""

    def __init__(self, exc):
        self._exc = exc

    def __iter__(self):
        raise self._exc


class ExplodingItems:
    """A mapping-like object whose ``items``/iteration raises — a custom map."""

    def items(self):
        raise RuntimeError("hostile items() was executed")

    def keys(self):
        raise RuntimeError("hostile keys() was executed")

    def __getitem__(self, k):
        raise RuntimeError("hostile __getitem__ was executed")

    def __iter__(self):
        raise RuntimeError("hostile __iter__ was executed")


def fake_aws_key():
    """Assemble an AWS-key-shaped string at runtime (never a source literal)."""
    return "AKIA" + ("Q7" * 8)


def fake_private_key_header():
    return "-----BEGIN " + "RSA" + " PRIVATE KEY-----"


def fake_token_assignment():
    return "api_key" + " = " + "'" + ("x" * 20) + "'"
