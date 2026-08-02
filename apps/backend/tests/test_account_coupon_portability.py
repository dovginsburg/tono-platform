from __future__ import annotations

import datetime as dt
import sqlite3
from concurrent.futures import ThreadPoolExecutor

import pytest

from backend.store import Store


def _identified(store: Store, subject: str):
    registration = store.register_device()
    account_id = registration.user.account_id
    store._conn.execute(
        "UPDATE accounts SET supabase_sub = ? WHERE id = ?", (subject, account_id)
    )
    return registration, account_id


def test_account_redemption_extends_and_is_portable(tmp_path):
    store = Store(str(tmp_path / "tono.sqlite"))
    first, account_id = _identified(store, "person-1")
    store.create_coupon("FIRST", 10)
    store.create_coupon("SECOND", 5)

    first_expiry = store.redeem_coupon(account_id, "FIRST")
    second_expiry = store.redeem_coupon(account_id, "SECOND")
    assert dt.datetime.fromisoformat(second_expiry) == (
        dt.datetime.fromisoformat(first_expiry) + dt.timedelta(days=5)
    )

    other_device = store.register_device()
    store.link_device_to_account(other_device.user.device_id, account_id)
    assert store.get_by_device(other_device.user.device_id).is_pro
    assert store.get_by_device(first.user.device_id).account.coupon_pro_expires_at == second_expiry
    with pytest.raises(ValueError, match="already redeemed"):
        store.redeem_coupon(account_id, "FIRST")


def test_anonymous_fails_closed_and_other_account_does_not_inherit(tmp_path):
    store = Store(str(tmp_path / "tono.sqlite"))
    anonymous = store.register_device().user
    store.create_coupon("PRIVATE", 7)
    with pytest.raises(ValueError, match="verified account"):
        store.redeem_coupon(anonymous.account_id, "PRIVATE")

    _, first_id = _identified(store, "first")
    second, _ = _identified(store, "second")
    store.redeem_coupon(first_id, "PRIVATE")
    assert not store.get_by_device(second.user.device_id).is_pro


def test_concurrent_account_replay_consumes_once(tmp_path):
    path = str(tmp_path / "tono.sqlite")
    seed = Store(path)
    _, account_id = _identified(seed, "concurrent")
    seed.create_coupon("RACE", 7, max_uses=1)
    seed.close()

    def redeem():
        local = Store(path)
        try:
            return local.redeem_coupon(account_id, "RACE")
        except ValueError as exc:
            return str(exc)
        finally:
            local.close()

    with ThreadPoolExecutor(max_workers=2) as executor:
        outcomes = list(executor.map(lambda _: redeem(), range(2)))
    assert sum("T" in result for result in outcomes) == 1
    check = sqlite3.connect(path)
    assert check.execute("SELECT use_count FROM coupons WHERE code='RACE'").fetchone()[0] == 1
    assert check.execute(
        "SELECT COUNT(*) FROM account_coupon_redemptions WHERE account_id=? AND code='RACE'",
        (account_id,),
    ).fetchone()[0] == 1


def test_legacy_backfill_is_additive_idempotent_and_keeps_audit(tmp_path):
    path = str(tmp_path / "tono.sqlite")
    store = Store(path)
    registration = store.register_device()
    account_id = registration.user.account_id
    now = dt.datetime.now(dt.timezone.utc)
    expiry = (now + dt.timedelta(days=3)).isoformat(timespec="seconds")
    store.create_coupon("LEGACY", 3)
    store._conn.execute(
        "UPDATE users SET coupon_pro_expires_at=? WHERE device_id=?",
        (expiry, registration.user.device_id),
    )
    store._conn.execute(
        "INSERT INTO coupon_redemptions(device_id, code, redeemed_at) VALUES (?, 'LEGACY', ?)",
        (registration.user.device_id, now.isoformat(timespec="seconds")),
    )
    store.close()

    migrated = Store(path)
    migrated.close()
    rerun = Store(path)
    assert rerun.get_account(account_id).coupon_pro_expires_at == expiry
    assert rerun._conn.execute("SELECT COUNT(*) FROM coupon_redemptions").fetchone()[0] == 1
    assert rerun._conn.execute("SELECT COUNT(*) FROM account_coupon_redemptions").fetchone()[0] == 1


def test_pending_signup_does_not_consume_until_verification(tmp_path):
    store = Store(str(tmp_path / "tono.sqlite"))
    registration = store.register_device()
    account_id = registration.user.account_id
    store.create_coupon("WELCOME", 14)
    store.begin_email_registration(
        account_id=account_id,
        email="person@example.com",
        provider_subject="pending-subject",
        pending_coupon_code=" welcome ",
    )
    assert store._conn.execute(
        "SELECT use_count FROM coupons WHERE code='WELCOME'"
    ).fetchone()[0] == 0
    assert not store.get_account(account_id).is_identified

    store.mark_email_verified(account_id=account_id, email="person@example.com")
    assert store._conn.execute(
        "SELECT use_count FROM coupons WHERE code='WELCOME'"
    ).fetchone()[0] == 1
    assert store.get_account(account_id).is_pro


def test_expired_account_coupon_does_not_authorize(tmp_path):
    store = Store(str(tmp_path / "tono.sqlite"))
    registration, account_id = _identified(store, "expired")
    past = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=1)).isoformat(
        timespec="seconds"
    )
    store._conn.execute(
        "UPDATE accounts SET coupon_pro_expires_at=? WHERE id=?", (past, account_id)
    )
    assert not store.get_by_device(registration.user.device_id).is_pro
