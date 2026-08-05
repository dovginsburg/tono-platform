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
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass
from typing import Any, Callable, Optional

import httpx
import jwt
from fastapi import HTTPException, status

APPLE_ISSUER = "https://appleid.apple.com"
APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"
GOOGLE_ISSUERS = ("accounts.google.com", "https://accounts.google.com")
GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs"

_JWKS_TTL_SECONDS = 3600


@dataclass
class IdentityClaims:
    sub: str
    email: Optional[str] = None
    nonce: Optional[str] = None
    # True only when the provider itself attests the address is verified. Apple
    # and Google both publish this claim; we default to False (fail closed) so an
    # address can never drive verified-email account convergence unless the token
    # actually proved it. Apple encodes the flag as a JSON string ("true"), so we
    # coerce truthy spellings uniformly.
    email_verified: bool = False


def _claim_email_verified(claims: dict) -> bool:
    """Coerce a provider ``email_verified`` claim to a strict bool.

    Apple sends it as the string ``"true"``/``"false"``; Google as a JSON bool.
    Anything not an affirmative true (missing, false, unexpected) reads as
    UNVERIFIED so it cannot be the thing that merges two accounts."""
    value = claims.get("email_verified")
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() == "true"
    return False


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
    return IdentityClaims(
        sub=claims["sub"],
        email=claims.get("email"),
        nonce=claims.get("nonce"),
        email_verified=_claim_email_verified(claims),
    )


async def verify_apple_web_identity_token(identity_token: str) -> IdentityClaims:
    """Verify an Apple identity token from the WEB Sign in with Apple flow.

    Identical cryptography to the native path (`verify_apple_identity_token`) —
    same Apple JWKS, same RS256, same issuer — but the audience is the Apple
    **Services ID** the website owns (`APPLE_WEB_CLIENT_ID`, e.g. ``tonoit.com``)
    rather than the native app's client id (`APPLE_CLIENT_ID`, ``com.tonoit.app``).

    Keeping the two audiences on two verifiers (instead of one that accepts
    both) means the native endpoint can never be satisfied by a web-audience
    token and vice versa, while both still resolve to the SAME ``apple_sub`` —
    Apple issues one stable subject per person across a primary App ID and the
    Services ID grouped under it — so native iOS and web Apple sign-ins converge
    onto one canonical account for free (see ``server._resolve_provider_signin``).

    Fails closed: unconfigured audience ⇒ 503; any signature/issuer/audience/
    expiry failure ⇒ 401, before any account state is touched.
    """
    client_id = os.environ.get("APPLE_WEB_CLIENT_ID")
    if not client_id:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE, "Apple web sign-in not configured"
        )
    try:
        header = jwt.get_unverified_header(identity_token)
        jwk = await _apple_jwks.get_key(header["kid"])
        claims = _decode_with_jwk(identity_token, jwk, audience=client_id, issuer=APPLE_ISSUER)
    except jwt.PyJWTError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, f"invalid Apple identity token: {exc}")
    return IdentityClaims(
        sub=claims["sub"],
        email=claims.get("email"),
        nonce=claims.get("nonce"),
        email_verified=_claim_email_verified(claims),
    )


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
    return IdentityClaims(
        sub=claims["sub"],
        email=claims.get("email"),
        email_verified=_claim_email_verified(claims),
    )


async def verify_google_web_id_token(id_token: str) -> IdentityClaims:
    """Verify a Google ID token from the WEB "Sign in with Google" flow that the
    website OWNS (Tono-owned Web OAuth client), replacing the Supabase-brokered
    path whose consent screen showed the shared project.

    Identical cryptography to the native path — same Google JWKS, same RS256/ES256,
    same issuer — but the audience is the Tono **Web** client id
    (``GOOGLE_WEB_CLIENT_ID``) rather than the native app's client id
    (``GOOGLE_CLIENT_ID``). Two audiences on two verifiers means a native-audience
    token can never satisfy the web endpoint and vice versa, while both resolve to
    the SAME stable Google ``sub`` — so native and web Google sign-ins converge on
    one canonical account (see ``server._resolve_provider_signin``).

    Captures ``nonce`` (the web flow sends one) for the caller's defense-in-depth
    check. Fails closed: unconfigured audience ⇒ 503; any signature/issuer/
    audience/expiry failure ⇒ 401, before any account state is touched.
    """
    client_id = os.environ.get("GOOGLE_WEB_CLIENT_ID")
    if not client_id:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE, "Google web sign-in not configured"
        )
    try:
        header = jwt.get_unverified_header(id_token)
        jwk = await _google_jwks.get_key(header["kid"])
        claims = _decode_with_jwk(id_token, jwk, audience=client_id, issuer=list(GOOGLE_ISSUERS))
    except jwt.PyJWTError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, f"invalid Google ID token: {exc}")
    return IdentityClaims(
        sub=claims["sub"],
        email=claims.get("email"),
        nonce=claims.get("nonce"),
        email_verified=_claim_email_verified(claims),
    )


# ---------------------------------------------------------------------------
# FastAPI dependency indirection — override these (not the verify_* functions
# above) in tests via app.dependency_overrides.
# ---------------------------------------------------------------------------


def get_apple_verifier() -> IdentityVerifier:
    return verify_apple_identity_token


def get_apple_web_verifier() -> IdentityVerifier:
    return verify_apple_web_identity_token


def get_google_verifier() -> IdentityVerifier:
    return verify_google_id_token


def get_google_web_verifier() -> IdentityVerifier:
    return verify_google_web_id_token
