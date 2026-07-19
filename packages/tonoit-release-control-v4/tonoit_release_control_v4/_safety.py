"""Internal safety primitives.

These are the load-bearing helpers that make every public entry point *total*
(never raises for hostile input) while never becoming a backdoor:

* :func:`guard` runs a thunk, swallowing ordinary ``Exception`` and returning a
  caller-supplied default, but deliberately lets ``BaseException`` subclasses
  (``KeyboardInterrupt``, ``SystemExit``, ...) propagate.  Totality must never
  mean "eat Ctrl-C".
* the ``is_exact_*`` predicates use *type identity* so ``bool`` never sneaks in
  as ``int`` and a subclass instance never impersonates a scalar.
* field reads go through :func:`read_field`, which reads by position with
  ``tuple.__getitem__`` -- bypassing any class-level descriptor and never
  invoking a field value.  Forged/short instances yield the ``MISSING`` sentinel
  instead of raising ``IndexError``.

Nothing here hashes, compares, iterates, or calls a caller-provided value.
"""

from __future__ import annotations

import math
from typing import Any, Callable


class _Missing:
    __slots__ = ()

    def __repr__(self) -> str:  # pragma: no cover - cosmetic
        return "<MISSING>"


MISSING = _Missing()


def guard(thunk: Callable[[], Any], default: Any) -> Any:
    """Return ``thunk()``; on ordinary ``Exception`` return ``default``.

    ``BaseException`` subclasses that are *not* ``Exception`` (notably
    ``KeyboardInterrupt`` and ``SystemExit``) are re-raised: totality applies to
    error handling, never to interpreter-control signals.
    """
    try:
        return thunk()
    except Exception:
        return default


def read_field(inst: Any, index: int) -> Any:
    """Positional read that never triggers descriptors and never raises.

    Uses the unbound ``tuple`` methods so an overridden ``__len__`` /
    ``__getitem__`` (there is none on our models, but a defensive habit) can't
    interpose, and a short/empty tuple simply yields :data:`MISSING`.
    """
    try:
        if index < 0 or index >= tuple.__len__(inst):
            return MISSING
        return tuple.__getitem__(inst, index)
    except Exception:
        return MISSING


def is_exact_bool(x: Any) -> bool:
    return x is True or x is False


def is_exact_int(x: Any) -> bool:
    # Exclude bool (a subclass of int) via type identity.
    return type(x) is int


def is_exact_str(x: Any) -> bool:
    return type(x) is str


def is_exact_frozenset(x: Any) -> bool:
    # Type identity only -- we never iterate or probe the members, so hostile
    # element ``__hash__`` / ``__eq__`` can never be executed by this check.
    return type(x) is frozenset


def is_finite_real(x: Any) -> bool:
    """True for a finite, non-bool ``int``/``float`` scalar."""
    t = type(x)
    if t is int:
        return True
    if t is float:
        return math.isfinite(x)
    return False
