"""Regression + hostile tests for the ONE canonical entitlement authority.

Two jobs, both narrow:

1. **Stub regression.** The free-tier model stubs ``is_pro_user()`` (hardcoded
   ``False``), ``get_user_signup_date()`` (hardcoded ``None``) and their sole
   consumer ``get_model_for_user()`` were retired in 91a665e. They were never a
   real entitlement authority — ``get_model_for_user`` was only ever called with
   the literal ``"anonymous"``, so the "Pro" branch was structurally dead and the
   TODOs never gated anything. These tests pin them GONE, so a future edit cannot
   reintroduce a second, always-denying, non-authoritative notion of "pro" beside
   the real gate.

2. **Canonical authority, hostile.** ``store._plan_grants_pro`` is the single
   source of truth every rewrite gate resolves through (via ``User.is_pro`` /
   ``Account.is_pro`` -> ``server._require_rewrite_entitlement``). These tests
   exercise it directly across the axes the route-level suite cannot reach
   cheaply: absent account data, inactive/expired/unknown subscription status,
   malformed authority data, and the active-entitlement controls.

   The malformed axis has two distinct failure classes, and only one was covered
   before: an UNPARSEABLE expiry raises ``ValueError``, but a *parseable but
   timezone-naive* expiry raises ``TypeError`` when compared against the aware
   ``now``. Naive values are reachable from non-canonical writers (dict-sourced
   rows via ``_row_to_user``/``_row_to_account``, account-link copying,
   migrations, manual grants). Both must DENY cleanly — never grant, and never
   escape the gate as an unhandled 500 in place of the contract's honest 402.

Complements ``test_entitlement_gate.py`` (route-level fail-closed matrix); it is
deliberately not duplicated here.
"""

from __future__ import annotations

import datetime as _dt
import inspect
import pathlib
import re

import pytest

# The retired free-tier model stubs. If any of these comes back, the repo has a
# second entitlement-shaped code path competing with the canonical gate.
RETIRED_STUBS = ("is_pro_user", "get_user_signup_date", "get_model_for_user")


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _register(client) -> dict:
    r = client.post("/v1/register", json={"platform": "ios", "app_version": "0.2.0"})
    assert r.status_code == 200, r.text
    return r.json()


def _backend_source_files() -> list[pathlib.Path]:
    """Every shipping backend .py file — the tests dir is excluded (this module
    names the retired stubs as string literals by design)."""
    import backend

    root = pathlib.Path(backend.__file__).parent
    return [p for p in root.rglob("*.py") if "tests" not in p.parts]


# ---------------------------------------------------------------------------
# 1. Stub regression — proving no production dependency
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("name", RETIRED_STUBS)
def test_retired_free_tier_stub_is_not_importable(name):
    """No shipping module re-exports the retired stub."""
    import backend.analyze as analyze
    import backend.server as server
    import backend.store as store

    for mod in (analyze, server, store):
        assert not hasattr(mod, name), f"{mod.__name__}.{name} was reintroduced"


@pytest.mark.parametrize("name", RETIRED_STUBS)
def test_retired_free_tier_stub_absent_from_all_backend_source(name):
    """Not merely unexported — textually absent from every shipping source file,
    so it cannot be revived as a private helper or called through a re-export."""
    pattern = re.compile(rf"\b{re.escape(name)}\b")
    offenders = [
        str(p) for p in _backend_source_files() if pattern.search(p.read_text(encoding="utf-8"))
    ]
    assert not offenders, f"retired stub {name!r} reappeared in: {offenders}"


def test_analyze_model_choice_is_not_user_tiered():
    """The legacy Coach path picks a fixed server-chosen model. It must not take
    a user/account principal — a per-user signature is how the retired
    ``get_model_for_user(user_id)`` tiering crept in originally."""
    from backend.analyze import _default_analyze_model

    params = inspect.signature(_default_analyze_model).parameters
    assert not params, f"_default_analyze_model grew a per-user parameter: {list(params)}"
    assert isinstance(_default_analyze_model(), str)


# ---------------------------------------------------------------------------
# 2. Canonical authority — hostile matrix on _plan_grants_pro
# ---------------------------------------------------------------------------


def _future_aware(days: int = 30) -> str:
    return (_dt.datetime.now(_dt.timezone.utc) + _dt.timedelta(days=days)).isoformat()


def _past_aware(days: int = 1) -> str:
    return (_dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(days=days)).isoformat()


# (plan, subscription_status, coupon_pro_expires_at)
DENY_CASES = [
    pytest.param("free", None, None, id="missing_account_data_all_absent"),
    pytest.param("", "", "", id="empty_strings"),
    pytest.param("free", "active", None, id="active_status_but_not_pro_plan"),
    pytest.param("pro", None, None, id="pro_plan_but_no_status"),
    pytest.param("pro", "canceled", None, id="canceled"),
    pytest.param("pro", "expired", None, id="expired"),
    pytest.param("pro", "incomplete_expired", None, id="incomplete_expired"),
    pytest.param("pro", "unpaid", None, id="unpaid"),
    pytest.param("pro", "paused", None, id="paused"),
    pytest.param("pro", "ACTIVE", None, id="status_case_mismatch_not_coerced"),
    pytest.param("PRO", "active", None, id="plan_case_mismatch_not_coerced"),
    pytest.param("free", None, _past_aware(), id="expired_coupon"),
]

# Malformed authority data. Two failure classes; both must deny, not raise.
MALFORMED_COUPONS = [
    pytest.param("not-a-date", id="unparseable_garbage"),
    pytest.param("9999", id="bare_number"),
    pytest.param("2026-13-45T99:99:99", id="out_of_range_fields"),
    pytest.param("null", id="literal_null_string"),
    pytest.param("   ", id="whitespace"),
    # Parseable but timezone-NAIVE -> TypeError on aware/naive comparison.
    pytest.param("2030-01-01T00:00:00", id="naive_future_timestamp"),
    pytest.param("2020-01-01T00:00:00", id="naive_past_timestamp"),
    pytest.param("2030-01-01", id="naive_date_only"),
]

GRANT_CASES = [
    pytest.param("pro", "active", None, id="active_subscription"),
    pytest.param("pro", "trialing", None, id="active_trial"),
    pytest.param("pro", "past_due", None, id="past_due_grace_window"),
    pytest.param("free", None, _future_aware(3650), id="durable_founder_coupon"),
]


@pytest.mark.parametrize("plan,status,coupon", DENY_CASES)
def test_canonical_authority_denies(plan, status, coupon):
    from backend.store import _plan_grants_pro

    assert _plan_grants_pro(plan, status, coupon) is False


@pytest.mark.parametrize("coupon", MALFORMED_COUPONS)
def test_canonical_authority_denies_malformed_data_without_raising(coupon):
    """Malformed authority data must fail closed *cleanly*. A raised exception
    here escapes ``_require_rewrite_entitlement`` as a 500 instead of the
    contract's honest 402, so returning False is part of the contract."""
    from backend.store import _plan_grants_pro

    assert _plan_grants_pro("free", None, coupon) is False


@pytest.mark.parametrize("coupon", MALFORMED_COUPONS)
def test_malformed_coupon_never_rescues_a_dead_subscription(coupon):
    """The coupon branch is the only fallback after a dead plan/status. Malformed
    data must not become an accidental grant path."""
    from backend.store import _plan_grants_pro

    assert _plan_grants_pro("pro", "canceled", coupon) is False


@pytest.mark.parametrize("plan,status,coupon", GRANT_CASES)
def test_canonical_authority_grants_active_entitlement(plan, status, coupon):
    """The positive controls — hardening must not have narrowed real access."""
    from backend.store import _plan_grants_pro

    assert _plan_grants_pro(plan, status, coupon) is True


def test_user_and_account_resolve_through_the_same_authority():
    """No second, disagreeing entitlement opinion: both principals delegate to
    ``_plan_grants_pro``."""
    from backend.store import Account, User

    for cls in (User, Account):
        src = inspect.getsource(cls.is_pro.fget)
        assert "_plan_grants_pro" in src, f"{cls.__name__}.is_pro bypasses the canonical authority"


# ---------------------------------------------------------------------------
# 3. Route level — malformed authority data yields the honest 402, not a 500
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("coupon", ["2030-01-01T00:00:00", "2030-01-01", "not-a-date"])
def test_malformed_coupon_row_fails_closed_with_honest_402(client, coupon):
    """A naive/garbage expiry on the users row must deny with the machine-readable
    402 the clients switch on — never a 500, and never access."""
    from backend.store import get_store

    reg = _register(client)
    get_store()._conn.execute(
        "UPDATE users SET coupon_pro_expires_at = ? WHERE device_id = ?",
        (coupon, reg["device_id"]),
    )

    r = client.post("/api/analyze", headers=_auth(reg["api_token"]), json={"text": "hi"})

    assert r.status_code == 402, f"expiry {coupon!r} -> {r.status_code} (expected honest 402)"
    assert r.json()["error"]["reason"] == "entitlement_required"
