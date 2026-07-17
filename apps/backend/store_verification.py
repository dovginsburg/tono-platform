"""Fail-closed Apple StoreKit and Google Play subscription verification."""

from __future__ import annotations

import base64
import datetime as dt
import hashlib
import json
import os
from dataclasses import dataclass
from typing import Any
from urllib.parse import quote

import httpx
import jwt
from cryptography import x509
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa

PRODUCT_IDS = {"com.tonoit.pro.monthly", "com.tonoit.pro.yearly"}


class StoreVerificationError(ValueError):
    pass


@dataclass(frozen=True)
class VerifiedStoreSubscription:
    product_id: str
    subscription_id: str
    status: str
    renews_at: str | None


def _verify_certificate_signature(cert: x509.Certificate, issuer_public_key: Any) -> None:
    if isinstance(issuer_public_key, rsa.RSAPublicKey):
        issuer_public_key.verify(cert.signature, cert.tbs_certificate_bytes, padding.PKCS1v15(), cert.signature_hash_algorithm)
    elif isinstance(issuer_public_key, ec.EllipticCurvePublicKey):
        issuer_public_key.verify(cert.signature, cert.tbs_certificate_bytes, ec.ECDSA(cert.signature_hash_algorithm))
    else:
        raise StoreVerificationError("unsupported Apple certificate key")


async def verify_apple_transaction(signed_transaction: str) -> VerifiedStoreSubscription:
    root_pem = os.environ.get("APPLE_ROOT_CA_PEM")
    if not root_pem:
        raise StoreVerificationError("Apple verification is not configured")
    try:
        header = jwt.get_unverified_header(signed_transaction)
        chain = [x509.load_der_x509_certificate(base64.b64decode(item)) for item in header["x5c"]]
        trusted_root = x509.load_pem_x509_certificate(root_pem.encode())
    except Exception as error:
        raise StoreVerificationError("invalid Apple certificate chain") from error
    if len(chain) < 2:
        raise StoreVerificationError("incomplete Apple certificate chain")

    now = dt.datetime.now(dt.timezone.utc)
    for cert in chain:
        valid_from = cert.not_valid_before.replace(tzinfo=dt.timezone.utc)
        valid_until = cert.not_valid_after.replace(tzinfo=dt.timezone.utc)
        if not (valid_from <= now <= valid_until):
            raise StoreVerificationError("expired Apple signing certificate")
    try:
        for cert, issuer in zip(chain, chain[1:]):
            _verify_certificate_signature(cert, issuer.public_key())
        _verify_certificate_signature(chain[-1], trusted_root.public_key())
    except Exception as error:
        raise StoreVerificationError("untrusted Apple signing certificate") from error

    try:
        payload = jwt.decode(signed_transaction, chain[0].public_key(), algorithms=["ES256"], options={"verify_aud": False})
    except Exception as error:
        raise StoreVerificationError("invalid Apple transaction signature") from error
    product_id = payload.get("productId")
    if product_id not in PRODUCT_IDS:
        raise StoreVerificationError("unexpected Apple product")
    if payload.get("bundleId") != os.environ.get("APPLE_BUNDLE_ID", "com.tonoit.app"):
        raise StoreVerificationError("unexpected Apple bundle")

    expiry_ms = payload.get("expiresDate")
    expiry = dt.datetime.fromtimestamp(int(expiry_ms) / 1000, tz=dt.timezone.utc) if expiry_ms else None
    if payload.get("revocationDate") is not None:
        status = "canceled"
    elif expiry is None or expiry <= now:
        status = "expired"
    elif payload.get("offerType") == 1:
        status = "trialing"
    else:
        status = "active"
    subscription_id = str(payload.get("originalTransactionId") or "")
    if not subscription_id:
        raise StoreVerificationError("Apple transaction has no original id")
    return VerifiedStoreSubscription(product_id, subscription_id, status, expiry.isoformat() if expiry else None)


async def verify_google_play_subscription(package_name: str, product_id: str, purchase_token: str) -> VerifiedStoreSubscription:
    if package_name != os.environ.get("GOOGLE_PLAY_PACKAGE_NAME", "com.tono.myapp") or product_id not in PRODUCT_IDS or not purchase_token:
        raise StoreVerificationError("unexpected Google Play purchase")
    raw_credentials = os.environ.get("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON")
    if not raw_credentials:
        raise StoreVerificationError("Google Play verification is not configured")
    try:
        credentials = json.loads(raw_credentials)
        now = int(dt.datetime.now(dt.timezone.utc).timestamp())
        token_uri = credentials.get("token_uri", "https://oauth2.googleapis.com/token")
        assertion = jwt.encode({
            "iss": credentials["client_email"],
            "scope": "https://www.googleapis.com/auth/androidpublisher",
            "aud": token_uri,
            "iat": now,
            "exp": now + 300,
        }, credentials["private_key"], algorithm="RS256")
        async with httpx.AsyncClient(timeout=15) as client:
            token_response = await client.post(token_uri, data={"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion})
            token_response.raise_for_status()
            response = await client.get(
                f"https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{package_name}/purchases/subscriptionsv2/tokens/{quote(purchase_token, safe='')}",
                headers={"Authorization": f"Bearer {token_response.json()['access_token']}"},
            )
            response.raise_for_status()
            payload = response.json()
    except Exception as error:
        raise StoreVerificationError("Google Play verification failed") from error

    matching = next((item for item in payload.get("lineItems") or [] if item.get("productId") == product_id), None)
    if matching is None:
        raise StoreVerificationError("Google Play product mismatch")
    state = payload.get("subscriptionState", "SUBSCRIPTION_STATE_UNSPECIFIED")
    offer_id = (matching.get("offerDetails") or {}).get("offerId")
    trial_offer_ids = {item for item in os.environ.get("GOOGLE_PLAY_TRIAL_OFFER_IDS", "").split(",") if item}
    status_map = {
        "SUBSCRIPTION_STATE_IN_GRACE_PERIOD": "past_due",
        "SUBSCRIPTION_STATE_ON_HOLD": "past_due",
        "SUBSCRIPTION_STATE_CANCELED": "canceled",
        "SUBSCRIPTION_STATE_EXPIRED": "expired",
        "SUBSCRIPTION_STATE_PAUSED": "expired",
        "SUBSCRIPTION_STATE_PENDING_PURCHASE": "incomplete",
    }
    status = ("trialing" if offer_id and offer_id in trial_offer_ids else "active") if state == "SUBSCRIPTION_STATE_ACTIVE" else status_map.get(state, "unknown")
    return VerifiedStoreSubscription(
        product_id,
        hashlib.sha256(purchase_token.encode()).hexdigest(),
        status,
        matching.get("expiryTime"),
    )
