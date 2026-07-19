"""Bounded, in-memory, no-I/O credential scan.

Operates only on an already-in-memory list/tuple of strings supplied by the
caller (the package never reads files or the network). Work is bounded by
``max_lines``, ``max_line_len``, and ``max_findings`` so a hostile or huge
input cannot cause unbounded work. All patterns use fixed/limited repetition
to avoid catastrophic backtracking. The result is scalar-only.
"""

from __future__ import annotations

import re

from ._reasons import TELEMETRY_SCHEMA_VERSION

_PATTERNS = (
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"-----BEGIN [A-Z ]{0,40}PRIVATE KEY-----"),
    re.compile(r"ghp_[A-Za-z0-9]{36}"),
    re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,64}"),
    re.compile(
        r"(?i)(?:api[_-]?key|secret|password|passwd|token)"
        r"\s{0,4}[:=]\s{0,4}['\"][^'\"\n]{8,128}['\"]"
    ),
)


def scan_credentials(lines, max_lines=10000, max_line_len=4096, max_findings=1000):
    scanned = 0
    findings = 0
    truncated = False
    if type(lines) not in (list, tuple):
        return {
            "scanned": 0,
            "findings": 0,
            "truncated": False,
            "schema_version": TELEMETRY_SCHEMA_VERSION,
        }
    try:
        for line in lines:
            if scanned >= max_lines:
                truncated = True
                break
            scanned += 1
            if type(line) is not str:
                continue
            segment = line[:max_line_len]
            for pattern in _PATTERNS:
                if pattern.search(segment) is not None:
                    findings += 1
                    if findings >= max_findings:
                        truncated = True
                        break
            if findings >= max_findings:
                truncated = True
                break
    except Exception:
        pass
    return {
        "scanned": int(scanned),
        "findings": int(findings),
        "truncated": bool(truncated),
        "schema_version": TELEMETRY_SCHEMA_VERSION,
    }
