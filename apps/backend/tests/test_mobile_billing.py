"""Build-91 mobile (Apple) entitlement contract — the 20 hostile GO tests.

Every test runs against a fresh SQLite DB (conftest `_isolate_db`) through the
real FastAPI app and the real store; none of them merely greps source.

Apple's signing chain is stood up locally in the exact shape the supported App
Store Server Library requires: a self-generated EC root → WWDR-marked CA
intermediate → receipt-signing leaf (both marker OIDs + key-usage + basic
constraints so the library's OpenSSL X509_STRICT path accepts the chain). The
leaf signs each JWS transaction/notification, the leaf+intermediate+root ride in
the JWS `x5c` header, and the production `SignedDataVerifier` (wrapped by
`AppleDataVerifier`) is pointed at the test root via `app.dependency_overrides`
— the same indirection social_auth uses so the suite needs no Apple network path
or real signing key. The verifier under test is Apple's own library; only its
trust anchor is swapped.
"""

from __future__ import annotations

import base64
import datetime as dt
import json
import os
import sqlite3
import uuid
from concurrent.futures import ThreadPoolExecutor

import jwt
import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

BUNDLE_ID = "com.tonoit.app"
PRODUCT_ID = "com.tonoit.pro.monthly"
ENVIRONMENT = "Sandbox"
DAY_MS = 86_400_000


# ---------------------------------------------------------------------------
# Test PKI + JWS signer
# ---------------------------------------------------------------------------


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


# Apple's certificate marker OIDs the App Store Server Library requires:
# the receipt-signing leaf and the WWDR intermediate.
LEAF_MARKER_OID = x509.ObjectIdentifier("1.2.840.113635.100.6.11.1")
WWDR_MARKER_OID = x509.ObjectIdentifier("1.2.840.113635.100.6.2.1")


def _mk_cert(subject_cn, issuer_cert, issuer_key, *, ca: bool, marker_oid=None):
    """Build an EC cert with the extensions Apple's library (OpenSSL X509_STRICT)
    expects: BasicConstraints, KeyUsage, SKI, and an AKI + Apple marker OID where
    relevant. A CA cert gets keyCertSign; a leaf gets digitalSignature."""
    key = ec.generate_private_key(ec.SECP256R1())
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, subject_cn)])
    issuer_name = issuer_cert.subject if issuer_cert else subject
    builder = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer_name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        # Wide validity window: the library checks the chain against the
        # transaction's signedDate (online checks off), and build-90 tokenless
        # claims can be a year+ old, so the signing cert must have been valid then.
        .not_valid_before(_now() - dt.timedelta(days=3650))
        .not_valid_after(_now() + dt.timedelta(days=3650))
        .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
        .add_extension(
            x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False
        )
        .add_extension(
            x509.KeyUsage(
                digital_signature=not ca,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=ca,
                crl_sign=ca,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
    )
    if marker_oid is not None:
        builder = builder.add_extension(
            x509.UnrecognizedExtension(marker_oid, b"\x05\x00"), critical=False
        )
    if issuer_cert is not None:
        builder = builder.add_extension(
            x509.AuthorityKeyIdentifier.from_issuer_public_key(issuer_key.public_key()),
            critical=False,
        )
    cert = builder.sign(issuer_key or key, hashes.SHA256())
    return key, cert


def _der(cert) -> bytes:
    from cryptography.hazmat.primitives.serialization import Encoding

    return cert.public_bytes(Encoding.DER)


def _make_sandbox_verifier(root_cert):
    """The production Apple library verifier, pointed at a test root."""
    from appstoreserverlibrary.models.Environment import Environment
    from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier

    from backend.app_store import AppleDataVerifier

    return AppleDataVerifier(
        {"Sandbox": SignedDataVerifier([_der(root_cert)], False, Environment.SANDBOX, BUNDLE_ID)}
    )


class AppleFixture:
    """A local stand-in for Apple's signing chain + the production library
    verifier pointed at it."""

    def __init__(self):
        self.root_key, self.root_cert = _mk_cert("Tono Test Apple Root CA", None, None, ca=True)
        self.int_key, self.int_cert = _mk_cert(
            "Tono Test Apple WWDR Intermediate", self.root_cert, self.root_key,
            ca=True, marker_oid=WWDR_MARKER_OID,
        )
        self.leaf_key, self.leaf_cert = _mk_cert(
            "Tono Test Apple Leaf", self.int_cert, self.int_key,
            ca=False, marker_oid=LEAF_MARKER_OID,
        )
        self.verifier = _make_sandbox_verifier(self.root_cert)

    def _x5c(self):
        from cryptography.hazmat.primitives.serialization import Encoding

        return [
            base64.b64encode(c.public_bytes(Encoding.DER)).decode("ascii")
            for c in (self.leaf_cert, self.int_cert, self.root_cert)
        ]

    def sign(self, payload: dict, *, signing_key=None) -> str:
        return jwt.encode(
            payload,
            signing_key or self.leaf_key,
            algorithm="ES256",
            headers={"x5c": self._x5c()},
        )

    def transaction(self, **overrides) -> dict:
        now_ms = int(_now().timestamp() * 1000)
        payload = dict(
            bundleId=BUNDLE_ID,
            productId=PRODUCT_ID,
            environment=ENVIRONMENT,
            transactionId=uuid.uuid4().hex,
            originalTransactionId=uuid.uuid4().hex,
            inAppOwnershipType="PURCHASED",
            signedDate=now_ms,
            purchaseDate=now_ms,
            expiresDate=now_ms + 30 * DAY_MS,
            type="Auto-Renewable Subscription",
        )
        payload.update(overrides)
        # Allow explicit None to drop a field (e.g. tokenless / no expiry).
        return {k: v for k, v in payload.items() if v is not None}

    def sign_transaction(self, *, signing_key=None, **overrides) -> str:
        return self.sign(self.transaction(**overrides), signing_key=signing_key)

    def sign_notification(
        self, notification_type, *, subtype=None, tx=None, **tx_overrides
    ) -> str:
        tx = tx if tx is not None else self.transaction(**tx_overrides)
        payload = {
            "notificationType": notification_type,
            "notificationUUID": uuid.uuid4().hex,
            "data": {
                "bundleId": BUNDLE_ID,
                "environment": ENVIRONMENT,
                "signedTransactionInfo": self.sign(tx),
            },
        }
        if subtype:
            payload["subtype"] = subtype
        return self.sign(payload)


@pytest.fixture
def apple(client):
    """Install the test-trusted verifier; `client` first so the app module is
    imported and shared."""
    from backend import app_store
    from backend.server import app

    fx = AppleFixture()
    app.dependency_overrides[app_store.get_appstore_verifier] = lambda: fx.verifier

    def _disable():
        app.dependency_overrides.pop(app_store.get_appstore_verifier, None)

    fx.disable = _disable
    yield fx
    _disable()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _register(client) -> dict:
    r = client.post("/v1/register", json={"platform": "ios"})
    assert r.status_code == 200, r.text
    return r.json()


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _me(client, token: str) -> dict:
    r = client.get("/v1/me", headers=_auth(token))
    assert r.status_code == 200, r.text
    return r.json()


def _sync(client, token: str, jws: str):
    return client.post(
        "/v1/app-store/subscription",
        json={"signed_transaction_info": jws},
        headers=_auth(token),
    )


def _notify(client, jws: str):
    return client.post("/v1/app-store/notifications", json={"signedPayload": jws})


def _db_scalar(sql: str, params=()) -> int:
    con = sqlite3.connect(os.environ["TONO_DB_PATH"])
    try:
        return con.execute(sql, params).fetchone()[0]
    finally:
        con.close()


def _override_apple_signin(app, sub: str, email="person@example.com"):
    import backend.social_auth as social_auth

    async def fake(_token: str):
        return social_auth.IdentityClaims(sub=sub, email=email)

    app.dependency_overrides[social_auth.get_apple_verifier] = lambda: fake


# ===========================================================================
# 1. Anonymous registration -> one account+device; proof retry -> same account
# ===========================================================================


def test_01_registration_creates_one_account_and_device_atomically(client):
    reg = _register(client)
    assert reg["account_id"] and uuid.UUID(reg["account_id"])
    assert _db_scalar("SELECT COUNT(*) FROM users") == 1
    assert _db_scalar("SELECT COUNT(*) FROM accounts") == 1
    assert _db_scalar("SELECT COUNT(*) FROM users WHERE account_id IS NULL") == 0

    again = client.post(
        "/v1/register",
        json={
            "platform": "ios",
            "device_id": reg["device_id"],
            "device_credential": reg["device_credential"],
        },
    )
    assert again.status_code == 200, again.text
    assert again.json()["account_id"] == reg["account_id"]
    # No second account or device minted on a proven retry.
    assert _db_scalar("SELECT COUNT(*) FROM accounts") == 1
    assert _db_scalar("SELECT COUNT(*) FROM users") == 1


# ===========================================================================
# 2. Concurrent first registration for one device -> one device+account
# ===========================================================================


def test_02_concurrent_first_registration_no_orphan_accounts(client):
    device_id = str(uuid.uuid4())

    def _do(_):
        return client.post("/v1/register", json={"platform": "ios", "device_id": device_id})

    with ThreadPoolExecutor(max_workers=8) as ex:
        responses = list(ex.map(_do, range(8)))

    ok = [r for r in responses if r.status_code == 200]
    assert ok, [r.status_code for r in responses]
    # Exactly one device row and exactly one account — no orphans from a
    # rolled-back account+device insert.
    assert _db_scalar("SELECT COUNT(*) FROM users WHERE device_id = ?", (device_id,)) == 1
    assert _db_scalar("SELECT COUNT(*) FROM accounts") == 1
    account_ids = {r.json()["account_id"] for r in ok}
    assert len(account_ids) == 1


# ===========================================================================
# 3. Migration backfills every null exactly once; rerun idempotent
# ===========================================================================


def test_03_migration_backfills_nulls_once_and_is_idempotent(client):
    from backend.store import get_store

    store = get_store()
    now = "2026-01-01T00:00:00+00:00"
    con = sqlite3.connect(os.environ["TONO_DB_PATH"])
    try:
        # Two legacy anonymous devices (null account) + one already-accounted,
        # Pro device that migration must not disturb.
        con.execute(
            "INSERT INTO users (device_id, api_token, plan, created_at, updated_at) VALUES ('legacy-a','tok-a','free',?,?)",
            (now, now),
        )
        con.execute(
            "INSERT INTO users (device_id, api_token, plan, subscription_status, created_at, updated_at) "
            "VALUES ('legacy-b','tok-b','pro','active',?,?)",
            (now, now),
        )
        con.execute("INSERT INTO accounts (id, plan, created_at, updated_at) VALUES ('acc-existing','pro',?,?)", (now, now))
        con.execute(
            "INSERT INTO users (device_id, api_token, plan, account_id, created_at, updated_at) "
            "VALUES ('has-acc','tok-c','free','acc-existing',?,?)",
            (now, now),
        )
        con.commit()
    finally:
        con.close()

    result = store.backfill_missing_accounts()
    assert result == {"backfilled": 2, "remaining_null": 0}
    assert _db_scalar("SELECT COUNT(*) FROM users WHERE account_id IS NULL") == 0
    # Each backfilled device got a distinct new account; the pre-existing
    # account is untouched, and legacy-b's Pro is preserved on its new account.
    assert _db_scalar("SELECT account_id FROM users WHERE device_id='has-acc'") == "acc-existing"
    assert _db_scalar("SELECT plan FROM accounts WHERE id='acc-existing'") == "pro"
    assert _db_scalar("SELECT a.subscription_status FROM accounts a JOIN users u ON u.account_id=a.id WHERE u.device_id='legacy-b'") == "active"

    # Rerun is a no-op.
    assert store.backfill_missing_accounts() == {"backfilled": 0, "remaining_null": 0}
    assert _db_scalar("SELECT COUNT(*) FROM accounts") == 3


# ===========================================================================
# 4. Anonymous -> new credential preserves UUID, history, and grants
# ===========================================================================


def test_04_signin_upgrades_anonymous_account_in_place(client, apple):
    from backend.server import app

    reg = _register(client)
    account_id = reg["account_id"]

    # Grant an Apple entitlement to the anonymous account.
    jws = apple.sign_transaction(appAccountToken=account_id)
    assert _sync(client, reg["api_token"], jws).status_code == 200
    assert _me(client, reg["api_token"])["is_pro"] is True

    # Sign in with a brand-new Apple identity: the SAME account is upgraded in
    # place (its UUID is unchanged) and the entitlement grant survives.
    _override_apple_signin(app, sub="apple-upgrade-1")
    r = client.post("/v1/auth/apple", json={"identity_token": "t"}, headers=_auth(reg["api_token"]))
    assert r.status_code == 200, r.text
    assert r.json()["account_id"] == account_id  # UUID preserved

    me = _me(client, reg["api_token"])
    assert me["account_id"] == account_id
    assert me["is_pro"] is True
    grants = get_store_grants(account_id)
    assert len(grants) == 1 and grants[0]["state"] == "active"


def get_store_grants(account_id: str):
    from backend.store import get_store

    return get_store().list_entitlement_grants(account_id)


# ===========================================================================
# 5. Login to a credential owned by another account: switch, never merge
# ===========================================================================


def test_05_plain_signin_switches_without_merging_private_data(client, apple):
    from backend.server import app

    # Account A owned by apple-owner-5, with its own entitlement grant.
    dev_a = _register(client)
    _override_apple_signin(app, sub="apple-owner-5")
    acc_a = client.post(
        "/v1/auth/apple", json={"identity_token": "t"}, headers=_auth(dev_a["api_token"])
    ).json()["account_id"]
    assert _sync(client, dev_a["api_token"], apple.sign_transaction(appAccountToken=acc_a)).status_code == 200

    # Device B is signed into its own identified account (google-owner-5).
    dev_b = _register(client)
    import backend.social_auth as social_auth

    async def fake_g(_t):
        return social_auth.IdentityClaims(sub="google-owner-5", email="b@example.com")

    app.dependency_overrides[social_auth.get_google_verifier] = lambda: fake_g
    acc_b = client.post(
        "/v1/auth/google", json={"id_token": "t"}, headers=_auth(dev_b["api_token"])
    ).json()["account_id"]
    assert acc_b != acc_a

    # Explicit LINK of A's identity onto B is a conflict — never a silent merge.
    conflict = client.post(
        "/v1/auth/apple", json={"identity_token": "t", "link": True}, headers=_auth(dev_b["api_token"])
    )
    assert conflict.status_code == 409
    assert _me(client, dev_b["api_token"])["account_id"] == acc_b  # B unharmed

    # Plain sign-in switches device B to account A (ordinary login), and A's
    # private grants are A's alone — B contributed none to A.
    switch = client.post("/v1/auth/apple", json={"identity_token": "t"}, headers=_auth(dev_b["api_token"]))
    assert switch.status_code == 200
    assert switch.json()["account_id"] == acc_a
    assert len(get_store_grants(acc_a)) == 1  # not merged with B; still exactly one
    assert get_store_grants(acc_b) == []


# ===========================================================================
# 6. Purchase binds the canonical account UUID, never the device UUID
# ===========================================================================


def test_06_purchase_binds_account_uuid_never_device_uuid(client, apple):
    reg = _register(client)
    account_id, device_id = reg["account_id"], reg["device_id"]
    assert account_id != device_id

    # Bound to the canonical account UUID -> direct grant, readback equals it.
    ok = _sync(client, reg["api_token"], apple.sign_transaction(appAccountToken=account_id))
    assert ok.status_code == 200, ok.text
    assert ok.json()["is_pro"] is True
    assert ok.json()["account_id"] == account_id

    # A transaction bound to the DEVICE UUID (not the account) is a foreign
    # token -> conflict. Purchase never silently accepts the device id.
    reg2 = _register(client)
    bad = _sync(client, reg2["api_token"], apple.sign_transaction(appAccountToken=reg2["device_id"]))
    assert bad.status_code == 409
    assert _me(client, reg2["api_token"])["is_pro"] is False


# ===========================================================================
# 7. JWS happy path + every rejection mode + stale-after-refund
# ===========================================================================


def test_07_jws_validation_matrix(client, apple):
    reg = _register(client)
    tok, acc = reg["api_token"], reg["account_id"]

    # Happy path.
    assert _sync(client, tok, apple.sign_transaction(appAccountToken=acc)).status_code == 200

    # Forged signature: real leaf in x5c, but signed with a different key.
    forged = apple.sign_transaction(appAccountToken=acc, signing_key=ec.generate_private_key(ec.SECP256R1()))
    assert _sync(client, tok, forged).status_code == 422

    # Untrusted chain: a whole separate PKI the verifier doesn't trust.
    rogue = AppleFixture()
    assert _sync(client, tok, rogue.sign_transaction(appAccountToken=acc)).status_code == 422

    # Wrong bundle id -> wrong app -> 403.
    assert _sync(client, tok, apple.sign_transaction(appAccountToken=acc, bundleId="com.evil.app")).status_code == 403
    # Wrong product / wrong environment / malformed token -> 422.
    assert _sync(client, tok, apple.sign_transaction(appAccountToken=acc, productId="com.tonoit.pro.lifetime")).status_code == 422
    assert _sync(client, tok, apple.sign_transaction(appAccountToken=acc, environment="Xcode")).status_code == 422
    assert _sync(client, tok, apple.sign_transaction(appAccountToken="not-a-uuid")).status_code == 422

    # Stale signed active JWS after a refund must NOT resurrect the purchase.
    reg2 = _register(client)
    tok2, acc2 = reg2["api_token"], reg2["account_id"]
    orig = uuid.uuid4().hex
    base_ms = int(_now().timestamp() * 1000)
    assert _sync(
        client, tok2,
        apple.sign_transaction(appAccountToken=acc2, originalTransactionId=orig, signedDate=base_ms),
    ).status_code == 200
    # Refund notification at a later time.
    refund = apple.sign_notification("REFUND", tx=apple.transaction(originalTransactionId=orig, signedDate=base_ms + DAY_MS))
    assert _notify(client, refund).json()["outcome"] == "refunded"
    assert _me(client, tok2)["is_pro"] is False
    # Replay the OLD active transaction -> remains revoked, not entitled.
    replay = _sync(
        client, tok2,
        apple.sign_transaction(appAccountToken=acc2, originalTransactionId=orig, signedDate=base_ms - DAY_MS),
    )
    assert replay.status_code == 200
    assert replay.json()["is_pro"] is False
    assert _me(client, tok2)["is_pro"] is False


# ===========================================================================
# 8. Replay of a bound transaction by another account -> conflict, no leak
# ===========================================================================


def test_08_bound_transaction_replayed_by_other_account_conflicts(client, apple):
    dev_a = _register(client)
    orig = uuid.uuid4().hex
    jws = apple.sign_transaction(appAccountToken=dev_a["account_id"], originalTransactionId=orig)
    assert _sync(client, dev_a["api_token"], jws).status_code == 200

    dev_b = _register(client)
    r = _sync(client, dev_b["api_token"], jws)  # B uploads A's bound transaction
    assert r.status_code == 409
    body = r.text
    # The conflict reveals no owner account id / private data.
    assert dev_a["account_id"] not in body
    assert "person@example.com" not in body
    assert _me(client, dev_b["api_token"])["is_pro"] is False


# ===========================================================================
# 9. Token-present mismatch never falls into the legacy claim path
# ===========================================================================


def test_09_token_mismatch_never_becomes_legacy_claim(client, apple):
    from backend.store import get_store

    dev = _register(client)
    orig = uuid.uuid4().hex
    foreign = str(uuid.uuid4())  # a valid UUID, but not this account
    r = _sync(client, dev["api_token"], apple.sign_transaction(appAccountToken=foreign, originalTransactionId=orig))
    assert r.status_code == 409
    # No legacy claim row was ever created for a token-present transaction.
    assert get_store().get_legacy_claim(orig) is None


# ===========================================================================
# 10. Tokenless claim: idempotent for the winner, exactly one winner overall
# ===========================================================================


def test_10_tokenless_claim_idempotent_and_single_winner(client, apple):
    from backend.store import get_store

    store = get_store()
    dev_a = _register(client)
    dev_b = _register(client)
    orig = uuid.uuid4().hex

    def tokenless():
        return apple.sign_transaction(originalTransactionId=orig, appAccountToken=None)

    # A claims the tokenless lineage, then repeats -> idempotent, one grant.
    assert _sync(client, dev_a["api_token"], tokenless()).status_code == 200
    assert _sync(client, dev_a["api_token"], tokenless()).status_code == 200
    assert len(store.list_entitlement_grants(dev_a["account_id"])) == 1

    # B's later claim on the same lineage conflicts.
    assert _sync(client, dev_b["api_token"], tokenless()).status_code == 409
    assert store.list_entitlement_grants(dev_b["account_id"]) == []

    # Simultaneous claims on a fresh lineage -> exactly one winner/grant.
    orig2 = uuid.uuid4().hex
    dev_c = _register(client)
    dev_d = _register(client)

    def claim(dev):
        return _sync(client, dev["api_token"], apple.sign_transaction(originalTransactionId=orig2, appAccountToken=None))

    with ThreadPoolExecutor(max_workers=2) as ex:
        results = list(ex.map(claim, [dev_c, dev_d]))
    codes = sorted(r.status_code for r in results)
    assert codes == [200, 409]
    claim_row = store.get_legacy_claim(orig2)
    assert claim_row is not None
    winners = [d for d in (dev_c, dev_d) if store.list_entitlement_grants(d["account_id"])]
    assert len(winners) == 1
    assert claim_row["claimant_account_id"] == winners[0]["account_id"]


# ===========================================================================
# 11. Crash after commit + StoreKit redelivery -> one purchase/grant
# ===========================================================================


def test_11_redelivery_after_commit_is_idempotent(client, apple):
    from backend.store import get_store

    store = get_store()
    dev = _register(client)
    orig = uuid.uuid4().hex
    jws = apple.sign_transaction(appAccountToken=dev["account_id"], originalTransactionId=orig)

    # First delivery commits the grant. "Crash before HTTP response" is modeled
    # by StoreKit redelivering the very same signed transaction.
    assert _sync(client, dev["api_token"], jws).status_code == 200
    assert _sync(client, dev["api_token"], jws).status_code == 200
    assert _sync(client, dev["api_token"], jws).status_code == 200

    assert _db_scalar("SELECT COUNT(*) FROM provider_purchases WHERE original_transaction_id=?", (orig,)) == 1
    assert len(store.list_entitlement_grants(dev["account_id"])) == 1
    assert _me(client, dev["api_token"])["is_pro"] is True


# ===========================================================================
# 12. Set-App-Account-Token transient failure: entitlement stays, op retries
# ===========================================================================


def test_12_set_token_failure_keeps_entitlement_and_retries(client, apple):
    from backend.app_store import reconcile_set_app_account_token
    from backend.store import get_store

    store = get_store()
    dev = _register(client)
    orig = uuid.uuid4().hex
    assert _sync(client, dev["api_token"], apple.sign_transaction(originalTransactionId=orig, appAccountToken=None)).status_code == 200

    # A durable pending op exists after the tokenless claim.
    op = store.get_set_token_operation(orig)
    assert op is not None and op["state"] == "pending"

    # Transient failure: op -> failed, but the entitlement is untouched.
    def failing(_op):
        raise RuntimeError("Apple 503")

    tally = reconcile_set_app_account_token(store, failing)
    assert tally == {"succeeded": 0, "failed": 1}
    assert store.get_set_token_operation(orig)["state"] == "failed"
    assert _me(client, dev["api_token"])["is_pro"] is True  # entitlement remains

    # Retry succeeds and converges without a duplicate grant.
    tally2 = reconcile_set_app_account_token(store, lambda _op: None)
    assert tally2 == {"succeeded": 1, "failed": 0}
    assert store.get_set_token_operation(orig)["state"] == "succeeded"
    assert len(store.list_entitlement_grants(dev["account_id"])) == 1


# ===========================================================================
# 13. FAMILY_SHARED grants a beneficiary only — no token, no recovery
# ===========================================================================


def test_13_family_shared_grants_beneficiary_only(client, apple):
    from backend.store import get_store

    store = get_store()
    dev = _register(client)
    orig = uuid.uuid4().hex
    r = _sync(
        client, dev["api_token"],
        apple.sign_transaction(originalTransactionId=orig, inAppOwnershipType="FAMILY_SHARED", appAccountToken=None),
    )
    assert r.status_code == 200
    assert r.json()["is_pro"] is True

    grants = store.list_entitlement_grants(dev["account_id"])
    assert len(grants) == 1 and grants[0]["grant_kind"] == "family"
    purchase = store.get_provider_purchase(orig)
    assert purchase["ownership_type"] == "FAMILY_SHARED"
    assert purchase["app_account_token"] is None          # no token set
    assert store.get_set_token_operation(orig) is None     # no Set-Token attempted
    assert store.get_legacy_claim(orig) is None            # family is not a legacy claim


# ===========================================================================
# 14. Family revocation removes only that beneficiary's grant
# ===========================================================================


def test_14_family_revocation_targets_one_beneficiary(client, apple):
    from backend.store import get_store

    store = get_store()
    orig = uuid.uuid4().hex

    # Two family members share one purchase lineage; each gets a family grant.
    dev_a = _register(client)
    dev_b = _register(client)
    for dev in (dev_a, dev_b):
        assert _sync(
            client, dev["api_token"],
            apple.sign_transaction(originalTransactionId=orig, inAppOwnershipType="FAMILY_SHARED", appAccountToken=None),
        ).status_code == 200

    base_ms = int(_now().timestamp() * 1000)
    # Revoke sharing for beneficiary A only (notification carries A's token).
    revoke = apple.sign_notification(
        "REVOKE",
        tx=apple.transaction(
            originalTransactionId=orig, inAppOwnershipType="FAMILY_SHARED",
            appAccountToken=dev_a["account_id"], signedDate=base_ms + DAY_MS,
        ),
    )
    assert _notify(client, revoke).json()["outcome"] == "beneficiary_revoked"

    assert _me(client, dev_a["api_token"])["is_pro"] is False  # A revoked
    assert _me(client, dev_b["api_token"])["is_pro"] is True   # B intact
    assert store.get_provider_purchase(orig)["lifecycle_state"] == "active"  # purchase intact


# ===========================================================================
# 15. Refund then delayed older active stays revoked; trial-consumed sticks
# ===========================================================================


def test_15_refund_is_terminal_and_preserves_trial_consumed(client, apple):
    from backend.store import get_store

    store = get_store()
    dev = _register(client)
    orig = uuid.uuid4().hex
    base_ms = int(_now().timestamp() * 1000)

    # Purchase used the free-trial introductory offer (offerType 1).
    assert _sync(
        client, dev["api_token"],
        apple.sign_transaction(appAccountToken=dev["account_id"], originalTransactionId=orig, signedDate=base_ms, offerType=1),
    ).status_code == 200
    assert store.get_provider_purchase(orig)["trial_consumed"] == 1

    # Refund.
    assert _notify(client, apple.sign_notification("REFUND", tx=apple.transaction(originalTransactionId=orig, signedDate=base_ms + DAY_MS))).json()["outcome"] == "refunded"
    assert _me(client, dev["api_token"])["is_pro"] is False
    assert store.get_provider_purchase(orig)["trial_consumed"] == 1  # refund never reset it

    # A delayed OLDER active transaction must not resurrect entitlement or reset
    # trial-consumed.
    replay = _sync(
        client, dev["api_token"],
        apple.sign_transaction(appAccountToken=dev["account_id"], originalTransactionId=orig, signedDate=base_ms - DAY_MS),
    )
    assert replay.json()["is_pro"] is False
    p = store.get_provider_purchase(orig)
    assert p["lifecycle_state"] == "refunded"
    assert p["trial_consumed"] == 1


# ===========================================================================
# 16. Notification duplicate / out-of-order is idempotent; current state wins
# ===========================================================================


def test_16_notifications_dedupe_and_current_state_wins(client, apple):
    from backend.store import get_store

    store = get_store()
    dev = _register(client)
    orig = uuid.uuid4().hex
    base_ms = int(_now().timestamp() * 1000)
    assert _sync(client, dev["api_token"], apple.sign_transaction(appAccountToken=dev["account_id"], originalTransactionId=orig, signedDate=base_ms)).status_code == 200

    # A refund at t2.
    refund = apple.sign_notification("REFUND", tx=apple.transaction(originalTransactionId=orig, signedDate=base_ms + 2 * DAY_MS))
    assert _notify(client, refund).json()["outcome"] == "refunded"

    # Exact duplicate (same notificationUUID) -> deduped, state unchanged.
    assert _notify(client, refund).json()["outcome"] == "duplicate"
    assert store.get_provider_purchase(orig)["lifecycle_state"] == "refunded"

    # A stale (older, t1) renewal delivered out of order is ignored.
    stale_renew = apple.sign_notification("DID_RENEW", tx=apple.transaction(originalTransactionId=orig, signedDate=base_ms + DAY_MS))
    assert _notify(client, stale_renew).json()["outcome"] == "stale"
    assert store.get_provider_purchase(orig)["lifecycle_state"] == "refunded"
    assert _me(client, dev["api_token"])["is_pro"] is False

    # A newer (t3) renewal is the current state and wins.
    fresh_renew = apple.sign_notification("DID_RENEW", tx=apple.transaction(originalTransactionId=orig, signedDate=base_ms + 3 * DAY_MS, expiresDate=base_ms + 40 * DAY_MS))
    assert _notify(client, fresh_renew).json()["outcome"] == "active"
    assert _me(client, dev["api_token"])["is_pro"] is True


# ===========================================================================
# 17. Cached true + backend false -> false; server authority clears Pro
# ===========================================================================


def test_17_backend_false_overrides_any_client_cache(client, apple):
    dev = _register(client)
    orig = uuid.uuid4().hex
    base_ms = int(_now().timestamp() * 1000)
    assert _sync(client, dev["api_token"], apple.sign_transaction(appAccountToken=dev["account_id"], originalTransactionId=orig, signedDate=base_ms)).status_code == 200
    assert _me(client, dev["api_token"])["is_pro"] is True
    # An entitled account is unlimited.
    assert client.post("/api/analyze", json={"text": "hi there"}, headers=_auth(dev["api_token"])).json()["daily_limit"] == -1

    # Backend now says false (refund). Even if a client cached Pro=true, the
    # server is the authority: is_pro flips false and paid usage is regated.
    assert _notify(client, apple.sign_notification("REFUND", tx=apple.transaction(originalTransactionId=orig, signedDate=base_ms + DAY_MS))).json()["outcome"] == "refunded"
    me = _me(client, dev["api_token"])
    assert me["is_pro"] is False
    assert me["daily_limit"] == 3  # FREE_DAILY_LIMIT from conftest — back to free


# ===========================================================================
# 18. Backend unavailable -> unknown -> paid request denied (fail closed)
# ===========================================================================


def test_18_unknown_fails_closed_no_entitlement(client, apple):
    dev = _register(client)
    # Simulate reconciliation being unavailable: the verifier is unconfigured,
    # so the App Store endpoint cannot confirm anything -> 503 (unknown).
    apple.disable()
    r = _sync(client, dev["api_token"], apple.sign_transaction(appAccountToken=dev["account_id"]))
    assert r.status_code == 503  # unknown, never an optimistic grant

    # Unknown fails closed: no grant exists and the server never presents Pro.
    assert _me(client, dev["api_token"])["is_pro"] is False
    # Paid backend usage is denied by the server regardless of any client cache.
    for _ in range(3):
        assert client.post("/api/analyze", json={"text": "hello"}, headers=_auth(dev["api_token"])).status_code == 200
    assert client.post("/api/analyze", json={"text": "hello"}, headers=_auth(dev["api_token"])).status_code == 429


# ===========================================================================
# 19. Purchase success but server 503 -> unfinished; retry finishes exactly once
# ===========================================================================


def test_19_transient_failure_then_retry_grants_exactly_once(client, apple):
    from backend.store import get_store

    store = get_store()
    dev = _register(client)
    orig = uuid.uuid4().hex
    jws = apple.sign_transaction(appAccountToken=dev["account_id"], originalTransactionId=orig)

    # Transient server-side unavailability: no durable grant is written, so the
    # StoreKit transaction stays unfinished (the client will redeliver).
    apple.disable()
    assert _sync(client, dev["api_token"], jws).status_code == 503
    assert _db_scalar("SELECT COUNT(*) FROM provider_purchases WHERE original_transaction_id=?", (orig,)) == 0
    assert _me(client, dev["api_token"])["is_pro"] is False

    # Recovery: the same transaction is redelivered once the server can confirm
    # again, and now durably grants — exactly once, idempotent under further
    # redelivery.
    from backend import app_store
    from backend.server import app

    app.dependency_overrides[app_store.get_appstore_verifier] = lambda: apple.verifier
    assert _sync(client, dev["api_token"], jws).status_code == 200
    assert _sync(client, dev["api_token"], jws).status_code == 200
    assert _db_scalar("SELECT COUNT(*) FROM provider_purchases WHERE original_transaction_id=?", (orig,)) == 1
    assert len(store.list_entitlement_grants(dev["account_id"])) == 1


# ===========================================================================
# 20. Stale build-90 tokenless purchase is claimable — no version/date cutoff
# ===========================================================================


def test_20_old_tokenless_purchase_is_never_rejected_for_being_old(client, apple):
    from backend.store import get_store

    store = get_store()
    dev = _register(client)
    orig = uuid.uuid4().hex
    # A build-90 charge from a year ago: validly signed, active, tokenless.
    year_ago_ms = int((_now() - dt.timedelta(days=365)).timestamp() * 1000)
    r = _sync(
        client, dev["api_token"],
        apple.sign_transaction(
            originalTransactionId=orig, appAccountToken=None,
            signedDate=year_ago_ms, purchaseDate=year_ago_ms,
            expiresDate=int((_now() + dt.timedelta(days=30)).timestamp() * 1000),
        ),
    )
    # It is claimed via the permanent legacy path, NOT rejected for being old.
    assert r.status_code == 200, r.text
    assert r.json()["is_pro"] is True
    assert store.get_legacy_claim(orig)["claimant_account_id"] == dev["account_id"]


# ===========================================================================
# Remediation hostile regressions (close the five P0 falsifications + the
# current-provider / Set-Token production seams). Each drives real behavior and
# the DB mutation boundary, not source greps.
# ===========================================================================


# ---- P0 #1: missing/unknown ownership must fail closed (never PURCHASED) ----


def test_p0_missing_or_unknown_ownership_fails_closed(client, apple):
    from backend.store import get_store

    store = get_store()
    dev = _register(client)

    # Tokenless signed transaction with NO inAppOwnershipType. A prior candidate
    # defaulted this to PURCHASED and granted Pro; it must now 422 and grant
    # nothing — no purchase row, no legacy claim, no grant.
    orig = uuid.uuid4().hex
    r = _sync(
        client, dev["api_token"],
        apple.sign_transaction(originalTransactionId=orig, appAccountToken=None, inAppOwnershipType=None),
    )
    assert r.status_code == 422
    assert _me(client, dev["api_token"])["is_pro"] is False
    assert _db_scalar("SELECT COUNT(*) FROM provider_purchases WHERE original_transaction_id=?", (orig,)) == 0
    assert store.get_legacy_claim(orig) is None
    assert store.list_entitlement_grants(dev["account_id"]) == []

    # An unrecognized ownership string is equally refused.
    orig2 = uuid.uuid4().hex
    r2 = _sync(
        client, dev["api_token"],
        apple.sign_transaction(originalTransactionId=orig2, appAccountToken=None, inAppOwnershipType="WEIRD_TYPE"),
    )
    assert r2.status_code == 422
    assert _db_scalar("SELECT COUNT(*) FROM provider_purchases WHERE original_transaction_id=?", (orig2,)) == 0


# ---- P0 #2: notification must validate the nested transaction (wrong app) ----


def test_p0_notification_rejects_wrong_app_nested_transaction(client, apple):
    from backend.store import get_store

    store = get_store()
    dev = _register(client)
    orig = uuid.uuid4().hex
    assert _sync(
        client, dev["api_token"],
        apple.sign_transaction(appAccountToken=dev["account_id"], originalTransactionId=orig),
    ).status_code == 200
    assert _me(client, dev["api_token"])["is_pro"] is True

    # A validly Apple-signed REFUND whose NESTED transaction is for a different
    # app. It must be rejected (403) via the same canonical transaction path and
    # mutate NOTHING — the active purchase is untouched.
    base_ms = int(_now().timestamp() * 1000)
    hostile = apple.sign_notification(
        "REFUND",
        tx=apple.transaction(
            originalTransactionId=orig, bundleId="com.other.vendor.app", signedDate=base_ms + DAY_MS
        ),
    )
    r = _notify(client, hostile)
    assert r.status_code == 403
    assert store.get_provider_purchase(orig)["lifecycle_state"] == "active"
    assert _me(client, dev["api_token"])["is_pro"] is True


# ---- P0 #3: terminal beats active on an EQUAL provider timestamp ----


def test_p0_equal_timestamp_terminal_beats_active(client, apple):
    from backend.store import get_store

    store = get_store()
    dev = _register(client)
    orig = uuid.uuid4().hex
    base_ms = int(_now().timestamp() * 1000)
    assert _sync(
        client, dev["api_token"],
        apple.sign_transaction(appAccountToken=dev["account_id"], originalTransactionId=orig, signedDate=base_ms),
    ).status_code == 200

    t_terminal = base_ms + DAY_MS
    assert _notify(
        client,
        apple.sign_notification("REFUND", tx=apple.transaction(originalTransactionId=orig, signedDate=t_terminal)),
    ).json()["outcome"] == "refunded"
    assert _me(client, dev["api_token"])["is_pro"] is False

    # A renewal at the SAME provider timestamp must NOT resurrect: terminal wins
    # on the tie (deterministic equal-timestamp precedence).
    same_ts_renew = apple.sign_notification(
        "DID_RENEW",
        tx=apple.transaction(originalTransactionId=orig, signedDate=t_terminal, expiresDate=base_ms + 40 * DAY_MS),
    )
    assert _notify(client, same_ts_renew).json()["outcome"] == "stale"
    assert store.get_provider_purchase(orig)["lifecycle_state"] == "refunded"
    assert _me(client, dev["api_token"])["is_pro"] is False

    # A client replay of an ACTIVE transaction at the SAME signed timestamp also
    # cannot resurrect (transaction-path equal-timestamp precedence).
    replay = _sync(
        client, dev["api_token"],
        apple.sign_transaction(appAccountToken=dev["account_id"], originalTransactionId=orig, signedDate=t_terminal),
    )
    assert replay.json()["is_pro"] is False
    assert store.get_provider_purchase(orig)["lifecycle_state"] == "refunded"

    # Replay idempotence is preserved: a duplicate refund (same notificationUUID)
    # is deduped, and terminal state is unchanged.
    dup = apple.sign_notification("REFUND", tx=apple.transaction(originalTransactionId=orig, signedDate=t_terminal))
    first = _notify(client, dup).json()["outcome"]
    assert _notify(client, dup).json()["outcome"] == "duplicate"
    assert first == "refunded"
    assert store.get_provider_purchase(orig)["lifecycle_state"] == "refunded"


# ---- P0 #4: a TOKENLESS family revoke must not mass-revoke beneficiaries ----


def test_p0_tokenless_family_revoke_never_mass_revokes(client, apple):
    from backend.store import get_store

    store = get_store()
    orig = uuid.uuid4().hex
    dev_a = _register(client)
    dev_b = _register(client)
    base_ms = int(_now().timestamp() * 1000)

    # Two family beneficiaries share one purchase lineage; each gets a family grant.
    for dev in (dev_a, dev_b):
        assert _sync(
            client, dev["api_token"],
            apple.sign_transaction(
                originalTransactionId=orig, inAppOwnershipType="FAMILY_SHARED",
                appAccountToken=None, signedDate=base_ms,
            ),
        ).status_code == 200
    assert _me(client, dev_a["api_token"])["is_pro"] is True
    assert _me(client, dev_b["api_token"])["is_pro"] is True

    # A real-shape TOKENLESS FAMILY_SHARED revoke (no appAccountToken — the
    # contract's own family semantics). No beneficiary can be proven, so it must
    # NOT revoke anyone; the event is parked for provider reconciliation.
    revoke = apple.sign_notification(
        "REVOKE",
        tx=apple.transaction(
            originalTransactionId=orig, inAppOwnershipType="FAMILY_SHARED",
            appAccountToken=None, signedDate=base_ms + DAY_MS,
        ),
    )
    assert _notify(client, revoke).json()["outcome"] == "unresolved_beneficiary"

    # Neither beneficiary lost Pro; the purchase and both grants are intact.
    assert _me(client, dev_a["api_token"])["is_pro"] is True
    assert _me(client, dev_b["api_token"])["is_pro"] is True
    assert store.get_provider_purchase(orig)["lifecycle_state"] == "active"
    assert [g["state"] for g in store.list_entitlement_grants(dev_a["account_id"])] == ["active"]
    assert [g["state"] for g in store.list_entitlement_grants(dev_b["account_id"])] == ["active"]

    # The dropped revoke is durably recorded (non-destructive) for reconciliation.
    unresolved = store.list_unresolved_events()
    assert len(unresolved) == 1
    assert unresolved[0]["original_transaction_id"] == orig
    assert unresolved[0]["reason"] == "family_revoke_no_provable_beneficiary"

    # And a proven-beneficiary (token-present) revoke still targets exactly one.
    targeted = apple.sign_notification(
        "REVOKE",
        tx=apple.transaction(
            originalTransactionId=orig, inAppOwnershipType="FAMILY_SHARED",
            appAccountToken=dev_a["account_id"], signedDate=base_ms + 2 * DAY_MS,
        ),
    )
    assert _notify(client, targeted).json()["outcome"] == "beneficiary_revoked"
    assert _me(client, dev_a["api_token"])["is_pro"] is False
    assert _me(client, dev_b["api_token"])["is_pro"] is True


# ---- P0 #5: a non-CA intermediate in the JWS chain must be rejected ----


def test_p0_non_ca_intermediate_is_rejected(client, apple):
    dev = _register(client)

    # Build a chain whose intermediate is NOT a CA (BasicConstraints ca=False),
    # signed by the trusted test root, with a leaf under it. A prior home-grown
    # verifier accepted this; Apple's library rejects it (X509_STRICT / path).
    bad_int_key, bad_int_cert = _mk_cert(
        "Tono Test Non-CA Intermediate", apple.root_cert, apple.root_key,
        ca=False, marker_oid=WWDR_MARKER_OID,
    )
    leaf_key, leaf_cert = _mk_cert(
        "Tono Test Leaf via non-CA int", bad_int_cert, bad_int_key,
        ca=False, marker_oid=LEAF_MARKER_OID,
    )
    from cryptography.hazmat.primitives.serialization import Encoding

    x5c = [
        base64.b64encode(c.public_bytes(Encoding.DER)).decode("ascii")
        for c in (leaf_cert, bad_int_cert, apple.root_cert)
    ]
    jws = jwt.encode(
        apple.transaction(appAccountToken=dev["account_id"]),
        leaf_key, algorithm="ES256", headers={"x5c": x5c},
    )
    r = _sync(client, dev["api_token"], jws)
    assert r.status_code == 422, r.text
    assert _me(client, dev["api_token"])["is_pro"] is False
    assert _db_scalar("SELECT COUNT(*) FROM provider_purchases") == 0


# ---- Blocker A: current-provider terminal state beats replayed active proof ----


def _override_provider_client(app, client_obj):
    from backend import app_store

    app.dependency_overrides[app_store.get_current_provider_client] = lambda: client_obj


def test_blockerA_current_provider_terminal_blocks_replayed_active_proof(client, apple):
    from backend import app_store
    from backend.server import app
    from backend.store import get_store

    store = get_store()
    dev = _register(client)
    orig = uuid.uuid4().hex

    class FakeProvider:
        def current_state(self, original_transaction_id, environment):
            assert original_transaction_id == orig
            # Apple's live state for this lineage is REVOKED even though the
            # client uploads an apparently-active signed transaction.
            return app_store.ProviderStateSnapshot(lifecycle_state="revoked", signed_ms=0)

    _override_provider_client(app, FakeProvider())
    try:
        r = _sync(
            client, dev["api_token"],
            apple.sign_transaction(appAccountToken=dev["account_id"], originalTransactionId=orig),
        )
        assert r.status_code == 200
        assert r.json()["is_pro"] is False  # replayed proof did NOT grant
        assert _me(client, dev["api_token"])["is_pro"] is False
        assert store.get_provider_purchase(orig)["lifecycle_state"] == "revoked"
        assert store.list_entitlement_grants(dev["account_id"]) == []
    finally:
        app.dependency_overrides.pop(app_store.get_current_provider_client, None)


def test_blockerA_current_provider_unavailable_fails_closed_503(client, apple):
    from backend import app_store
    from backend.server import app

    dev = _register(client)
    orig = uuid.uuid4().hex

    class FailingProvider:
        def current_state(self, original_transaction_id, environment):
            raise app_store.ProviderUnavailable("Apple App Store Server API 503")

    _override_provider_client(app, FailingProvider())
    try:
        r = _sync(
            client, dev["api_token"],
            apple.sign_transaction(appAccountToken=dev["account_id"], originalTransactionId=orig),
        )
        # Missing/unavailable provider trust fails closed (retryable), never a
        # silent grant, and writes no durable purchase.
        assert r.status_code == 503
        assert _db_scalar("SELECT COUNT(*) FROM provider_purchases WHERE original_transaction_id=?", (orig,)) == 0
        assert _me(client, dev["api_token"])["is_pro"] is False
    finally:
        app.dependency_overrides.pop(app_store.get_current_provider_client, None)


# ---- Blocker D: the concrete App Store Server API Set-Token sender ----


def test_blockerD_concrete_set_token_sender_calls_api_and_is_retry_safe(client, apple):
    from backend.app_store import AppStoreServerSetTokenSender, reconcile_set_app_account_token
    from backend.store import get_store

    store = get_store()
    dev = _register(client)
    orig = uuid.uuid4().hex
    assert _sync(
        client, dev["api_token"],
        apple.sign_transaction(originalTransactionId=orig, appAccountToken=None),
    ).status_code == 200
    op = store.get_set_token_operation(orig)
    assert op is not None and op["state"] == "pending"

    # A fake App Store Server API client that first fails transiently, then
    # succeeds — proving the concrete sender is wired to the real API method and
    # that a transient failure never erases the already-verified entitlement.
    class FakeAPIClient:
        def __init__(self):
            self.calls = []
            self.fail_next = True

        def set_app_account_token(self, original_transaction_id, request):
            self.calls.append((original_transaction_id, request.appAccountToken))
            if self.fail_next:
                self.fail_next = False
                raise RuntimeError("transient App Store Server API failure")

    fake = FakeAPIClient()
    sender = AppStoreServerSetTokenSender({"Production": fake}, "Production")

    # First reconcile: transient failure -> op retriable, entitlement intact.
    assert reconcile_set_app_account_token(store, sender) == {"succeeded": 0, "failed": 1}
    assert store.get_set_token_operation(orig)["state"] == "failed"
    assert _me(client, dev["api_token"])["is_pro"] is True

    # Retry: success, converges without a duplicate grant; op idempotently done.
    assert reconcile_set_app_account_token(store, sender) == {"succeeded": 1, "failed": 0}
    assert store.get_set_token_operation(orig)["state"] == "succeeded"
    assert reconcile_set_app_account_token(store, sender) == {"succeeded": 0, "failed": 0}
    assert fake.calls == [(orig, dev["account_id"]), (orig, dev["account_id"])]
    assert len(store.list_entitlement_grants(dev["account_id"])) == 1
