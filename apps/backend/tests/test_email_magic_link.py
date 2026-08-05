"""Tono-branded magic-link sign-in for EXISTING users only.

Replaces the former browser-direct `supabase.auth.signInWithOtp({ shouldCreateUser:
true })`, which leaked the shared tenant's ParentScript sender and minted
unledgered provider accounts. The new `/v1/auth/email/magic-link`:

  * sends a Tono-owned, Tono-branded link (never a shared-tenant email);
  * serves EXISTING Tono users only — existence is decided against Tono's OWN
    ledger (`has_verified_email_account`), so an unknown address creates nothing
    and sends nothing;
  * is anti-enumerating — identical 202 body whether or not the address is known;
  * fails closed — a provider outage is a 503, never a false "we sent it".
"""

from __future__ import annotations

import pytest


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _register(client) -> dict:
    r = client.post("/v1/register", json={})
    assert r.status_code == 200, r.text
    return r.json()


class _FakeMagicClient:
    """Records send_magic_link calls; can be told to raise a provider outcome."""

    def __init__(self):
        self.sent: list[str] = []
        self.fail = None  # an EmailAuthOutcome to raise, or None

    async def send_magic_link(self, *, email: str) -> None:
        import backend.email_auth as email_auth
        if self.fail is not None:
            raise email_auth.EmailAuthError(self.fail)
        self.sent.append(email)


@pytest.fixture
def fake_magic(client):
    from backend.server import app
    import backend.email_auth as email_auth

    fake = _FakeMagicClient()
    app.dependency_overrides[email_auth.get_email_auth_client] = lambda: fake
    yield fake
    app.dependency_overrides.pop(email_auth.get_email_auth_client, None)


def _make_verified_account(client, email: str) -> str:
    """A fresh install that then proves an email — an existing Tono user."""
    from backend.store import get_store
    reg = _register(client)
    account_id = reg["account_id"]
    get_store().mark_email_verified(account_id=account_id, email=email)
    return account_id


# ---------------------------------------------------------------------------
# Store-level: existence is Tono's ledger, not the provider.
# ---------------------------------------------------------------------------


def test_has_verified_email_account_only_true_for_verified_ledger_rows(client):
    from backend.store import get_store
    store = get_store()
    assert store.has_verified_email_account("nobody@example.com") is False

    _register(client)  # anonymous account, no verified email
    assert store.has_verified_email_account("nobody@example.com") is False

    _make_verified_account(client, "owner@example.com")
    assert store.has_verified_email_account("owner@example.com") is True
    # case-insensitive via normalize_email
    assert store.has_verified_email_account("OWNER@example.com") is True


# ---------------------------------------------------------------------------
# Endpoint behavior.
# ---------------------------------------------------------------------------


def test_magic_link_sends_for_existing_verified_user(client, fake_magic):
    _make_verified_account(client, "owner@example.com")
    r = client.post("/v1/auth/email/magic-link", json={"email": "owner@example.com"})
    assert r.status_code == 202, r.text
    assert fake_magic.sent == ["owner@example.com"]


def test_magic_link_unknown_address_sends_and_creates_nothing(client, fake_magic):
    """shouldCreateUser=false semantics: an unknown address never reaches the
    provider, so nothing is created and nothing is sent."""
    r = client.post("/v1/auth/email/magic-link", json={"email": "stranger@example.com"})
    assert r.status_code == 202, r.text
    assert fake_magic.sent == []


def test_magic_link_is_anti_enumerating(client, fake_magic):
    _make_verified_account(client, "known@example.com")
    known = client.post("/v1/auth/email/magic-link", json={"email": "known@example.com"})
    unknown = client.post("/v1/auth/email/magic-link", json={"email": "unknown@example.com"})
    assert known.status_code == unknown.status_code == 202
    assert known.json() == unknown.json()


def test_magic_link_provider_outage_is_never_a_false_sent(client, fake_magic):
    import backend.email_auth as email_auth
    _make_verified_account(client, "owner@example.com")
    fake_magic.fail = email_auth.EmailAuthOutcome.PROVIDER_UNAVAILABLE
    r = client.post("/v1/auth/email/magic-link", json={"email": "owner@example.com"})
    assert r.status_code == 503, r.text
    assert "verification_pending" not in r.text


def test_magic_link_provider_disagreement_stays_anti_enum(client, fake_magic):
    """If the provider 4xxs a known address (INVALID_CREDENTIALS), the endpoint
    still answers the accepted shape rather than leaking the disagreement."""
    import backend.email_auth as email_auth
    _make_verified_account(client, "owner@example.com")
    fake_magic.fail = email_auth.EmailAuthOutcome.INVALID_CREDENTIALS
    r = client.post("/v1/auth/email/magic-link", json={"email": "owner@example.com"})
    assert r.status_code == 202, r.text


# ---------------------------------------------------------------------------
# The email body is Tono-branded (no shared-tenant sender/branding).
# ---------------------------------------------------------------------------


def test_magic_link_email_body_is_tono_branded():
    from backend.email_auth import _magic_link_email
    subject, html = _magic_link_email("https://bndbgpqbpzukrbhquztj.supabase.co/auth/v1/verify?token=x")
    assert "Tono" in subject
    assert "Tono" in html
    assert "parentscript" not in (subject + html).lower()
    assert 'href="https://bndbgpqbpzukrbhquztj.supabase.co/auth/v1/verify?token=x"' in html


def test_magic_link_branded_path_mints_magiclink_and_sends_via_tono(monkeypatch):
    """email_auth.send_magic_link uses admin generate_link(type=magiclink) + the
    Tono ESP send — never a GoTrue-side send (which would be shared-tenant)."""
    import asyncio
    import backend.email_auth as email_auth

    client = email_auth.SupabaseEmailAuthClient(
        base="https://proj.supabase.co", key="anon", service_key="svc",
        resend_key="re_x", from_addr="Tono <noreply@tonoit.com>",
    )
    assert client.tono_send_enabled is True
    calls = {}

    async def fake_generate(*, link_type, email, redirect_to, password=None):
        calls["link_type"] = link_type
        return ("https://proj.supabase.co/auth/v1/verify?token=tok&type=magiclink", "uid")

    async def fake_send(*, to, subject, html):
        calls["to"] = to
        calls["subject"] = subject

    monkeypatch.setattr(client, "_admin_generate_link", fake_generate)
    monkeypatch.setattr(client, "_send_tono_email", fake_send)

    asyncio.run(client.send_magic_link(email="owner@example.com"))
    assert calls["link_type"] == "magiclink"
    assert calls["to"] == "owner@example.com"
    assert "Tono" in calls["subject"]
