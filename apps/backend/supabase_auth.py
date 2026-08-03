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

Email-confirmation authority — why a signature is not enough:
  A real Supabase password (and OAuth) access token does NOT carry a
  top-level ``email_verified`` claim. GoTrue puts ``email_verified`` only
  inside ``user_metadata``, which is user-writable and therefore never
  trusted here. So a cryptographically valid token, on its own, cannot tell
  us whether the address was actually confirmed. When the token carries no
  GoTrue-controlled in-token verdict (top-level ``email_verified`` or the
  service-role-only ``app_metadata.email_verified``), we ask GoTrue itself:
  an authenticated ``GET {SUPABASE_URL}/auth/v1/user`` returns the
  service-owned ``email_confirmed_at``, which a user cannot set. We call it
  with the token's OWN bearer, then fail CLOSED unless the response is a
  well-formed record whose subject (and email, when the token carries one)
  match the claims we just verified. A provider outage, a malformed body, or
  any subject/email inconsistency raises — it never yields a "verified".
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass, replace
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
    # GoTrue's authenticated user record, used to read the service-owned
    # ``email_confirmed_at`` when a token carries no in-token verified claim.
    # Prefer the project base URL; fall back to the issuer only when it is the
    # sole thing configured (JWKS-only setups). ``SUPABASE_USER_URL`` overrides.
    user_url = (
        os.environ.get("SUPABASE_USER_URL")
        or (f"{supabase_url}/auth/v1/user" if supabase_url else None)
        or (f"{issuer}/user" if issuer else None)
    )
    # Hosted Supabase fronts GoTrue with a gateway that requires the project
    # (anon/publishable) key to route. Same env names email_auth already reads,
    # so one project config drives both.
    api_key = (
        os.environ.get("SUPABASE_ANON_KEY")
        or os.environ.get("SUPABASE_PUBLISHABLE_KEY")
        or os.environ.get("SUPABASE_KEY")
    )
    return {
        "jwks_url": jwks_url,
        "issuer": issuer,
        "audience": os.environ.get("SUPABASE_AUD") or _DEFAULT_AUDIENCE,
        "hs_secret": os.environ.get("SUPABASE_JWT_SECRET"),
        "user_url": user_url,
        "api_key": api_key,
    }


def config_is_valid() -> bool:
    """True when at least one verification path is fully configured. Used by
    startup diagnostics — an env with none of these can never verify a web
    sign-in and /v1/auth/web will 503.

    HS256 additionally requires a resolvable issuer: an HS256 secret with no
    issuer is treated as NOT configured because ``verify_supabase_access_token``
    fails closed on it (an issuer-less symmetric decode is a forgery vector).
    JWKS mode needs only a JWKS URL — its keys are project-bound."""
    cfg = _config()
    if cfg["jwks_url"]:
        return True
    return bool(cfg["hs_secret"] and cfg["issuer"])


def _extract_claims(payload: dict) -> SupabaseClaims:
    if payload.get("is_anonymous") is True:
        # An anonymous Supabase user carries no verified identity; refuse so
        # it can never mint or merge a canonical account.
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "anonymous Supabase session not allowed")
    sub = payload.get("sub")
    if not sub:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Supabase token missing sub")
    email = payload.get("email")
    # Verification authority — GoTrue-controlled evidence ONLY.
    #
    # ``user_metadata`` (GoTrue's ``raw_user_meta_data``) is USER-WRITABLE: any
    # signed-in user can set arbitrary keys through ``auth.updateUser({ data })``.
    # Reading ``user_metadata.email_verified`` therefore let a user FORGE verified
    # status and, downstream, attach their identity to a stranger's canonical
    # account by claiming that stranger's address (see
    # server._resolve_provider_signin's verified-email convergence). We now trust
    # only the two sources GoTrue itself controls:
    #   * the TOP-LEVEL ``email_verified`` claim, which GoTrue mints from
    #     ``users.email_confirmed_at`` and a user cannot set; and
    #   * ``app_metadata`` (``raw_app_meta_data``), writable only with the
    #     service role — never by the end user.
    # ``user_metadata`` is deliberately NOT consulted. If neither authoritative
    # source is present we default to UNVERIFIED (fail closed), which at worst
    # withholds convergence — never grants it on unproven input.
    app_meta = payload.get("app_metadata") or {}
    verified = bool(payload.get("email_verified") or app_meta.get("email_verified"))
    return SupabaseClaims(sub=str(sub), email=email, email_verified=verified)


async def verify_supabase_access_token(access_token: str) -> SupabaseClaims:
    cfg = _config()
    audience = cfg["audience"]

    if cfg["hs_secret"]:
        # Legacy symmetric mode. An HS256 secret with NO issuer would verify
        # only the signature and audience, accepting any HS256 token minted
        # with the same shared secret regardless of which Supabase project /
        # issuer produced it. That is a decode-without-issuer weakness, so we
        # fail CLOSED here rather than skip the ``iss`` check. Configure
        # SUPABASE_ISSUER (or SUPABASE_URL, which derives the issuer) to enable
        # HS256 verification. JWKS mode is unaffected — its keys are bound to a
        # single project's published key set, so it never reaches this branch.
        if not cfg["issuer"]:
            raise HTTPException(
                status.HTTP_503_SERVICE_UNAVAILABLE,
                "Supabase HS256 mode requires an issuer "
                "(set SUPABASE_ISSUER or SUPABASE_URL)",
            )
        try:
            payload = jwt.decode(
                access_token,
                key=cfg["hs_secret"],
                algorithms=["HS256"],
                audience=audience,
                issuer=cfg["issuer"],
                options={"verify_iss": True, "require": ["iss"]},
            )
        except jwt.PyJWTError as exc:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, f"invalid Supabase token: {exc}")

    elif cfg["jwks_url"]:
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

    else:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "Supabase web sign-in is not configured (set SUPABASE_URL or SUPABASE_JWT_SECRET)",
        )

    # Signature/issuer/audience are now proven. Extract the in-token verdict,
    # then — only when the token carried no GoTrue-controlled email verdict —
    # let GoTrue's own user record settle confirmation (see below).
    claims = _extract_claims(payload)
    return await _resolve_email_verification(cfg, access_token, payload, claims)


async def _resolve_email_verification(
    cfg: dict[str, Optional[str]],
    access_token: str,
    payload: dict,
    claims: SupabaseClaims,
) -> SupabaseClaims:
    """Settle ``email_verified`` for a cryptographically-verified token.

    Fast path (unchanged behaviour, and the only path the HS256/JWKS unit tests
    take, since their tokens embed the claim): if the token itself carried a
    GoTrue-controlled verdict — a top-level ``email_verified`` key, or the
    service-role-only ``app_metadata.email_verified`` — we trust
    ``_extract_claims``' result and make no second call. A key that is present
    and *false* is still authoritative and is honoured as such.

    Slow path (the real Supabase password/OAuth token, which omits the top-level
    claim entirely): consult GoTrue's authenticated user record for the
    service-owned ``email_confirmed_at``. Only reached when the token also
    carries an ``email`` — with no address there is nothing to converge on and
    the pre-existing ``email_verified=False`` result is returned untouched.
    """
    if claims.email is None:
        return claims
    app_meta = payload.get("app_metadata")
    in_token_authority = ("email_verified" in payload) or (
        isinstance(app_meta, dict) and "email_verified" in app_meta
    )
    if in_token_authority:
        return claims
    confirmed = await _authoritative_email_confirmed(
        cfg, access_token, expected_sub=claims.sub, expected_email=claims.email
    )
    return replace(claims, email_verified=confirmed)


async def _http_get_supabase_user(url: str, headers: dict[str, str]) -> httpx.Response:
    """The single authenticated GET of GoTrue's user record.

    Isolated behind its own name so contract tests can substitute a
    Supabase-shaped response without a network path — the same seam philosophy
    as ``get_supabase_verifier``. Raises ``httpx.HTTPError`` on transport
    failure, which the caller converts into a fail-closed 503."""
    async with httpx.AsyncClient(timeout=10) as client:
        return await client.get(url, headers=headers)


async def _authoritative_email_confirmed(
    cfg: dict[str, Optional[str]],
    access_token: str,
    *,
    expected_sub: str,
    expected_email: str,
) -> bool:
    """Return whether GoTrue itself considers this token's address confirmed.

    Calls ``GET {SUPABASE_URL}/auth/v1/user`` with the token's OWN bearer and
    reads the service-owned ``email_confirmed_at``. Everything here fails
    CLOSED — an unreachable/erroring/malformed provider, or a response whose
    subject or email does not match the claims we cryptographically verified,
    raises rather than yielding a "verified". ``user_metadata`` in the response
    is never consulted."""
    user_url = cfg["user_url"]
    if not user_url:
        # No way to reach the one source that can prove confirmation, so we must
        # not assert it. Fail closed rather than silently deny a real person.
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "Supabase user endpoint is not configured (set SUPABASE_URL)",
        )
    headers = {"Authorization": f"Bearer {access_token}"}
    if cfg["api_key"]:
        headers["apikey"] = cfg["api_key"]
    try:
        response = await _http_get_supabase_user(user_url, headers)
    except httpx.HTTPError:
        # The transport exception's string can carry the project host; never
        # surface or chain it. Fail closed.
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "Supabase user endpoint unreachable",
        ) from None
    if response.status_code in (401, 403):
        # GoTrue rejected the very token we just verified — treat as
        # unauthenticated, never as verified.
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Supabase rejected access token")
    if response.status_code >= 300:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE, "Supabase user endpoint error"
        )
    try:
        data = response.json()
    except ValueError:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "Supabase user endpoint returned a malformed body",
        ) from None
    if not isinstance(data, dict):
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "Supabase user endpoint returned a malformed body",
        )
    # Consistency (fail closed): the authoritative record MUST describe the same
    # subject we verified, or we would read a stranger's confirmation state.
    if str(data.get("id") or "") != str(expected_sub):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Supabase user subject mismatch")
    # ...and the same address the token carried (case-insensitively), or we
    # would confirm one address using another's status.
    record_email = data.get("email")
    if (
        not record_email
        or str(record_email).strip().lower() != expected_email.strip().lower()
    ):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Supabase user email mismatch")
    # ``email_confirmed_at`` (and its legacy alias ``confirmed_at``) is a
    # GoTrue-owned timestamp, set only once ownership was proven and unwritable
    # by the end user. Non-null => confirmed.
    confirmed_at = data.get("email_confirmed_at") or data.get("confirmed_at")
    return bool(confirmed_at)


# ---------------------------------------------------------------------------
# FastAPI dependency indirection — override this (not verify_* above) in
# tests via app.dependency_overrides.
# ---------------------------------------------------------------------------


def get_supabase_verifier() -> SupabaseVerifier:
    return verify_supabase_access_token
