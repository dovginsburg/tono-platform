"""Hostile / property probes for the final mass-release candidate.

Focused adversarial coverage across the boundaries a release must not fail on:
auth, the entitlement gate, cross-account isolation, webhook replay/forgery,
Unicode + malformed input, logging redaction, and URL/redirect limits.

These complement (not duplicate) test_entitlement_gate.py and
test_stripe_lifecycle.py: everything here attacks a boundary from the outside
rather than asserting an internal contract.
"""

from __future__ import annotations

import datetime as _dt
import json
import logging

import pytest


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _register(client) -> dict:
    r = client.post("/v1/register", json={"platform": "ios", "app_version": "0.2.0"})
    assert r.status_code == 200, r.text
    return r.json()


def _entitle(device_id: str) -> None:
    from backend.store import get_store

    expires = (_dt.datetime.now(_dt.timezone.utc) + _dt.timedelta(days=30)).isoformat(
        timespec="seconds"
    )
    get_store()._conn.execute(
        "UPDATE users SET coupon_pro_expires_at = ? WHERE device_id = ?",
        (expires, device_id),
    )


# --------------------------------------------------------------------------
# Auth boundary
# --------------------------------------------------------------------------


MALFORMED_AUTH = [
    "",
    "Bearer",
    "Bearer ",
    "Basic abc",
    "bearer",
    "Bearer " + "A" * 4096,
    "Bearer \x00nul",
    "Bearer ../../etc/passwd",
    "Bearer {}",
    "Bearer null",
    "Bearer undefined",
    "Bearer 0",
    # Non-ASCII cannot be a str header value (httpx enforces RFC 7230 ASCII, as
    # any real client must), so send the raw UTF-8 bytes a hostile client would
    # actually put on the wire.
    ("Bearer " + "\u202e" * 8).encode("utf-8"),           # RTL override
    "Bearer \U0001d518\U0001d52b\U0001d526\U0001d520\U0001d52c\U0001d521\U0001d522".encode("utf-8"),
    "Bearer ' OR '1'='1",
    "Bearer %00",
]


@pytest.mark.parametrize("header", MALFORMED_AUTH)
def test_malformed_bearer_never_authenticates(client, header):
    """No malformed Authorization value may reach a 2xx, and none may 500."""
    r = client.post("/api/analyze", headers={"Authorization": header}, json={"text": "hi"})
    assert r.status_code in (401, 403, 422), f"{header!r} -> {r.status_code}"


def test_another_devices_token_cannot_act_as_me(client):
    """Cross-account isolation on the token boundary."""
    a = _register(client)
    b = _register(client)
    _entitle(a["device_id"])

    # B (unentitled) presenting its own token fails closed...
    assert client.post("/api/analyze", headers=_auth(b["api_token"]), json={"text": "hi"}).status_code == 402
    # ...and B cannot borrow A's identity by claiming A's device_id.
    r = client.get("/v1/me", headers=_auth(b["api_token"]))
    assert r.status_code == 200
    assert r.json()["device_id"] == b["device_id"]
    assert r.json()["is_pro"] is False


def test_account_deletion_is_scoped_to_the_calling_principal(client):
    """DELETE /v1/account must only ever delete the caller's own account."""
    a = _register(client)
    b = _register(client)

    assert client.delete("/v1/account", headers=_auth(a["api_token"])).status_code == 200
    # A's token is revoked...
    assert client.get("/v1/me", headers=_auth(a["api_token"])).status_code == 401
    # ...and B is untouched.
    rb = client.get("/v1/me", headers=_auth(b["api_token"]))
    assert rb.status_code == 200
    assert rb.json()["account_id"]


# --------------------------------------------------------------------------
# Entitlement gate — the binding no-free-tier contract
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    "status,entitled",
    [
        ("active", True),
        ("trialing", True),
        ("past_due", True),      # deliberate auto-renew grace
        ("canceled", False),
        ("incomplete", False),
        ("incomplete_expired", False),
        ("unpaid", False),
        ("paused", False),
        ("", False),
        ("ACTIVE", False),        # case-sensitive: no sloppy match reopens access
        ("active ", False),       # whitespace must not pass either
    ],
)
def test_subscription_status_gate_is_exact(client, status, entitled):
    from backend.store import get_store

    reg = _register(client)
    get_store().update_subscription(
        device_id=reg["device_id"], customer_id=None,
        subscription_id="sub_x", status=status, renews_at=None,
    )
    r = client.post("/api/analyze", headers=_auth(reg["api_token"]), json={"text": "hello"})
    assert (r.status_code == 200) is entitled, f"status={status!r} -> {r.status_code}"
    if not entitled:
        assert r.status_code == 402
        assert r.json()["error"]["reason"] == "entitlement_required"


def test_expired_coupon_fails_closed_and_is_not_off_by_one(client):
    from backend.store import get_store

    reg = _register(client)
    past = (_dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(seconds=1)).isoformat(
        timespec="seconds"
    )
    get_store()._conn.execute(
        "UPDATE users SET coupon_pro_expires_at = ? WHERE device_id = ?", (past, reg["device_id"])
    )
    r = client.post("/api/analyze", headers=_auth(reg["api_token"]), json={"text": "hello"})
    assert r.status_code == 402


def test_malformed_coupon_timestamp_fails_closed(client):
    """A corrupt expiry must deny, never grant (fail closed on parse error)."""
    from backend.store import get_store

    reg = _register(client)
    for junk in ("not-a-date", "9999", "", "2026-13-45T99:99:99"):
        get_store()._conn.execute(
            "UPDATE users SET coupon_pro_expires_at = ? WHERE device_id = ?", (junk, reg["device_id"])
        )
        r = client.post("/api/analyze", headers=_auth(reg["api_token"]), json={"text": "hi"})
        assert r.status_code == 402, f"junk expiry {junk!r} granted access"


# --------------------------------------------------------------------------
# Unicode / malformed payloads
# --------------------------------------------------------------------------


HOSTILE_TEXT = [
    "\x00embedded nul",
    "😀" * 200,                 # emoji flood
    "‮RTL override attack",
    "á" * 500,                       # combining marks
    "𝕳𝖊𝖑𝖑𝖔 𝖜𝖔𝖗𝖑𝖉",
    "<script>alert(1)</script>",
    "'; DROP TABLE users; --",
    "{{7*7}}",
    "${jndi:ldap://x/a}",
    "\n\r\t" * 100,
    "\U0001F1FA\U0001F1F8" * 100,          # regional indicators
    "ẗ" * 1999,
]


@pytest.mark.parametrize("text", HOSTILE_TEXT)
def test_hostile_text_never_500s(client, text):
    reg = _register(client)
    _entitle(reg["device_id"])
    r = client.post("/api/analyze", headers=_auth(reg["api_token"]), json={"text": text})
    assert r.status_code < 500, f"{text[:40]!r} -> {r.status_code}: {r.text[:200]}"


def test_oversize_draft_is_rejected_not_truncated(client):
    reg = _register(client)
    _entitle(reg["device_id"])
    r = client.post(
        "/api/analyze", headers=_auth(reg["api_token"]), json={"text": "x" * 100_000}
    )
    assert r.status_code == 400
    assert "too long" in r.text


def test_analytics_endpoint_rejects_undeclared_fields(client):
    """extra='forbid' is the structural privacy guard — a client bug that tries
    to attach message text must 422, not be silently accepted."""
    reg = _register(client)
    r = client.post(
        "/v1/events",
        headers=_auth(reg["api_token"]),
        json={"event": "analysis_shown", "message_text": "my private draft"},
    )
    assert r.status_code == 422


# --------------------------------------------------------------------------
# Webhook: forgery, replay, ordering
# --------------------------------------------------------------------------


def test_webhook_rejects_unsigned_and_forged_payloads(client, monkeypatch):
    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_fake")
    monkeypatch.setenv("STRIPE_WEBHOOK_SECRET", "whsec_fake")
    forged = {
        "id": "evt_forged",
        "type": "customer.subscription.updated",
        "data": {"object": {"id": "sub_x", "status": "active", "customer": "cus_x"}},
    }
    for headers in ({}, {"stripe-signature": "t=1,v1=deadbeef"}, {"stripe-signature": ""}):
        r = client.post("/v1/stripe/webhook", json=forged, headers=headers)
        assert r.status_code == 400, f"forged webhook accepted with {headers}"


def test_webhook_replay_of_the_same_event_is_idempotent(client, monkeypatch):
    import backend.payments as payments_mod

    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_fake")
    monkeypatch.setenv("STRIPE_WEBHOOK_SECRET", "whsec_fake")

    reg = _register(client)
    from backend.store import get_store

    store = get_store()
    user = store.get_by_device(reg["device_id"])
    store.attach_account_stripe_customer(user.account_id, "cus_replay")

    event = {
        "id": "evt_replay_1",
        "type": "customer.subscription.updated",
        "data": {
            "object": {
                "id": "sub_replay", "status": "active", "customer": "cus_replay",
                "current_period_end": 4102444800,
                "items": {"data": [{"price": {"product": "prod_x"}}]},
            }
        },
    }
    monkeypatch.setattr(
        payments_mod.stripe.Webhook, "construct_event", lambda payload, sig, secret: json.loads(payload)
    )

    first = client.post("/v1/stripe/webhook", content=json.dumps(event),
                        headers={"stripe-signature": "ok", "content-type": "application/json"})
    assert first.status_code == 200 and first.json().get("duplicate") is not True

    second = client.post("/v1/stripe/webhook", content=json.dumps(event),
                         headers={"stripe-signature": "ok", "content-type": "application/json"})
    assert second.status_code == 200
    assert second.json().get("duplicate") is True, "replayed event was reprocessed"


def test_stale_canceled_event_cannot_be_resurrected_by_replay(client, monkeypatch):
    """Order independence: a late 'active' redelivery must not undo a cancel."""
    import backend.payments as payments_mod

    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_fake")
    monkeypatch.setenv("STRIPE_WEBHOOK_SECRET", "whsec_fake")
    monkeypatch.setattr(
        payments_mod.stripe.Webhook, "construct_event", lambda payload, sig, secret: json.loads(payload)
    )

    reg = _register(client)
    from backend.store import get_store

    store = get_store()
    user = store.get_by_device(reg["device_id"])
    store.attach_account_stripe_customer(user.account_id, "cus_order")

    def send(event_id, status, period_end):
        ev = {
            "id": event_id, "type": "customer.subscription.updated",
            "data": {"object": {
                "id": "sub_order", "status": status, "customer": "cus_order",
                "current_period_end": period_end,
                "items": {"data": [{"price": {"product": "prod_x"}}]},
            }},
        }
        return client.post("/v1/stripe/webhook", content=json.dumps(ev),
                           headers={"stripe-signature": "ok", "content-type": "application/json"})

    assert send("evt_a", "active", 4102444800).status_code == 200
    assert send("evt_b", "canceled", 4102444800).status_code == 200
    # A late redelivery of the OLDER active state, under a new event id.
    assert send("evt_c", "active", 4000000000).status_code == 200

    after = store.get_by_device(reg["device_id"])
    assert not after.is_pro, "a stale active event resurrected a canceled subscription"


# --------------------------------------------------------------------------
# Logging redaction
# --------------------------------------------------------------------------


def test_logs_never_contain_draft_text_or_bearer_tokens(client, caplog):
    reg = _register(client)
    _entitle(reg["device_id"])
    secret_draft = "ZZTOPSECRETDRAFTZZ my private message"

    with caplog.at_level(logging.DEBUG):
        r = client.post(
            "/api/analyze", headers=_auth(reg["api_token"]),
            json={"text": secret_draft, "thread_context": "QQPRIVATETHREADQQ"},
        )
    assert r.status_code == 200
    blob = "\n".join(rec.getMessage() for rec in caplog.records)
    assert "ZZTOPSECRETDRAFTZZ" not in blob, "draft text reached the logs"
    assert "QQPRIVATETHREADQQ" not in blob, "thread context reached the logs"
    assert reg["api_token"] not in blob, "bearer token reached the logs"


def test_phase_timing_logs_carry_no_identifiers(client, caplog):
    reg = _register(client)
    _entitle(reg["device_id"])
    with caplog.at_level(logging.INFO):
        client.post(
            "/api/analyze/variant", headers=_auth(reg["api_token"]),
            json={"text": "hello there", "axis": "warmer"},
        )
    phase_lines = [r.getMessage() for r in caplog.records if "tono.phase" in r.getMessage()]
    assert phase_lines, "expected phase-timing lines"
    for line in phase_lines:
        assert reg["device_id"] not in line
        assert reg["api_token"] not in line
        assert "hello there" not in line


# --------------------------------------------------------------------------
# URL / redirect boundary
# --------------------------------------------------------------------------


OPEN_REDIRECT_ATTEMPTS = [
    "https://evil.example.com/x",
    "http://tonoit.com/x",                     # downgrade
    "//evil.example.com/x",
    "https://tonoit.com.evil.example.com/x",
    "https://tonoit.com@evil.example.com/x",
    "javascript:alert(1)",
    "data:text/html,<script>1</script>",
    "https://eviltonoit.com/x",
    "",
    "not-a-url",
    "https://",
]


@pytest.mark.parametrize("candidate", OPEN_REDIRECT_ATTEMPTS)
def test_portal_return_url_never_leaves_the_allowlist(monkeypatch, candidate):
    monkeypatch.setenv("PUBLIC_BASE_URL", "https://tonoit.com")
    from backend import payments

    class _Req:
        base_url = "https://api.tonoit.com/"

    resolved = payments._portal_return_url(_Req(), candidate)
    assert resolved.startswith("https://tonoit.com/") or resolved.endswith(".tonoit.com/app/account"), (
        f"{candidate!r} escaped the allowlist -> {resolved}"
    )
    assert "evil.example.com" not in resolved
    assert not resolved.startswith("javascript:")
    assert not resolved.startswith("data:")


def test_public_base_url_ignores_attacker_host_header(monkeypatch):
    """Redirect bases must never derive from the Host header."""
    monkeypatch.delenv("PUBLIC_BASE_URL", raising=False)
    from backend import payments

    class _Req:
        base_url = "https://attacker.example.com/"
        headers = {"Host": "attacker.example.com"}

    assert payments._public_base_url(_Req()) == "https://tonoit.com"


def test_public_base_url_rejects_non_https_configuration(monkeypatch):
    monkeypatch.setenv("PUBLIC_BASE_URL", "http://tonoit.com")
    from backend import payments

    class _Req:
        base_url = "https://api.tonoit.com/"

    assert payments._public_base_url(_Req()) == "https://tonoit.com"
