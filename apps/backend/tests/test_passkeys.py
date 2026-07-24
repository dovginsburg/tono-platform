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


def test_register_options_excludes_already_registered_credentials(client):
    """A second registration/options call for an account that already has a
    credential should list it in excludeCredentials, so the platform won't
    let you register the same authenticator twice."""
    from webauthn.helpers import bytes_to_base64url

    from backend.store import get_store

    device = _register(client)
    r1 = client.post("/v1/auth/passkey/register/options", headers=_auth(device["api_token"]))
    assert r1.json()["excludeCredentials"] == []

    me = client.get("/v1/me", headers=_auth(device["api_token"])).json()
    # Must be real base64url-encoded bytes — the endpoint round-trips this
    # through base64url decode/re-encode when building excludeCredentials.
    credential_id = bytes_to_base64url(b"fake-credential-bytes-1")
    store = get_store()
    store.add_webauthn_credential(
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


def test_list_returns_registered_credentials(client):
    from webauthn.helpers import bytes_to_base64url

    from backend.store import get_store

    device = _register(client)
    client.post("/v1/auth/passkey/register/options", headers=_auth(device["api_token"]))
    me = client.get("/v1/me", headers=_auth(device["api_token"])).json()

    credential_id = bytes_to_base64url(b"fake-credential-bytes-list")
    store = get_store()
    store.add_webauthn_credential(
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


def test_delete_removes_own_credential(client):
    from webauthn.helpers import bytes_to_base64url

    from backend.store import get_store

    device = _register(client)
    client.post("/v1/auth/passkey/register/options", headers=_auth(device["api_token"]))
    me = client.get("/v1/me", headers=_auth(device["api_token"])).json()

    credential_id = bytes_to_base64url(b"fake-credential-bytes-delete")
    store = get_store()
    store.add_webauthn_credential(
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


def test_delete_cannot_remove_another_accounts_credential(client):
    """Account isolation: device Y must not be able to delete a credential
    that belongs to account A just by knowing its credential_id."""
    from webauthn.helpers import bytes_to_base64url

    from backend.store import get_store

    device_a = _register(client)
    client.post("/v1/auth/passkey/register/options", headers=_auth(device_a["api_token"]))
    me_a = client.get("/v1/me", headers=_auth(device_a["api_token"])).json()

    credential_id = bytes_to_base64url(b"fake-credential-bytes-isolated")
    store = get_store()
    store.add_webauthn_credential(
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


# ---------------------------------------------------------------------------
# Route-level replay / revocation / origin-binding logic.
#
# A full authenticator ceremony (real CBOR/COSE key + real signed assertion)
# is out of process (see module docstring). So — exactly as the suite already
# does nowhere-but-here — we monkeypatch backend.passkeys.verify_* to return
# objects carrying only the fields the *route* reads, so these tests exercise
# the route's own replay/revocation/origin logic and never the crypto lib.
# ---------------------------------------------------------------------------


class _FakeAuthVerification:
    """Mimics the object py_webauthn's verify_authentication_response returns;
    the route only reads `.new_sign_count`."""

    def __init__(self, new_sign_count: int):
        self.new_sign_count = new_sign_count


def _login_credential(challenge_b64: str, cred_id: str, origin: str = "http://localhost:3300") -> dict:
    """Build a login `credential` blob whose clientDataJSON really encodes
    `challenge_b64` (so the route's single-use challenge pop works) and whose
    rawId is `cred_id`."""
    import json

    client_data = json.dumps(
        {"type": "webauthn.get", "challenge": challenge_b64, "origin": origin}
    ).encode()
    client_data_b64 = base64.urlsafe_b64encode(client_data).rstrip(b"=").decode()
    return {
        "id": cred_id,
        "rawId": cred_id,
        "type": "public-key",
        "response": {
            "clientDataJSON": client_data_b64,
            "authenticatorData": "AA",
            "signature": "AA",
        },
    }


def _seed_credential(client, device, sign_count: int = 0):
    """Register a device, attach a bare account, and add a stored credential
    directly via the store. Returns (account_id, credential_id)."""
    from webauthn.helpers import bytes_to_base64url

    from backend.store import get_store

    client.post("/v1/auth/passkey/register/options", headers=_auth(device["api_token"]))
    me = client.get("/v1/me", headers=_auth(device["api_token"])).json()

    credential_id = bytes_to_base64url(b"seeded-credential-bytes")
    store = get_store()
    store.add_webauthn_credential(
        credential_id=credential_id,
        account_id=me["account_id"],
        public_key=b"\x01" * 32,
        sign_count=sign_count,
        transports=["internal"],
    )
    return me["account_id"], credential_id


def test_revoked_credential_is_rejected_before_signature_check(client, monkeypatch):
    """A credential that verifies fine, once deleted, is rejected at the
    store lookup ("unknown passkey") BEFORE any signature check — the route
    calls store.get_webauthn_credential first and 401s if it's None."""
    import backend.passkeys as passkeys

    device = _register(client)
    _, credential_id = _seed_credential(client, device, sign_count=0)

    # Verifier always "succeeds" — proves the gate below is the store lookup,
    # not the crypto.
    monkeypatch.setattr(
        passkeys,
        "verify_authentication_response",
        lambda **kw: _FakeAuthVerification(new_sign_count=1),
    )

    # 1) Login works while the credential exists.
    challenge = client.post("/v1/auth/passkey/login/options").json()["challenge"]
    r_ok = client.post(
        "/v1/auth/passkey/login/verify",
        json={"credential": _login_credential(challenge, credential_id)},
        headers=_auth(device["api_token"]),
    )
    assert r_ok.status_code == 200, r_ok.text

    # 2) Revoke it via the delete route.
    r_del = client.delete(f"/v1/auth/passkey/{credential_id}", headers=_auth(device["api_token"]))
    assert r_del.status_code == 204

    # 3) Same rawId now rejected as unknown, even though the verifier would
    #    still "succeed" — the store lookup short-circuits first.
    challenge2 = client.post("/v1/auth/passkey/login/options").json()["challenge"]
    r_revoked = client.post(
        "/v1/auth/passkey/login/verify",
        json={"credential": _login_credential(challenge2, credential_id)},
        headers=_auth(device["api_token"]),
    )
    assert r_revoked.status_code == 401
    assert "unknown passkey" in r_revoked.json()["error"]["message"].lower()


def test_sign_count_is_persisted_and_fed_back_to_replay_detection(client, monkeypatch):
    """The incremented sign count from a successful login is persisted, and
    the NOW-updated stored count is what the route feeds into the next
    verify as credential_current_sign_count (the replay/clone guard)."""
    import backend.passkeys as passkeys

    from backend.store import get_store

    device = _register(client)
    _, credential_id = _seed_credential(client, device, sign_count=5)

    # First login: verifier reports new_sign_count = stored + 1.
    monkeypatch.setattr(
        passkeys,
        "verify_authentication_response",
        lambda **kw: _FakeAuthVerification(new_sign_count=6),
    )
    challenge = client.post("/v1/auth/passkey/login/options").json()["challenge"]
    r1 = client.post(
        "/v1/auth/passkey/login/verify",
        json={"credential": _login_credential(challenge, credential_id)},
        headers=_auth(device["api_token"]),
    )
    assert r1.status_code == 200, r1.text

    # Persisted counter advanced 5 -> 6.
    assert get_store().get_webauthn_credential(credential_id).sign_count == 6

    # Second login: capture the kwargs the verifier receives and prove the
    # route passed the NOW-updated stored count (6) as the current sign count.
    captured: dict = {}

    def _capturing_verifier(**kw):
        captured.update(kw)
        return _FakeAuthVerification(new_sign_count=7)

    monkeypatch.setattr(passkeys, "verify_authentication_response", _capturing_verifier)
    challenge2 = client.post("/v1/auth/passkey/login/options").json()["challenge"]
    r2 = client.post(
        "/v1/auth/passkey/login/verify",
        json={"credential": _login_credential(challenge2, credential_id)},
        headers=_auth(device["api_token"]),
    )
    assert r2.status_code == 200, r2.text
    assert captured["credential_current_sign_count"] == 6
    assert get_store().get_webauthn_credential(credential_id).sign_count == 7


def test_login_verify_binds_origin_and_rp_id_from_config(client, monkeypatch):
    """RP-ID and expected origin fed to the verifier come from config, so a
    wrong-origin assertion would be rejected by the library. We assert
    _expected_origins() parses the comma list and that the login/verify route
    passes exactly those (+ _rp_id()) into verify_authentication_response."""
    import backend.passkeys as passkeys

    monkeypatch.setenv("WEBAUTHN_RP_ID", "tono.app")
    monkeypatch.setenv("WEBAUTHN_ORIGIN", "https://tono.app, https://www.tono.app")

    assert passkeys._expected_origins() == ["https://tono.app", "https://www.tono.app"]
    assert passkeys._rp_id() == "tono.app"

    device = _register(client)
    _, credential_id = _seed_credential(client, device, sign_count=0)

    captured: dict = {}

    def _capturing_verifier(**kw):
        captured.update(kw)
        return _FakeAuthVerification(new_sign_count=1)

    monkeypatch.setattr(passkeys, "verify_authentication_response", _capturing_verifier)
    challenge = client.post("/v1/auth/passkey/login/options").json()["challenge"]
    r = client.post(
        "/v1/auth/passkey/login/verify",
        json={"credential": _login_credential(challenge, credential_id, origin="https://tono.app")},
        headers=_auth(device["api_token"]),
    )
    assert r.status_code == 200, r.text
    assert captured["expected_origin"] == ["https://tono.app", "https://www.tono.app"]
    assert captured["expected_rp_id"] == "tono.app"


def test_register_verify_binds_origin_and_rp_id_from_config(client, monkeypatch):
    """Same origin/RP-ID binding proof for the registration ceremony."""
    import backend.passkeys as passkeys

    monkeypatch.setenv("WEBAUTHN_RP_ID", "tono.app")
    monkeypatch.setenv("WEBAUTHN_ORIGIN", "https://tono.app, https://www.tono.app")

    device = _register(client)
    # options both creates the account and stashes the registration challenge.
    client.post("/v1/auth/passkey/register/options", headers=_auth(device["api_token"]))

    class _FakeRegVerification:
        credential_id = b"registered-cred-bytes"
        credential_public_key = b"\x02" * 32
        sign_count = 0

    captured: dict = {}

    def _capturing_reg_verifier(**kw):
        captured.update(kw)
        return _FakeRegVerification()

    monkeypatch.setattr(passkeys, "verify_registration_response", _capturing_reg_verifier)

    r = client.post(
        "/v1/auth/passkey/register/verify",
        json={"credential": {"id": "x", "rawId": "x", "response": {}, "type": "public-key"}},
        headers=_auth(device["api_token"]),
    )
    assert r.status_code == 200, r.text
    assert captured["expected_origin"] == ["https://tono.app", "https://www.tono.app"]
    assert captured["expected_rp_id"] == "tono.app"


def test_login_challenge_is_single_use(client, monkeypatch):
    """After a successful login consumes a challenge, replaying the SAME
    clientDataJSON/challenge is rejected 400 'challenge expired or missing' —
    the challenge was popped."""
    import backend.passkeys as passkeys

    device = _register(client)
    _, credential_id = _seed_credential(client, device, sign_count=0)

    monkeypatch.setattr(
        passkeys,
        "verify_authentication_response",
        lambda **kw: _FakeAuthVerification(new_sign_count=1),
    )

    challenge = client.post("/v1/auth/passkey/login/options").json()["challenge"]
    credential_blob = _login_credential(challenge, credential_id)

    r1 = client.post(
        "/v1/auth/passkey/login/verify",
        json={"credential": credential_blob},
        headers=_auth(device["api_token"]),
    )
    assert r1.status_code == 200, r1.text

    # Replay the exact same blob (same challenge) — now popped.
    r2 = client.post(
        "/v1/auth/passkey/login/verify",
        json={"credential": credential_blob},
        headers=_auth(device["api_token"]),
    )
    assert r2.status_code == 400
    assert "challenge" in r2.json()["error"]["message"].lower()


def test_registration_challenge_is_single_use(client, monkeypatch):
    """A registration challenge is popped on verify, so a second verify
    without calling options again fails 400."""
    import backend.passkeys as passkeys

    device = _register(client)
    client.post("/v1/auth/passkey/register/options", headers=_auth(device["api_token"]))

    class _FakeRegVerification:
        credential_id = b"registered-cred-bytes-once"
        credential_public_key = b"\x03" * 32
        sign_count = 0

    monkeypatch.setattr(
        passkeys, "verify_registration_response", lambda **kw: _FakeRegVerification()
    )

    body = {"credential": {"id": "x", "rawId": "x", "response": {}, "type": "public-key"}}
    r1 = client.post(
        "/v1/auth/passkey/register/verify", json=body, headers=_auth(device["api_token"])
    )
    assert r1.status_code == 200, r1.text

    # Second verify without a fresh options call — challenge already popped.
    r2 = client.post(
        "/v1/auth/passkey/register/verify", json=body, headers=_auth(device["api_token"])
    )
    assert r2.status_code == 400
    assert "options" in r2.json()["error"]["message"].lower()
