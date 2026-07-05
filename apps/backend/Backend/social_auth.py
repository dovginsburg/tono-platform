"""Apple / Google identity-token verification for account sign-in.

Both providers issue a signed JWT ("identity token" / "ID token") after the
client completes native Sign in with Apple / Google. The client sends that
token to us; we verify its signature against the provider's published JWKS,
check audience/issuer, and trust the `sub` claim as the stable per-provider
user identifier. We never see a password and never talk to the provider on
the client's behalf — this is pure token verification.

Testability: server.py depends on `get_apple_verifier`/`get_google_verifier`
(not the verify functions directly), so tests can override them via
`app.dependency_overrides` and never need real network access to Apple/
Google's key endpoints or a real signed token. The default implementations
below ARE real and are what runs in production — they are just not
exercised by this repo's test suite, since this sandbox has no network path
to appleid.apple.com or googleapis.com to verify that end-to-end. Confirm
against real Apple/Google tokens from a dev machine before shipping.

`APPLE_JWKS_URL`/`APPLE_ISSUER`/`GOOGLE_JWKS_URL`/`GOOGLE_ISSUERS` are
overridable via env vars specifically so
`Backend/scripts/oauth_test_harness.py` can point this module's REAL
verification code (JWKS fetch, RS256 signature check, aud/iss validation —
not a mock) at a local fake JWKS server instead of the real providers, and
exercise the exact code path that runs in production without needing
network access to Apple/Google or real production client IDs. Leave these
unset in production — the defaults below are the real endpoints.
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass
from typing import Any, Callable, Optional

import httpx
import jwt
from fastapi import HTTPException, status

APPLE_ISSUER = os.environ.get("APPLE_ISSUER", "https://appleid.apple.com")
APPLE_JWKS_URL = os.environ.get("APPLE_JWKS_URL", "https://appleid.apple.com/auth/keys")
GOOGLE_ISSUERS = tuple(
    os.environ.get("GOOGLE_ISSUERS", "accounts.google.com,https://accounts.google.com").split(",")
)
GOOGLE_JWKS_URL = os.environ.get("GOOGLE_JWKS_URL", "https://www.googleapis.com/oauth2/v3/certs")

_JWKS_TTL_SECONDS = 3600


@dataclass
class IdentityClaims:
    sub: str
    email: Optional[str] = None


IdentityVerifier = Callable[[str], "Any"]  # async (token: str) -> IdentityClaims


class _JwksCache:
    """Tiny in-memory JWKS cache, one per provider. A 1-hour TTL matches
    both providers' documented key-rotation cadence (they rotate rarely and
    publish overlapping old+new keys during rotation, so a slightly-stale
    cache never breaks verification — it just means a brand-new key
    published in the last hour might briefly not verify)."""

    def __init__(self, url: str):
        self.url = url
        self._keys: dict[str, dict] = {}
        self._fetched_at: float = 0.0

    async def get_key(self, kid: str) -> dict:
        if not self._keys or (time.time() - self._fetched_at) > _JWKS_TTL_SECONDS:
            await self._refresh()
        key = self._keys.get(kid)
        if not key:
            # kid not found even after a fresh fetch — force one more refresh
            # in case the provider rotated keys since our last cache.
            await self._refresh()
            key = self._keys.get(kid)
        if not key:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "unknown signing key")
        return key

    async def _refresh(self) -> None:
        async with httpx.AsyncClient(timeout=10) as c:
            r = await c.get(self.url)
            r.raise_for_status()
            data = r.json()
        self._keys = {k["kid"]: k for k in data.get("keys", [])}
        self._fetched_at = time.time()


_apple_jwks = _JwksCache(APPLE_JWKS_URL)
_google_jwks = _JwksCache(GOOGLE_JWKS_URL)


def _decode_with_jwk(token: str, jwk: dict, *, audience: str, issuer) -> dict:
    public_key = jwt.algorithms.RSAAlgorithm.from_jwk(jwk)
    return jwt.decode(
        token,
        key=public_key,
        algorithms=["RS256"],
        audience=audience,
        issuer=issuer,
    )


async def verify_apple_identity_token(identity_token: str) -> IdentityClaims:
    client_id = os.environ.get("APPLE_CLIENT_ID")
    if not client_id:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Apple sign-in not configured")
    try:
        header = jwt.get_unverified_header(identity_token)
        jwk = await _apple_jwks.get_key(header["kid"])
        claims = _decode_with_jwk(identity_token, jwk, audience=client_id, issuer=APPLE_ISSUER)
    except jwt.PyJWTError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, f"invalid Apple identity token: {exc}")
    return IdentityClaims(sub=claims["sub"], email=claims.get("email"))


async def verify_google_id_token(id_token: str) -> IdentityClaims:
    client_id = os.environ.get("GOOGLE_CLIENT_ID")
    if not client_id:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Google sign-in not configured")
    try:
        header = jwt.get_unverified_header(id_token)
        jwk = await _google_jwks.get_key(header["kid"])
        claims = _decode_with_jwk(id_token, jwk, audience=client_id, issuer=list(GOOGLE_ISSUERS))
    except jwt.PyJWTError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, f"invalid Google ID token: {exc}")
    return IdentityClaims(sub=claims["sub"], email=claims.get("email"))


# ---------------------------------------------------------------------------
# FastAPI dependency indirection — override these (not the verify_* functions
# above) in tests via app.dependency_overrides.
# ---------------------------------------------------------------------------


def get_apple_verifier() -> IdentityVerifier:
    return verify_apple_identity_token


def get_google_verifier() -> IdentityVerifier:
    return verify_google_id_token
