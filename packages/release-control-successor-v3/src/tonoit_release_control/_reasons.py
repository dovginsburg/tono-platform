"""Fixed, finite reason/gate codes and bounds.

All codes are genuine built-in ``int`` values so telemetry never leaks an
enum instance or any caller-derived scalar.
"""

from __future__ import annotations

TELEMETRY_SCHEMA_VERSION = 1

# Reason codes -------------------------------------------------------------
REASON_OK = 0
REASON_UNKNOWN_FLAG = 1
REASON_KILLED = 2
REASON_NOT_READY = 3
REASON_NO_AUTHORITY = 4
REASON_BUILD_GATE = 5
REASON_SCHEMA_GATE = 6
REASON_TTL_EXPIRED = 7
REASON_NOT_IN_ALLOWLIST = 8
REASON_NOT_IN_COHORT = 9
REASON_INVALID = 10

# Gate stage codes ---------------------------------------------------------
GATE_NONE = 0
GATE_KILL = 1
GATE_READY = 2
GATE_AUTHORITY = 3
GATE_BUILD = 4
GATE_SCHEMA = 5
GATE_TTL = 6
GATE_ALLOWLIST = 7
GATE_COHORT = 8
GATE_INPUT = 9

# Bounds -------------------------------------------------------------------
MAX_FLAG_LEN = 256
MAX_ID_LEN = 256
MAX_ALLOWLIST = 10000
MAX_BUILD = 1 << 31
MAX_SCHEMA = 1 << 31
MAX_COHORT = 100
# Upper bound on an acceptable epoch-seconds TTL (~year 2100); anything above
# is treated as a non-finite/"huge" value and fails closed.
MAX_EPOCH = 4102444800.0

PROTECTED_CAPABILITIES = frozenset({"safety", "help", "export", "delete", "recovery"})
