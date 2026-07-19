"""Hostile value factories shared across the regression tests.

These deliberately abuse ``__eq__`` / ``__hash__`` / ``__str__`` and hashability
so the tests can prove the package validates by *exact type* and never invokes a
dunder on an untrusted value.
"""


class EqualityHashMimic:
    """Mimics the equality and hash of a target enum member.

    A naive validator that does ``value in {members...}`` will match this object
    and (worse) retain it.  ``value`` is a mutable attribute so a test can prove
    the object was never retained by mutating it after construction.
    """

    def __init__(self, target, value="hard"):
        self._target = target
        self.value = value

    def __hash__(self):
        return hash(self._target)

    def __eq__(self, other):
        return True


class RaisingObject:
    """Every dunder a validator might touch raises loudly."""

    def __eq__(self, other):
        raise RuntimeError("hostile __eq__ was called")

    def __ne__(self, other):
        raise RuntimeError("hostile __ne__ was called")

    def __hash__(self):
        raise RuntimeError("hostile __hash__ was called")

    def __lt__(self, other):
        raise RuntimeError("hostile __lt__ was called")

    def __str__(self):
        raise RuntimeError("hostile __str__ was called")

    def __repr__(self):
        raise RuntimeError("hostile __repr__ was called")

    # Present so accessing an attribute name that looks like ``.value`` raises.
    def __getattr__(self, name):
        raise RuntimeError("hostile __getattr__ was called for %r" % (name,))


class UnhashableCustom:
    """Instances are unhashable (``hash()`` raises ``TypeError``)."""

    __hash__ = None


def unhashable_values():
    """Fresh unhashable values for each call (mutable containers included)."""
    return [[], {}, set(), bytearray(b"x"), UnhashableCustom()]


class BoolLike:
    """An object that compares/behaves ``True`` but is not an exact ``bool``."""

    def __bool__(self):
        return True

    def __eq__(self, other):
        return other is True

    def __hash__(self):
        return hash(True)
