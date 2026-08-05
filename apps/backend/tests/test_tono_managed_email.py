"""Tono-owned transactional email path (product isolation on a SHARED Supabase
tenant).

Tono's production Supabase project is shared with a sibling product, so its
GoTrue SMTP sender/templates are project-global and cannot be rebranded without
changing the sibling's mail. When a service-role key + a Tono ESP key are
configured, ``SupabaseEmailAuthClient`` instead mints the action link with the
Admin ``generate_link`` API (which sends NO email) and delivers a Tono-branded
message from the Tono sender. These tests drive that path with a mocked httpx
transport (no network), and prove the default path is unchanged when it is off.
"""

from __future__ import annotations

import asyncio
import json

import httpx
import pytest

from backend import email_auth
from backend.email_auth import EmailAuthError, EmailAuthOutcome, SupabaseEmailAuthClient

BASE = "https://proj.supabase.co"

_REAL_ASYNC_CLIENT = httpx.AsyncClient  # captured before any monkeypatch


def _install_transport(monkeypatch, handler):
    """Route every httpx.AsyncClient created inside email_auth through a
    MockTransport so no real network is touched. Uses the REAL AsyncClient
    captured at import time so the factory does not recurse into itself."""
    def factory(*args, **kwargs):
        kwargs.pop("timeout", None)
        return _REAL_ASYNC_CLIENT(transport=httpx.MockTransport(handler), **kwargs)
    monkeypatch.setattr(email_auth.httpx, "AsyncClient", factory)


def _enabled_client() -> SupabaseEmailAuthClient:
    return SupabaseEmailAuthClient(
        BASE, "anon-key", service_key="svc-role-key", resend_key="re_key",
        from_addr="Tono <noreply@tonoit.com>",
    )


def _run(coro):
    return asyncio.run(coro)


def test_enabled_signup_mints_link_and_sends_tono_branded_mail(monkeypatch):
    calls = {"generate_link": None, "resend": None, "signup_hit": False}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/auth/v1/admin/generate_link"):
            calls["generate_link"] = json.loads(request.content)
            return httpx.Response(200, json={
                "properties": {"action_link":
                    f"{BASE}/auth/v1/verify?token=tok123&type=signup"
                    "&redirect_to=https://tonoit.com/app/auth/callback"},
                "user": {"id": "uid-abc"},
            })
        if request.url.host == "api.resend.com":
            calls["resend"] = json.loads(request.content)
            return httpx.Response(200, json={"id": "em_1"})
        if request.url.path.endswith("/auth/v1/signup"):
            calls["signup_hit"] = True
            return httpx.Response(200, json={"id": "should-not-be-used"})
        return httpx.Response(500)

    _install_transport(monkeypatch, handler)
    result = _run(_enabled_client().sign_up(email="new@example.com", password="Password123!"))

    assert calls["signup_hit"] is False  # GoTrue self-send path is NOT used
    assert result.verification_required is True
    assert result.session is None
    assert result.provider_user_id == "uid-abc"
    # generate_link: correct type, TOP-LEVEL redirect (not nested), password sent.
    gl = calls["generate_link"]
    assert gl["type"] == "signup"
    assert gl["email"] == "new@example.com"
    assert gl["redirect_to"] == email_auth._redirect_base()
    assert "options" not in gl  # top-level redirect_to, or GoTrue defaults to the shared site_url
    # Resend: Tono sender, Tono subject/branding, and the exact minted link.
    rs = calls["resend"]
    assert rs["from"] == "Tono <noreply@tonoit.com>"
    assert rs["to"] == ["new@example.com"]
    assert "Tono" in rs["subject"]
    assert "token=tok123" in rs["html"] and "Tono" in rs["html"]


def test_disabled_falls_back_to_gotrue_signup(monkeypatch):
    calls = {"signup": None, "generate_link_hit": False, "resend_hit": False}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/auth/v1/admin/generate_link"):
            calls["generate_link_hit"] = True
            return httpx.Response(200, json={"properties": {"action_link": "x"}})
        if request.url.host == "api.resend.com":
            calls["resend_hit"] = True
            return httpx.Response(200, json={"id": "em"})
        if request.url.path.endswith("/auth/v1/signup"):
            calls["signup"] = json.loads(request.content)
            return httpx.Response(200, json={"id": "uid-legacy",
                                             "confirmation_sent_at": "now"})
        return httpx.Response(500)

    _install_transport(monkeypatch, handler)
    client = SupabaseEmailAuthClient(BASE, "anon-key")  # no service/resend keys
    assert client.tono_send_enabled is False
    result = _run(client.sign_up(email="legacy@example.com", password="Password123!"))
    assert calls["generate_link_hit"] is False and calls["resend_hit"] is False
    assert calls["signup"]["email"] == "legacy@example.com"
    assert result.verification_required is True  # no session -> confirmation pending


def test_enabled_recovery_for_unknown_address_is_swallowed_no_send(monkeypatch):
    calls = {"resend_hit": False}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/auth/v1/admin/generate_link"):
            return httpx.Response(422, json={"error_code": "user_not_found"})
        if request.url.host == "api.resend.com":
            calls["resend_hit"] = True
            return httpx.Response(200, json={"id": "em"})
        return httpx.Response(500)

    _install_transport(monkeypatch, handler)
    # Must NOT raise and must NOT send — identical to a real send (anti-enum).
    _run(_enabled_client().request_password_reset(email="ghost@example.com"))
    assert calls["resend_hit"] is False


def test_enabled_recovery_sends_flagged_tono_recovery_mail(monkeypatch):
    calls = {"generate_link": None, "resend": None}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/auth/v1/admin/generate_link"):
            calls["generate_link"] = json.loads(request.content)
            return httpx.Response(200, json={"properties": {"action_link":
                f"{BASE}/auth/v1/verify?token=rec1&type=recovery"}})
        if request.url.host == "api.resend.com":
            calls["resend"] = json.loads(request.content)
            return httpx.Response(200, json={"id": "em"})
        return httpx.Response(500)

    _install_transport(monkeypatch, handler)
    _run(_enabled_client().request_password_reset(email="real@example.com"))
    assert calls["generate_link"]["type"] == "recovery"
    assert email_auth.RECOVERY_FLOW_MARKER in calls["generate_link"]["redirect_to"]
    assert "Reset your Tono password" == calls["resend"]["subject"]
    assert "token=rec1" in calls["resend"]["html"]


def test_enabled_signup_esp_failure_is_provider_unavailable_not_delivery(monkeypatch):
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/auth/v1/admin/generate_link"):
            return httpx.Response(200, json={"properties": {"action_link":
                f"{BASE}/auth/v1/verify?token=t"}})
        if request.url.host == "api.resend.com":
            return httpx.Response(502, text="bad gateway")  # ESP down
        return httpx.Response(500)

    _install_transport(monkeypatch, handler)
    with pytest.raises(EmailAuthError) as ei:
        _run(_enabled_client().sign_up(email="x@example.com", password="Password123!"))
    assert ei.value.outcome is EmailAuthOutcome.PROVIDER_UNAVAILABLE


def test_enabled_signup_already_registered_maps_to_invalid_credentials(monkeypatch):
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/auth/v1/admin/generate_link"):
            return httpx.Response(422, json={"error_code": "email_exists"})
        return httpx.Response(500)

    _install_transport(monkeypatch, handler)
    with pytest.raises(EmailAuthError) as ei:
        _run(_enabled_client().sign_up(email="taken@example.com", password="Password123!"))
    # The register handler folds INVALID_CREDENTIALS into the anti-enum accepted shape.
    assert ei.value.outcome is EmailAuthOutcome.INVALID_CREDENTIALS


@pytest.mark.parametrize("env,expected", [
    ({"SUPABASE_URL": BASE, "SUPABASE_SERVICE_ROLE_KEY": "s", "TONO_RESEND_API_KEY": "r"}, True),
    ({"SUPABASE_URL": BASE, "SUPABASE_SERVICE_ROLE_KEY": "s"}, False),  # no ESP key
    ({"SUPABASE_URL": BASE, "TONO_RESEND_API_KEY": "r"}, False),        # no service key
    ({"SUPABASE_SERVICE_ROLE_KEY": "s", "TONO_RESEND_API_KEY": "r"}, False),  # no base
])
def test_tono_managed_email_enabled_requires_all_three(monkeypatch, env, expected):
    for k in ("SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "TONO_RESEND_API_KEY",
              "SUPABASE_ANON_KEY"):
        monkeypatch.delenv(k, raising=False)
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    assert email_auth.tono_managed_email_enabled() is expected
