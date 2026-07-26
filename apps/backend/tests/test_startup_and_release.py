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
# G-1 (QA regression) — Render must fail closed on an ephemeral DB path
# ===========================================================================
#
# Render injects RENDER=true and mounts the persistent disk at /data. A DB
# written anywhere else (the "./tono.db" default, or any path outside /data)
# is wiped on every deploy. resolve_db_path() must reject that on Render while
# preserving the historical local/dev/test default when RENDER is absent.


def _fresh_store_module():
    from backend import store as store_module

    return store_module


def test_render_unset_preserves_local_default(monkeypatch):
    monkeypatch.delenv("RENDER", raising=False)
    monkeypatch.delenv("TONO_DB_PATH", raising=False)
    store = _fresh_store_module()
    assert store.resolve_db_path() == "./tono.db"


def test_render_unset_honors_explicit_path(monkeypatch):
    monkeypatch.delenv("RENDER", raising=False)
    monkeypatch.setenv("TONO_DB_PATH", "/tmp/tono_local_dev.db")
    store = _fresh_store_module()
    assert store.resolve_db_path() == "/tmp/tono_local_dev.db"


def test_render_rejects_missing_db_path(monkeypatch):
    monkeypatch.setenv("RENDER", "true")
    monkeypatch.delenv("TONO_DB_PATH", raising=False)
    store = _fresh_store_module()
    with pytest.raises(store.EphemeralDatabasePathError) as ei:
        store.resolve_db_path()
    assert "unset" in str(ei.value).lower()


def test_render_rejects_blank_db_path(monkeypatch):
    monkeypatch.setenv("RENDER", "true")
    monkeypatch.setenv("TONO_DB_PATH", "   ")
    store = _fresh_store_module()
    with pytest.raises(store.EphemeralDatabasePathError):
        store.resolve_db_path()


@pytest.mark.parametrize("bad_path", ["./tono.db", "/tmp/tono.db", "/var/data/tono.db"])
def test_render_rejects_path_outside_data(monkeypatch, bad_path):
    monkeypatch.setenv("RENDER", "true")
    monkeypatch.setenv("TONO_DB_PATH", bad_path)
    store = _fresh_store_module()
    with pytest.raises(store.EphemeralDatabasePathError) as ei:
        store.resolve_db_path()
    assert "/data" in str(ei.value)


def test_render_rejects_dotdot_escape_from_data(monkeypatch):
    """A path that lexically starts with /data but escapes it via `..` must be
    rejected — realpath normalization closes the containment bypass."""
    monkeypatch.setenv("RENDER", "true")
    monkeypatch.setenv("TONO_DB_PATH", "/data/../tmp/escape.db")
    store = _fresh_store_module()
    with pytest.raises(store.EphemeralDatabasePathError):
        store.resolve_db_path()


@pytest.mark.parametrize("good_path", ["/data/tono.db", "/data/sub/tono.db", "/data"])
def test_render_accepts_path_under_data(monkeypatch, good_path):
    monkeypatch.setenv("RENDER", "true")
    monkeypatch.setenv("TONO_DB_PATH", good_path)
    store = _fresh_store_module()
    assert store.resolve_db_path() == good_path


@pytest.mark.parametrize("truthy", ["true", "TRUE", "1", "yes"])
def test_render_truthy_values_all_enforce(monkeypatch, truthy):
    monkeypatch.setenv("RENDER", truthy)
    monkeypatch.setenv("TONO_DB_PATH", "/tmp/tono.db")
    store = _fresh_store_module()
    with pytest.raises(store.EphemeralDatabasePathError):
        store.resolve_db_path()


def test_render_falsey_value_treated_as_local(monkeypatch):
    """RENDER present but falsey (e.g. an explicitly-disabled override) must
    NOT enforce the /data guard — only a truthy RENDER means "on Render"."""
    monkeypatch.setenv("RENDER", "false")
    monkeypatch.setenv("TONO_DB_PATH", "/tmp/tono.db")
    store = _fresh_store_module()
    assert store.resolve_db_path() == "/tmp/tono.db"


def test_get_store_fails_closed_on_render_without_persistent_disk(monkeypatch):
    """The singleton accessor propagates the fail-closed error — startup cannot
    silently open an ephemeral DB on Render."""
    monkeypatch.setenv("RENDER", "true")
    monkeypatch.setenv("TONO_DB_PATH", "/tmp/tono_ephemeral.db")
    store = _fresh_store_module()
    store.reset_store()
    try:
        with pytest.raises(store.EphemeralDatabasePathError):
            store.get_store()
    finally:
        store.reset_store()


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


def _unresolved_artifact(gate):
    """The shipped artifact with both evidence forms reset to their
    pre-attestation shape — i.e. what ships if the owner attestation is ever
    reverted. Used to exercise fail-closed without mutating the tracked file."""
    artifact = gate.load_artifact()
    artifact["evidence"] = {
        "checkout_disabled": {
            "supplied": False, "source": None, "verified_by": None,
            "verified_at": None, "reference": None,
        },
        "charged_before_upgrade_policy": {
            "supplied": False, "owner_approved": False, "approved_by": None,
            "approved_at": None, "bounded_window_days": None, "policy_reference": None,
        },
    }
    return artifact


def test_release_gate_fails_closed_when_evidence_is_absent():
    """The load-bearing invariant: with NO evidence the gate blocks.

    This previously asserted the *shipped* artifact was unresolved. That stopped
    being true on 2026-07-25, when the owner attested (Dov Ginsburg, recorded in
    docs/operations/BUILD90-OWNER-ATTESTATION-2026-07-25.md) that nobody has paid
    via Stripe/Apple/Play, closing the gate through Form B over an empty
    population. The assertion is therefore re-expressed against a synthetic
    evidence-free artifact so the fail-closed property is still proven — the gate
    itself is unchanged and was NOT weakened.
    """
    gate = _load_gate()
    result = gate.evaluate(_unresolved_artifact(gate), env={})
    assert result.ready is False
    assert result.evidence_source is None
    assert any("UNRESOLVED" in r for r in result.reasons)


def test_shipped_artifact_is_owner_attested_ready_via_form_b_only():
    """Locks in the 2026-07-25 closure and its exact shape.

    Fails if the attestation is silently reverted, and — just as importantly —
    if anyone ever flips Form A (`checkout_disabled`) to supplied. No App Store
    Connect observation was ever made, so Form A must stay unclaimed; only the
    owner's Form B attestation closes this gate.
    """
    gate = _load_gate()
    artifact = gate.load_artifact()
    result = gate.evaluate(artifact, env={})
    assert result.ready is True, f"shipped artifact should be attested-ready: {result.reasons}"
    assert result.evidence_source == "artifact"

    checkout = artifact["evidence"]["checkout_disabled"]
    assert checkout["supplied"] is False, "Form A must stay unclaimed — no ASC observation was made"
    for field in ("source", "verified_by", "verified_at", "reference"):
        assert checkout[field] is None, f"checkout_disabled.{field} must remain null"

    policy = artifact["evidence"]["charged_before_upgrade_policy"]
    assert policy["supplied"] is True and policy["owner_approved"] is True
    assert isinstance(policy["bounded_window_days"], int)
    assert not isinstance(policy["bounded_window_days"], bool)
    assert policy["bounded_window_days"] > 0
    for field in ("approved_by", "approved_at", "policy_reference"):
        assert isinstance(policy[field], str) and policy[field].strip()


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


def _load_build91_verifier():
    """Import the build-91 verifier as a module so its gate dependency can be
    monkeypatched. Its sibling-import of build90_recovery_gate needs the Scripts
    dir on sys.path."""
    scripts = str(IOS_SCRIPTS)
    added = scripts not in sys.path
    if added:
        sys.path.insert(0, scripts)
    try:
        spec = importlib.util.spec_from_file_location(
            "verify_build91_entitlement_contract",
            IOS_SCRIPTS / "verify_build91_entitlement_contract.py",
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        if added:
            sys.path.remove(scripts)


def test_build91_verifier_blocks_the_release_path_when_the_gate_is_unresolved():
    """The gate is genuinely load-bearing on the release path.

    Previously this asserted the verifier exits 1 by default. Since the
    2026-07-25 owner attestation the shipped artifact is legitimately READY, so
    "by default" now means PASS. The invariant that actually matters — *remove
    the evidence and the whole verification path blocks* — is proven here by
    monkeypatching the gate's artifact loader, which leaves the tracked artifact
    untouched. The gate and the verifier are unchanged; neither was weakened.
    """
    verifier = _load_build91_verifier()
    gate = verifier.build90_recovery_gate
    original = gate.load_artifact
    try:
        gate.load_artifact = lambda *a, **k: _unresolved_artifact(_load_gate())
        with pytest.raises(AssertionError) as excinfo:
            verifier.main()
        assert "charged-before-upgrade" in str(excinfo.value)
    finally:
        gate.load_artifact = original

    # ...and with the real, owner-attested artifact the same path passes.
    assert verifier.main() == 0


def test_build91_verification_path_passes_with_the_shipped_attestation():
    """End-to-end subprocess proof at the committed tree: the verifier exits 0
    on the shipped attestation, and still exits 0 when complete evidence is
    additionally supplied out-of-band."""
    verifier = REPO_ROOT / "apps" / "ios" / "Scripts" / "verify_build91_entitlement_contract.py"
    env = dict(os.environ)
    env.pop("TONO_BUILD90_RECOVERY_EVIDENCE", None)
    shipped = subprocess.run(
        [sys.executable, str(verifier)], cwd=REPO_ROOT, capture_output=True, text=True, env=env
    )
    assert shipped.returncode == 0, shipped.stdout + shipped.stderr
    assert "build91-entitlement-contract: PASS" in shipped.stdout

    # Supplying complete evidence out-of-band also passes the verification path.
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
