"""Supabase access-token verification for canonical web account sign-in.

The web app authenticates a person with Supabase (Apple/Google OAuth or
magic-link). Supabase issues a signed access token (a JWT). The web
callback forwards that token to ``POST /v1/auth/web``; we verify its
signature, issuer and audience here, then trust the ``sub`` claim as the
stable per-person Supabase user id (the "provider subject") and the
``email`` claim ONLY when Supabase marks it verified.

Why this mirrors ``social_auth.py`` (Apple/Google identity tokens):
  - Same trust model: verify a provider-signed JWT against a published
    JWKS (or a configured shared secret), never a decode-only path.
  - Same testability seam: ``server.py`` depends on
    ``get_supabase_verifier`` (not ``verify_supabase_access_token``
    directly), so tests override it via ``app.dependency_overrides`` and
    need no network path to the Supabase JWKS endpoint.

Two signing modes, matching the two Supabase eras:
  - Asymmetric (current default): RS256/ES256, keys published at
    ``{SUPABASE_URL}/auth/v1/.well-known/jwks.json``. Configure
    ``SUPABASE_URL`` (or ``SUPABASE_JWKS_URL`` + ``SUPABASE_ISSUER``).
  - Symmetric (legacy): HS256 with the project JWT secret. Configure
    ``SUPABASE_JWT_SECRET`` (and ``SUPABASE_ISSUER`` for iss checking).

Both fail CLOSED: if nothing is configured we raise 503, never a
decode-without-verify fallback. Audience defaults to ``authenticated``
(Supabase's audience for signed-in users), overridable via
``SUPABASE_AUD``.
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass
from typing import Any, Callable, Optional

import httpx
import jwt
from fastapi import HTTPException, status

_JWKS_TTL_SECONDS = 3600
_DEFAULT_AUDIENCE = "authenticated"
_ASYMMETRIC_ALGS = ["RS256", "ES256"]


@dataclass
class SupabaseClaims:
    """The subset of a verified Supabase access token we act on.

    ``sub`` is the Supabase user id — stable per person across browsers
    and providers (Supabase dedupes identities onto one user by verified
    email), which is exactly what makes "same person, fresh browser"
    converge to one canonical account. ``email`` is populated ONLY when
    ``email_verified`` is true, so an unverified address can never drive a
    merge (see server._resolve_provider_signin)."""

    sub: str
    email: Optional[str] = None
    email_verified: bool = False


SupabaseVerifier = Callable[[str], "Any"]  # async (token: str) -> SupabaseClaims


class _JwksCache:
    """In-memory JWKS cache with a 1-hour TTL, matching social_auth's cache.
    Supabase publishes overlapping old+new keys during rotation, so a
    slightly-stale cache never breaks verification."""

    def __init__(self, url: str):
        self.url = url
        self._keys: dict[str, dict] = {}
        self._fetched_at: float = 0.0

    async def get_key(self, kid: str) -> dict:
        if not self._keys or (time.time() - self._fetched_at) > _JWKS_TTL_SECONDS:
            await self._refresh()
        key = self._keys.get(kid)
        if not key:
            # kid unknown even after TTL check — force one refresh in case
            # Supabase rotated signing keys since our last fetch.
            await self._refresh()
            key = self._keys.get(kid)
        if not key:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "unknown Supabase signing key")
        return key

    async def _refresh(self) -> None:
        async with httpx.AsyncClient(timeout=10) as c:
            r = await c.get(self.url)
            r.raise_for_status()
            data = r.json()
        self._keys = {k["kid"]: k for k in data.get("keys", []) if k.get("kid")}
        self._fetched_at = time.time()


# One process-wide cache, keyed by resolved JWKS URL so a config change
# (rare) rebuilds it rather than serving stale keys from another project.
_jwks_caches: dict[str, _JwksCache] = {}


def _jwks_cache_for(url: str) -> _JwksCache:
    cache = _jwks_caches.get(url)
    if cache is None:
        cache = _JwksCache(url)
        _jwks_caches[url] = cache
    return cache


def _config() -> dict[str, Optional[str]]:
    """Resolve Supabase verification config from the environment.

    Fails closed at call time (503) if neither an asymmetric nor a
    symmetric verification path is configured — we never fall back to an
    unverified decode."""
    supabase_url = (os.environ.get("SUPABASE_URL") or "").rstrip("/")
    jwks_url = os.environ.get("SUPABASE_JWKS_URL") or (
        f"{supabase_url}/auth/v1/.well-known/jwks.json" if supabase_url else None
    )
    issuer = os.environ.get("SUPABASE_ISSUER") or (
        f"{supabase_url}/auth/v1" if supabase_url else None
    )
    return {
        "jwks_url": jwks_url,
        "issuer": issuer,
        "audience": os.environ.get("SUPABASE_AUD") or _DEFAULT_AUDIENCE,
        "hs_secret": os.environ.get("SUPABASE_JWT_SECRET"),
    }


def config_is_valid() -> bool:
    """True when at least one verification path is fully configured. Used by
    startup diagnostics — an env with none of these can never verify a web
    sign-in and /v1/auth/web will 503."""
    cfg = _config()
    return bool(cfg["hs_secret"] or cfg["jwks_url"])


def _extract_claims(payload: dict) -> SupabaseClaims:
    if payload.get("is_anonymous") is True:
        # An anonymous Supabase user carries no verified identity; refuse so
        # it can never mint or merge a canonical account.
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "anonymous Supabase session not allowed")
    sub = payload.get("sub")
    if not sub:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Supabase token missing sub")
    email = payload.get("email")
    meta = payload.get("user_metadata") or {}
    # Supabase surfaces the verified flag either top-level or under
    # user_metadata depending on provider/version — treat either truthy
    # value as verified, and default to UNVERIFIED when absent (fail closed).
    verified = bool(payload.get("email_verified") or meta.get("email_verified"))
    return SupabaseClaims(sub=str(sub), email=email, email_verified=verified)


async def verify_supabase_access_token(access_token: str) -> SupabaseClaims:
    cfg = _config()
    audience = cfg["audience"]

    if cfg["hs_secret"]:
        # Legacy symmetric mode.
        try:
            payload = jwt.decode(
                access_token,
                key=cfg["hs_secret"],
                algorithms=["HS256"],
                audience=audience,
                issuer=cfg["issuer"] if cfg["issuer"] else None,
                options={"verify_iss": bool(cfg["issuer"])},
            )
        except jwt.PyJWTError as exc:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, f"invalid Supabase token: {exc}")
        return _extract_claims(payload)

    if cfg["jwks_url"]:
        try:
            header = jwt.get_unverified_header(access_token)
            jwk = await _jwks_cache_for(cfg["jwks_url"]).get_key(header.get("kid", ""))
            alg = jwk.get("alg")
            algorithms = [alg] if alg in _ASYMMETRIC_ALGS else _ASYMMETRIC_ALGS
            public_key = jwt.PyJWK(jwk).key
            payload = jwt.decode(
                access_token,
                key=public_key,
                algorithms=algorithms,
                audience=audience,
                issuer=cfg["issuer"] if cfg["issuer"] else None,
                options={"verify_iss": bool(cfg["issuer"])},
            )
        except jwt.PyJWTError as exc:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, f"invalid Supabase token: {exc}")
        return _extract_claims(payload)

    raise HTTPException(
        status.HTTP_503_SERVICE_UNAVAILABLE,
        "Supabase web sign-in is not configured (set SUPABASE_URL or SUPABASE_JWT_SECRET)",
    )


# ---------------------------------------------------------------------------
# FastAPI dependency indirection — override this (not verify_* above) in
# tests via app.dependency_overrides.
# ---------------------------------------------------------------------------


def get_supabase_verifier() -> SupabaseVerifier:
    return verify_supabase_access_token
