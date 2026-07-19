"""Protected capability constants (read-only, deeply immutable).

This module exposes an inert, read-only view of the capabilities the successor
treats as *protected* -- capabilities a release rule may reference but that this
package can never itself grant, issue, or mutate.  There is deliberately **no**
grant/entitlement authority API and **no** membership-probe API that would hash a
caller-supplied key.
"""

from __future__ import annotations

# A frozenset is deeply immutable and its members are plain interned strings.
PROTECTED_CAPABILITIES = frozenset(
    {
        "read",
        "write",
        "admin",
        "billing",
        "export",
    }
)


def protected_capabilities() -> frozenset:
    """Return the protected-capability set (an immutable ``frozenset``).

    Read-only: this reports what is protected; it never grants, revokes, or
    checks a caller key against the set (which would hash the caller value).
    """
    return PROTECTED_CAPABILITIES
