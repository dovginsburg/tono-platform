"""Exact-type coercion primitives and an immutable base class.

Security rule enforced throughout: *never invoke a dunder method on an
untrusted value while validating it*.  ``type(x) is T`` inspects the object's
type slot without touching ``__eq__`` / ``__hash__`` / ``__lt__`` / ``__str__``
on the instance.  Consequently:

* an equality/hash mimic cannot be mistaken for a real enum member,
* an unhashable value (``[]``, ``{}``, a custom object) cannot raise, and
* an accessor that raises is never called.

Membership tests, ``==`` comparisons and hashing of untrusted values are
deliberately avoided.  This module performs no I/O and imports only from the
standard library.
"""
from __future__ import annotations

from typing import Any


class Immutable:
    """Base that blocks attribute mutation after construction.

    Subclasses set their state exactly once, from ``__init__``, via ``_set``
    (which routes through ``object.__setattr__``).  Every later assignment or
    deletion raises.  Combined with storing only immutable built-in scalars and
    enum members, this guarantees that neither the caller nor later code can
    alter a constructed model's serialized output.
    """

    __slots__ = ()

    def __setattr__(self, name: str, value: Any) -> None:  # noqa: D401
        raise AttributeError("release-control objects are immutable")

    def __delattr__(self, name: str) -> None:
        raise AttributeError("release-control objects are immutable")

    def _set(self, name: str, value: Any) -> None:
        object.__setattr__(self, name, value)


def is_exact_bool(value: Any) -> bool:
    return type(value) is bool


def is_exact_int(value: Any) -> bool:
    # ``type(value) is int`` is already False for ``bool`` (whose type is
    # ``bool``, not ``int``), so bool-as-int cannot slip through.
    return type(value) is int


def is_exact_str(value: Any) -> bool:
    return type(value) is str


def is_exact_dict(value: Any) -> bool:
    return type(value) is dict


def coerce_bool(value: Any, default: bool) -> bool:
    """Return ``value`` iff it is exactly ``True``/``False`` else ``default``."""
    return value if type(value) is bool else default


def coerce_int_in_range(value: Any, low: int, high: int, default: int) -> int:
    """Return ``value`` iff it is exactly an ``int`` within ``[low, high]``.

    The type gate short-circuits before any comparison, so a non-finite float
    (``inf``/``nan``) or a hostile object is never fed to ``<=`` (``nan`` never
    reaches a comparison), a ``bool`` is rejected, and a huge integer is
    rejected by the explicit bound check rather than overflowing.
    """
    if type(value) is int and low <= value <= high:
        return value
    return default


def coerce_enum(value: Any, enum_cls: Any, default: Any) -> Any:
    """Return ``value`` iff it is *exactly* a member of ``enum_cls``.

    A foreign object whose ``__eq__`` / ``__hash__`` mimic a real member, or an
    unhashable value, is rejected here and the inert ``default`` member is
    returned instead, so the hostile object is never retained nor emitted.
    """
    # Exact identity of the type object: no membership test, no comparison, no
    # hashing of ``value``.  A hostile value never has a dunder invoked, so it
    # can neither be mistaken for a member nor raise.
    if type(value) is enum_cls:
        return value
    return default
