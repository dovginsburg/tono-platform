"""Shared hostile-object builders for the test-suite.

Everything here is deliberately adversarial: forged model instances built by
by-passing the normal constructor, callables/descriptors that must never be
invoked, and keys whose ``__hash__`` / ``__eq__`` explode if touched.  The
package under test must survive contact with all of them without raising and
without executing any of the traps.
"""

from __future__ import annotations


class HashTrap:
    """A key that records/raises if it is ever hashed or compared.

    A correct validator never rehashes or probes arbitrary caller keys, so
    ``hashed`` / ``eq_calls`` must stay at zero after the package touches a
    forged model carrying one of these.
    """

    def __init__(self) -> None:
        self.hashed = 0
        self.eq_calls = 0

    def __hash__(self) -> int:  # pragma: no cover - must never run
        self.hashed += 1
        raise AssertionError("hostile __hash__ executed")

    def __eq__(self, other) -> bool:  # pragma: no cover - must never run
        self.eq_calls += 1
        raise AssertionError("hostile __eq__ executed")


class CallTrap:
    """A callable/descriptor backdoor that records if invoked.

    A correct implementation reads field *values* only; it never calls them
    and never triggers ``__get__``.  ``calls`` and ``gets`` must stay zero.
    """

    def __init__(self) -> None:
        self.calls = 0
        self.gets = 0

    def __call__(self, *a, **k):  # pragma: no cover - must never run
        self.calls += 1
        raise AssertionError("callable backdoor invoked")

    def __get__(self, obj, owner=None):  # pragma: no cover - must never run
        self.gets += 1
        raise AssertionError("descriptor backdoor invoked")


class Boom:
    """An object whose every ordinary access raises a *normal* Exception."""

    def __getattr__(self, name):  # pragma: no cover - defensive
        raise ValueError("boom")


def empty_instance(model):
    """``tuple.__new__(Model, ())`` -- exact type, zero fields."""
    return tuple.__new__(model, ())


def short_instance(model, values):
    """Exact type, too few fields."""
    return tuple.__new__(model, tuple(values))


def forged_instance(model, values):
    """Exact type, right arity but hostile/garbage field values."""
    return tuple.__new__(model, tuple(values))
