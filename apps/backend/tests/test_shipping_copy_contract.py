"""Shipping-copy contract lint.

The commercial contract is "14-day free trial, NO free daily tier, fail closed".
This test scans the SHIPPING surfaces (web pages + API routes, iOS/Android store
metadata, App Store review notes, StoreKit config, and user-facing app UI) and
fails if any retired 7-day-trial or free-daily-tier copy — or any client-side
free-tier scaffolding identifier — still ships. Dev-only design docs
(SCOPE.md / BRIEF.md / CLAUDE.md business-model exploration) are intentionally
out of scope: they are historical analysis, not customer-facing claims.
"""

from __future__ import annotations

import re
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[3]

# Concrete shipping surfaces (globs relative to repo root). Kept explicit so we
# never accidentally scan node_modules / build output / tests / dev docs.
_SHIPPING_GLOBS = [
    "apps/web/src/app/**/*.tsx",
    "apps/web/src/app/**/*.ts",
    "apps/ios/fastlane/metadata/**/*.txt",
    "apps/ios/AppStore/*.txt",
    "apps/ios/AppStoreMetadata/*.md",
    "apps/ios/AppStoreReviewNotes.md",
    "apps/ios/App/Tono.storekit",
    "apps/ios/App/*.swift",
    "apps/ios/Widget/*.swift",
    "apps/android/fastlane/metadata/**/*.txt",
    "apps/android/app/src/main/**/*.kt",
]

# (label, pattern). IGNORECASE. Each pattern must match ONLY retired copy — never
# a legitimate identifier (e.g. the API field ``daily_limit`` / ``dailyLimit`` is
# deliberately NOT forbidden; only user-facing free-tier prose is).
_FORBIDDEN = [
    # Retired 7-day trial (the contract trial is 14 days / P2W).
    ("7-day trial", re.compile(r"\b7[\s\-]?day\b", re.IGNORECASE)),
    ("P1W trial", re.compile(r"\bP1W\b")),
    ("first 7 days", re.compile(r"first\s+7\s+days", re.IGNORECASE)),
    ("free for 7 days", re.compile(r"free\s+for\s+7\s+days", re.IGNORECASE)),
    ("seven-day", re.compile(r"seven[\s\-]day", re.IGNORECASE)),
    ("day-8 trial window", re.compile(r"\bday\s*8\b", re.IGNORECASE)),
    # Retired free daily tier.
    ("N free rewrites", re.compile(r"\b10\s+free\b", re.IGNORECASE)),
    ("10 rewrites", re.compile(r"\b10\s+rewrites\b", re.IGNORECASE)),
    ("10 Coach runs", re.compile(r"\b10\s+coach\b", re.IGNORECASE)),
    ("rewrites/day", re.compile(r"rewrites?\s*/\s*day", re.IGNORECASE)),
    ("rewrites per day", re.compile(r"rewrites?\s+per\s+day", re.IGNORECASE)),
    ("runs per day", re.compile(r"runs?\s+per\s+day", re.IGNORECASE)),
    ("sessions/day", re.compile(r"sessions?\s*/\s*day", re.IGNORECASE)),
    ("coaching sessions/day", re.compile(r"coaching\s+sessions", re.IGNORECASE)),
    ("3/day", re.compile(r"\b3\s*/\s*day\b", re.IGNORECASE)),
    ("free-tier daily", re.compile(r"free[\s\-]tier\s+daily", re.IGNORECASE)),
    ("daily free limit", re.compile(r"daily\s+free\s+limit", re.IGNORECASE)),
    ("free daily limit", re.compile(r"free\s+daily\s+limit", re.IGNORECASE)),
    ("free_daily_limit", re.compile(r"free_daily_limit", re.IGNORECASE)),
    ("Free: N / Free · N", re.compile(r"free\s*[·:]\s*\d", re.IGNORECASE)),
    # Client-side free-tier scaffolding identifiers (removed).
    ("FreeTierGate", re.compile(r"FreeTierGate")),
    ("freeTier* key", re.compile(r"freeTier(Used|Day|Limit)")),
    ("FREE_TIER_* const", re.compile(r"FREE_TIER_(USED|DAY|LIMIT)")),
]


def _shipping_files() -> list[Path]:
    files: list[Path] = []
    for glob in _SHIPPING_GLOBS:
        files.extend(sorted(_REPO_ROOT.glob(glob)))
    # De-dupe while preserving order.
    seen: set[Path] = set()
    unique: list[Path] = []
    for f in files:
        if f.is_file() and f not in seen:
            seen.add(f)
            unique.append(f)
    return unique


def test_no_shipping_seven_day_or_free_daily_drift():
    hits: list[str] = []
    for path in _shipping_files():
        rel = path.relative_to(_REPO_ROOT)
        for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            for label, pattern in _FORBIDDEN:
                if pattern.search(line):
                    hits.append(f"{rel}:{i}: [{label}] {line.strip()}")
    assert not hits, "retired trial/free-tier copy still ships:\n" + "\n".join(hits)


def test_scan_actually_covers_files():
    """Guard against an empty/misconfigured scan silently passing."""
    files = _shipping_files()
    assert len(files) >= 15, f"shipping-copy scan only found {len(files)} files"
    names = {p.name for p in files}
    assert "Tono.storekit" in names
    assert "app-store-listing.md" in names
