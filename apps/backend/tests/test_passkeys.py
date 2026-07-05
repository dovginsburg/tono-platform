"""Server-side passkey (WebAuthn) tests: options generation, auth guards,
and error paths that don't require a real signed credential.

The actual registration + login ceremony (constructing a real key pair and
a real signed assertion) needs a real or virtual authenticator — hand-
rolling valid CBOR/COSE structures to fake one in a unit test would test
our test fixture more than our code. That happy path is verified instead
in apps/web via Playwright's CDP virtual authenticator (a simulated
platform authenticator — i.e. a simulated Face ID/Windows Hello) driving
the actual browser against this actual backend. See apps/web's passkey
test for that.
"""

from __future__ import annotations

import base64

import pytest


def _register(client) -> dict:
    r = client.post("/v1/register", json={})
    assert r.status_code == 200, r.text
    return r.json()


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def test_register_options_requires_bearer_token(client):
    r = client.post("/v1/auth/passkey/register/options")
    assert r.status_code == 401


def test_register_options_creates_bare_account_when_anonymous(client):
    device = _register(client)
    assert device["is_pro"] is False

    r = client.post("/v1/auth/passkey/register/options", headers=_auth(device["api_token"]))
    assert r.status_code == 200, r.text
    options = r.json()
    assert options["rp"]["id"]
    assert "challenge" in options
    assert options["user"]["id"]

    me = client.get("/v1/me", headers=_auth(device["api_token"])).json()
    assert me["account_id"] is not None


async def test_register_options_excludes_already_registered_credentials(client, store):
    """A second registration/options call for an account that already has a
    credential should list it in excludeCredentials, so the platform won't
    let you register the same authenticator twice."""
    from webauthn.helpers import bytes_to_base64url

    device = _register(client)
    r1 = client.post("/v1/auth/passkey/register/options", headers=_auth(device["api_token"]))
    assert r1.json()["excludeCredentials"] == []

    me = client.get("/v1/me", headers=_auth(device["api_token"])).json()
    # Must be real base64url-encoded bytes — the endpoint round-trips this
    # through base64url decode/re-encode when building excludeCredentials.
    credential_id = bytes_to_base64url(b"fake-credential-bytes-1")
    await store.add_webauthn_credential(
        credential_id=credential_id,
        account_id=me["account_id"],
        public_key=b"\x00" * 32,
        sign_count=0,
        transports=["internal"],
    )

    r2 = client.post("/v1/auth/passkey/register/options", headers=_auth(device["api_token"]))
    assert r2.json()["excludeCredentials"][0]["id"] == credential_id


def test_register_verify_without_prior_options_call_fails(client):
    device = _register(client)
    r = client.post(
        "/v1/auth/passkey/register/verify",
        json={"credential": {"id": "x", "rawId": "x", "response": {}, "type": "public-key"}},
        headers=_auth(device["api_token"]),
    )
    assert r.status_code == 400
    assert "options" in r.json()["error"]["message"].lower()


def test_login_options_is_public_no_auth_needed(client):
    r = client.post("/v1/auth/passkey/login/options")
    assert r.status_code == 200, r.text
    options = r.json()
    assert "challenge" in options
    # Discoverable-credential login: no allowCredentials list, the
    # authenticator itself prompts which passkey to use.
    assert options.get("allowCredentials") in (None, [])


def test_login_verify_rejects_malformed_credential(client):
    device = _register(client)
    r = client.post(
        "/v1/auth/passkey/login/verify",
        json={"credential": {"id": "x", "rawId": "x", "response": {}, "type": "public-key"}},
        headers=_auth(device["api_token"]),
    )
    assert r.status_code == 400


def test_login_verify_rejects_unknown_credential(client):
    device = _register(client)
    login_options = client.post("/v1/auth/passkey/login/options").json()
    challenge = login_options["challenge"]

    # Real base64url clientDataJSON containing the real challenge, but a
    # credential id that was never registered — should fail cleanly at the
    # "unknown passkey" lookup, not crash.
    import json

    client_data = json.dumps(
        {"type": "webauthn.get", "challenge": challenge, "origin": "http://localhost:3300"}
    ).encode()
    client_data_b64 = base64.urlsafe_b64encode(client_data).rstrip(b"=").decode()

    r = client.post(
        "/v1/auth/passkey/login/verify",
        json={
            "credential": {
                "id": "never-registered",
                "rawId": "never-registered",
                "type": "public-key",
                "response": {
                    "clientDataJSON": client_data_b64,
                    "authenticatorData": "AA",
                    "signature": "AA",
                },
            }
        },
        headers=_auth(device["api_token"]),
    )
    assert r.status_code == 401
    assert "unknown passkey" in r.json()["error"]["message"].lower()


def test_login_verify_requires_bearer_token(client):
    r = client.post("/v1/auth/passkey/login/verify", json={"credential": {}})
    assert r.status_code == 401


# ---------------------------------------------------------------------------
# Management: list / delete
# ---------------------------------------------------------------------------


def test_list_is_empty_for_anonymous_device(client):
    device = _register(client)
    r = client.get("/v1/auth/passkey", headers=_auth(device["api_token"]))
    assert r.status_code == 200, r.text
    assert r.json() == []


async def test_list_returns_registered_credentials(client, store):
    from webauthn.helpers import bytes_to_base64url

    device = _register(client)
    client.post("/v1/auth/passkey/register/options", headers=_auth(device["api_token"]))
    me = client.get("/v1/me", headers=_auth(device["api_token"])).json()

    credential_id = bytes_to_base64url(b"fake-credential-bytes-list")
    await store.add_webauthn_credential(
        credential_id=credential_id,
        account_id=me["account_id"],
        public_key=b"\x00" * 32,
        sign_count=0,
        transports=["internal"],
        nickname="my laptop",
    )

    r = client.get("/v1/auth/passkey", headers=_auth(device["api_token"]))
    assert r.status_code == 200, r.text
    items = r.json()
    assert len(items) == 1
    assert items[0]["credential_id"] == credential_id
    assert items[0]["nickname"] == "my laptop"


def test_list_requires_bearer_token(client):
    r = client.get("/v1/auth/passkey")
    assert r.status_code == 401


async def test_delete_removes_own_credential(client, store):
    from webauthn.helpers import bytes_to_base64url

    device = _register(client)
    client.post("/v1/auth/passkey/register/options", headers=_auth(device["api_token"]))
    me = client.get("/v1/me", headers=_auth(device["api_token"])).json()

    credential_id = bytes_to_base64url(b"fake-credential-bytes-delete")
    await store.add_webauthn_credential(
        credential_id=credential_id,
        account_id=me["account_id"],
        public_key=b"\x00" * 32,
        sign_count=0,
    )

    r = client.delete(f"/v1/auth/passkey/{credential_id}", headers=_auth(device["api_token"]))
    assert r.status_code == 204

    remaining = client.get("/v1/auth/passkey", headers=_auth(device["api_token"])).json()
    assert remaining == []


def test_delete_of_unknown_credential_is_404(client):
    device = _register(client)
    client.post("/v1/auth/passkey/register/options", headers=_auth(device["api_token"]))
    r = client.delete("/v1/auth/passkey/does-not-exist", headers=_auth(device["api_token"]))
    assert r.status_code == 404


async def test_delete_cannot_remove_another_accounts_credential(client, store):
    """Account isolation: device Y must not be able to delete a credential
    that belongs to account A just by knowing its credential_id."""
    from webauthn.helpers import bytes_to_base64url

    device_a = _register(client)
    client.post("/v1/auth/passkey/register/options", headers=_auth(device_a["api_token"]))
    me_a = client.get("/v1/me", headers=_auth(device_a["api_token"])).json()

    credential_id = bytes_to_base64url(b"fake-credential-bytes-isolated")
    await store.add_webauthn_credential(
        credential_id=credential_id,
        account_id=me_a["account_id"],
        public_key=b"\x00" * 32,
        sign_count=0,
    )

    device_y = _register(client)
    client.post("/v1/auth/passkey/register/options", headers=_auth(device_y["api_token"]))
    r = client.delete(f"/v1/auth/passkey/{credential_id}", headers=_auth(device_y["api_token"]))
    assert r.status_code == 404

    still_there = client.get("/v1/auth/passkey", headers=_auth(device_a["api_token"])).json()
    assert len(still_there) == 1
