"""Remediation regressions for the operational + release-readiness blockers.

Covers:
  * Blocker B — account backfill is wired into the app STARTUP lifespan (not a
    test-only direct call), so a legacy NULL-account device is repaired before
    any purchase/register route is served.
  * Blocker C — the iOS canonical tri-state is the sole Pro authority; a missing
    build-91 state fails closed with no cached-Bool fallback (source-focused,
    the surface can't run under XCTest here).
  * Blocker E — the build-90 charged-before-upgrade release gate fails closed by
    default and is wired into the build-91 verification path.
"""

from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
IOS_SCRIPTS = REPO_ROOT / "apps" / "ios" / "Scripts"


def _load_gate():
    spec = importlib.util.spec_from_file_location(
        "build90_recovery_gate", IOS_SCRIPTS / "build90_recovery_gate.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ===========================================================================
# Blocker A (QA regression) — supabase_sub migration ordering
# ===========================================================================


def test_supabase_sub_migration_ordering_on_legacy_db(_isolate_db):
    """Regression: Store.__init__ must not crash when the accounts table
    predates supabase_sub. On a migrated DB, CREATE TABLE IF NOT EXISTS is a
    no-op, so SCHEMA's CREATE UNIQUE INDEX idx_accounts_supabase_sub would run
    before the ALTER TABLE adds the column — crashing startup. The index must
    be created after the ALTER TABLE migration, not inside executescript(SCHEMA).
    """
    db_path = os.environ["TONO_DB_PATH"]

    # Reproduce the exact pre-change production shape: only the accounts table
    # is pre-created (without supabase_sub), simulating a DB from before the
    # column was added. All other tables/indexes are absent and will be minted
    # fresh by SCHEMA — the crash only happens because CREATE TABLE IF NOT
    # EXISTS accounts is a no-op and SCHEMA then tries to index a missing column.
    pre_change_schema = """
    CREATE TABLE accounts (
        id                      TEXT PRIMARY KEY,
        apple_sub               TEXT UNIQUE,
        google_sub              TEXT UNIQUE,
        email                   TEXT,
        plan                    TEXT NOT NULL DEFAULT 'free',
        stripe_customer_id      TEXT,
        stripe_subscription_id  TEXT,
        subscription_status     TEXT,
        subscription_renews_at  TEXT,
        coupon_pro_expires_at   TEXT,
        daily_count             INTEGER NOT NULL DEFAULT 0,
        daily_day               TEXT,
        created_at              TEXT NOT NULL,
        updated_at              TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_accounts_apple_sub ON accounts(apple_sub);
    CREATE INDEX IF NOT EXISTS idx_accounts_google_sub ON accounts(google_sub);
    CREATE INDEX IF NOT EXISTS idx_accounts_stripe_customer ON accounts(stripe_customer_id);
    """
    con = sqlite3.connect(db_path)
    try:
        con.executescript(pre_change_schema)
        cols = {r[1] for r in con.execute("PRAGMA table_info(accounts)").fetchall()}
        assert "supabase_sub" not in cols, "pre-condition: supabase_sub must not exist yet"
    finally:
        con.close()

    # Opening the Store against this pre-change DB must not crash.
    from backend.store import Store

    s = Store(db_path)
    s.close()

    # After init: column and unique index must both be present.
    con = sqlite3.connect(db_path)
    try:
        cols = {r[1] for r in con.execute("PRAGMA table_info(accounts)").fetchall()}
        assert "supabase_sub" in cols, "supabase_sub column missing after migration"

        idx_rows = {r[1]: r[2] for r in con.execute("PRAGMA index_list(accounts)").fetchall()}
        assert "idx_accounts_supabase_sub" in idx_rows, "idx_accounts_supabase_sub index missing"
        assert idx_rows["idx_accounts_supabase_sub"] == 1, "idx_accounts_supabase_sub must be UNIQUE"
    finally:
        con.close()


# ===========================================================================
# Blocker B — startup backfill wiring
# ===========================================================================


def test_backfill_missing_accounts_runs_on_app_startup(_isolate_db):
    """A legacy device row with a NULL account_id is backfilled by the app
    lifespan on startup — proven WITHOUT calling backfill_missing_accounts()
    directly (the exact gap the prior candidate had)."""
    from fastapi.testclient import TestClient

    from backend.store import get_store, reset_store

    db_path = os.environ["TONO_DB_PATH"]

    # Materialize the schema, then forget the singleton so the lifespan re-opens.
    get_store()
    reset_store()

    # Seed a legacy anonymous device with NO account (pre-account-first contract).
    now = "2026-01-01T00:00:00+00:00"
    con = sqlite3.connect(db_path)
    try:
        con.execute(
            "INSERT INTO users (device_id, api_token, plan, subscription_status, created_at, updated_at) "
            "VALUES ('legacy-null-startup', 'tok-legacy-null', 'pro', 'active', ?, ?)",
            (now, now),
        )
        con.commit()
        assert con.execute("SELECT COUNT(*) FROM users WHERE account_id IS NULL").fetchone()[0] == 1
    finally:
        con.close()

    # Entering the app is the ONLY trigger here — no direct backfill call.
    from backend.server import app

    with TestClient(app):
        pass

    con = sqlite3.connect(db_path)
    try:
        assert con.execute("SELECT COUNT(*) FROM users WHERE account_id IS NULL").fetchone()[0] == 0
        account_id = con.execute(
            "SELECT account_id FROM users WHERE device_id='legacy-null-startup'"
        ).fetchone()[0]
        assert account_id  # a real, non-null account UUID was minted
        # The device's own Pro (plan/status) is preserved onto the new account.
        row = con.execute("SELECT plan, subscription_status FROM accounts WHERE id=?", (account_id,)).fetchone()
        assert row == ("pro", "active")
    finally:
        con.close()


def test_startup_backfill_is_idempotent_across_reopens(_isolate_db):
    """A second startup finds nothing null and mutates nothing (idempotent)."""
    from fastapi.testclient import TestClient

    from backend.store import get_store, reset_store

    db_path = os.environ["TONO_DB_PATH"]
    get_store()
    reset_store()
    con = sqlite3.connect(db_path)
    try:
        con.execute(
            "INSERT INTO users (device_id, api_token, plan, created_at, updated_at) "
            "VALUES ('legacy-null-2', 'tok-2', 'free', '2026-01-01T00:00:00+00:00', '2026-01-01T00:00:00+00:00')"
        )
        con.commit()
    finally:
        con.close()

    from backend.server import app

    with TestClient(app):
        pass
    con = sqlite3.connect(db_path)
    try:
        accounts_after_first = con.execute("SELECT COUNT(*) FROM accounts").fetchone()[0]
    finally:
        con.close()

    reset_store()
    with TestClient(app):
        pass
    con = sqlite3.connect(db_path)
    try:
        assert con.execute("SELECT COUNT(*) FROM users WHERE account_id IS NULL").fetchone()[0] == 0
        assert con.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == accounts_after_first
    finally:
        con.close()


# ===========================================================================
# Blocker C — iOS tri-state closure (source-focused; no XCTest here)
# ===========================================================================


IOS = REPO_ROOT / "apps" / "ios"


def _swift(rel: str) -> str:
    return (IOS / rel).read_text(encoding="utf-8")


def test_isProAuthoritative_fails_closed_on_missing_state():
    src = _swift("Shared/SharedUserDefaults.swift")
    assert "case nil: return false" in src
    # The prior candidate's cached-Bool fallback must be gone.
    assert "case nil: return proUnlocked" not in src


@pytest.mark.parametrize(
    "rel",
    [
        "Shared/FeatureFlags.swift",
        "App/MemoryView.swift",
        "App/DigestView.swift",
        "Shared/CrashReporter.swift",
    ],
)
def test_consumers_do_not_authorize_from_cached_bool(rel):
    assert "TonePreferences().proUnlocked" not in _swift(rel)


def test_widget_uses_tristate_not_cached_bool():
    src = _swift("Widget/TonoWidget.swift")
    assert 'd.bool(forKey: "tc.proUnlocked")' not in src
    assert 'd.string(forKey: "tc.entitlementState") == "entitled"' in src


def test_keyboard_writes_mirror_via_recordEntitlement():
    src = _swift("KeyboardExtension/KeyboardRootView.swift")
    assert "SharedStore.defaults.set(usage.isPro, forKey: SharedKeys.proUnlocked)" not in src
    assert "TonePreferences.recordEntitlement(" in src


# ===========================================================================
# Blocker E — build-90 charged-before-upgrade release gate (fail closed)
# ===========================================================================


def test_release_gate_fails_closed_with_shipped_artifact():
    gate = _load_gate()
    result = gate.evaluate(gate.load_artifact(), env={})
    assert result.ready is False
    assert result.evidence_source is None
    assert any("UNRESOLVED" in r for r in result.reasons)


def test_release_gate_ready_with_checkout_disabled_evidence():
    gate = _load_gate()
    artifact = gate.load_artifact()
    artifact["evidence"]["checkout_disabled"] = {
        "supplied": True,
        "source": "App Store Connect",
        "verified_by": "release-owner",
        "verified_at": "2026-07-17T00:00:00Z",
        "reference": "ASC build-90 phased release halted; checkout disabled",
    }
    result = gate.evaluate(artifact, env={})
    assert result.ready is True
    assert result.evidence_source == "artifact"


def test_release_gate_ready_with_owner_approved_bounded_policy():
    gate = _load_gate()
    artifact = gate.load_artifact()
    artifact["evidence"]["charged_before_upgrade_policy"] = {
        "supplied": True,
        "owner_approved": True,
        "approved_by": "release-owner",
        "approved_at": "2026-07-17T00:00:00Z",
        "bounded_window_days": 30,
        "policy_reference": "owner-approved bounded post-charge recovery policy #123",
    }
    result = gate.evaluate(artifact, env={})
    assert result.ready is True


def test_release_gate_rejects_fabricated_incomplete_evidence():
    """A bare `supplied: true` without corroborating fields cannot pass — the
    gate refuses to be tricked by a fabricated flag."""
    gate = _load_gate()
    artifact = gate.load_artifact()
    artifact["evidence"]["checkout_disabled"] = {"supplied": True}
    artifact["evidence"]["charged_before_upgrade_policy"] = {"supplied": True, "owner_approved": True}
    result = gate.evaluate(artifact, env={})
    assert result.ready is False
    assert any("missing" in r for r in result.reasons)


def test_release_gate_env_override_ready(tmp_path):
    gate = _load_gate()
    evidence_file = tmp_path / "evidence.json"
    evidence_file.write_text(
        json.dumps(
            {
                "evidence": {
                    "charged_before_upgrade_policy": {
                        "supplied": True,
                        "owner_approved": True,
                        "approved_by": "owner",
                        "approved_at": "2026-07-17T00:00:00Z",
                        "bounded_window_days": 14,
                        "policy_reference": "ticket-42",
                    }
                }
            }
        )
    )
    result = gate.evaluate(gate.load_artifact(), env={gate.EVIDENCE_ENV: str(evidence_file)})
    assert result.ready is True
    assert result.evidence_source == gate.EVIDENCE_ENV


def test_release_gate_env_override_broken_pointer_fails_closed():
    gate = _load_gate()
    result = gate.evaluate(gate.load_artifact(), env={gate.EVIDENCE_ENV: "/nonexistent/evidence.json"})
    assert result.ready is False


def test_build91_verification_path_fails_closed_by_default():
    """The build-91 verifier (which the gate is wired into) fails closed on the
    unresolved build-90 prerequisite, and passes only when evidence is supplied
    out-of-band. Proves the gate actually blocks the release path."""
    verifier = REPO_ROOT / "apps" / "ios" / "Scripts" / "verify_build91_entitlement_contract.py"
    env = dict(os.environ)
    env.pop("TONO_BUILD90_RECOVERY_EVIDENCE", None)
    blocked = subprocess.run(
        [sys.executable, str(verifier)], cwd=REPO_ROOT, capture_output=True, text=True, env=env
    )
    assert blocked.returncode == 1
    assert "charged-before-upgrade" in (blocked.stdout + blocked.stderr)

    # Supplying complete evidence out-of-band flips the whole verification path
    # to PASS — the gate is the only thing blocking it.
    import tempfile

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(
            {
                "evidence": {
                    "checkout_disabled": {
                        "supplied": True,
                        "source": "TestFlight",
                        "verified_by": "owner",
                        "verified_at": "2026-07-17T00:00:00Z",
                        "reference": "build 90 checkout disabled",
                    }
                }
            },
            handle,
        )
        evidence_path = handle.name
    try:
        env["TONO_BUILD90_RECOVERY_EVIDENCE"] = evidence_path
        ready = subprocess.run(
            [sys.executable, str(verifier)], cwd=REPO_ROOT, capture_output=True, text=True, env=env
        )
        assert ready.returncode == 0, ready.stdout + ready.stderr
        assert "build91-entitlement-contract: PASS" in ready.stdout
    finally:
        os.unlink(evidence_path)
