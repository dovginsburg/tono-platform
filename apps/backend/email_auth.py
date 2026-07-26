"""Server-side email/password auth against the Supabase Auth REST API.

Build 114. Tono adds email registration WITHOUT becoming a second identity
store: Supabase keeps owning ``auth.users``, the password material and the
verification/reset mail, and this module is the only place that talks to it.
The canonical account (``accounts.id``) stays this server's own concept, and
``server._resolve_provider_signin`` remains the single primitive that binds a
provider subject to it — so an email login converges on exactly the same
canonical person an Apple/Google/web sign-in would.

Why the backend brokers this for iOS/Android instead of embedding a Supabase
client in Swift/Kotlin:

  * The native apps never handle a fragment token, a provider refresh token,
    or a project key. They exchange an email+password for one ordinary Tono
    bearer, which is the credential they already know how to store in the
    Keychain / EncryptedSharedPreferences.
  * Verification and reset stay LINK-based and provider-owned. The link opens
    the web callback (authorization-code/PKCE), never a native URL carrying a
    secret.
  * There is exactly one entitlement projector. A brokered login lands in the
    same ``/v1/auth`` path as every other identity, so a subscription bought
    on any surface follows the person.

Everything here fails CLOSED. If the project is not configured we raise 503
rather than degrade to an unverified path, mirroring ``supabase_auth.py``.

Privacy contract enforced by this module:
  * No password, token, email address, request body or provider response body
    is ever logged, raised, or attached to an exception. Callers receive an
    ``EmailAuthOutcome`` enum and, on success, only the fields they need.
  * ``EmailAuthError`` carries an outcome, never provider text. Consumer copy
    is derived from the outcome alone (see ``server._email_auth_failure``).
"""

from __future__ import annotations

import enum
import os
from dataclasses import dataclass
from typing import Any, Callable, Optional

import httpx
from fastapi import HTTPException, status

_TIMEOUT_SECONDS = 15.0


class EmailAuthOutcome(str, enum.Enum):
    """Every distinct consumer-visible behaviour this path can produce.

    Kept deliberately small and shape-based (never message-based): the
    consumer copy mapper switches on these and nothing else, so no provider
    string can ever reach a screen.
    """

    OK = "ok"
    #: Credentials were rejected. Callers MUST NOT reveal whether the address
    #: exists — see ``server`` for the anti-enumerating responses.
    INVALID_CREDENTIALS = "invalid_credentials"
    #: The provider refused the submitted PASSWORD on its own strength rules.
    #: Distinct from INVALID_CREDENTIALS because it is a fact about the string
    #: the person just typed, not about any account — so answering it plainly
    #: enumerates nothing, and swallowing it strands them (see below).
    WEAK_PASSWORD = "weak_password"
    #: The provider refused the submitted ADDRESS (its own validator, or a
    #: domain the project does not accept). Also a fact about the input.
    INVALID_EMAIL = "invalid_email"
    #: The address exists but ownership has not been proven yet.
    VERIFICATION_REQUIRED = "verification_required"
    #: The provider throttled us (or the person). Wait and retry — never a
    #: paywall, never a credential failure.
    RATE_LIMITED = "rate_limited"
    #: The project is not configured for email auth at all.
    NOT_CONFIGURED = "not_configured"
    #: The provider was unreachable or answered with an infrastructure error.
    #: Crucially this is NOT "we sent you an email" — see the callers.
    PROVIDER_UNAVAILABLE = "provider_unavailable"


class EmailAuthError(Exception):
    """A non-OK outcome. Deliberately carries no provider text.

    The absence of a message field is the point: there is no way for a caller
    to accidentally render provider detail, because the object never holds any.
    """

    def __init__(self, outcome: EmailAuthOutcome):
        super().__init__(outcome.value)
        self.outcome = outcome


@dataclass(frozen=True)
class EmailAuthSession:
    """A provider session. ``access_token`` is handed straight to the existing
    Supabase verifier so the ``sub``/``email_verified`` claims are checked
    cryptographically before any account state moves — a brokered login is
    never trusted just because the broker made the call."""

    access_token: str
    refresh_token: Optional[str] = None
    expires_in: Optional[int] = None


@dataclass(frozen=True)
class EmailSignUpResult:
    """Outcome of a registration attempt.

    ``verification_required`` is the normal case for a correctly configured
    project (Supabase withholds a session until the address is confirmed).
    ``session`` is populated only when a project has confirmations disabled;
    the caller still refuses to treat that as verified, so a misconfigured
    project cannot silently skip verification.

    ``provider_user_id`` is the provider's own immutable subject for the user
    the signup just created. Supabase returns it even when it withholds a
    session, and it is the single fact that makes an anonymous upgrade actually
    hold: the caller records it against the canonical account BEFORE
    verification, so whichever surface completes the verification (the web
    callback, or a native login) resolves the SAME canonical person instead of
    minting a second one. See ``server._record_email_registration_intent``.

    It is a public, opaque identifier — not a credential. It grants nothing on
    its own: the account stays unidentified until an address is proven, and
    every entitlement still reads plan/subscription/grant.
    """

    verification_required: bool
    session: Optional[EmailAuthSession] = None
    provider_user_id: Optional[str] = None


def _config() -> dict[str, Optional[str]]:
    base = (os.environ.get("SUPABASE_URL") or "").rstrip("/")
    key = (
        os.environ.get("SUPABASE_ANON_KEY")
        or os.environ.get("SUPABASE_PUBLISHABLE_KEY")
        or os.environ.get("SUPABASE_KEY")
    )
    return {"base": base or None, "key": key or None}


def config_is_valid() -> bool:
    """True when email auth can actually run. Used by startup diagnostics so a
    missing key is visible at boot rather than at a person's first signup."""
    cfg = _config()
    return bool(cfg["base"] and cfg["key"])


def _redirect_base() -> str:
    """Where a verification / reset link lands. Always the web callback, which
    runs the authorization-code exchange; never a native scheme carrying a
    secret. Configurable so staging points at staging."""
    return (
        os.environ.get("TONO_AUTH_REDIRECT_URL")
        or "https://tonoit.com/app/auth/callback"
    )


class SupabaseEmailAuthClient:
    """Thin, fail-closed wrapper over the Supabase Auth REST endpoints."""

    def __init__(self, base: str, key: str):
        self._base = base
        self._key = key

    # -- helpers ---------------------------------------------------------

    def _headers(self, bearer: Optional[str] = None) -> dict[str, str]:
        return {
            "apikey": self._key,
            "Authorization": f"Bearer {bearer or self._key}",
            "Content-Type": "application/json",
        }

    @staticmethod
    def _classify(response: httpx.Response) -> EmailAuthOutcome:
        """Map a provider response to an outcome using status class plus the
        provider's stable machine-readable ``error_code``. The human ``msg``
        is never consulted and never propagated."""
        if response.status_code < 300:
            return EmailAuthOutcome.OK
        if response.status_code == 429:
            return EmailAuthOutcome.RATE_LIMITED
        if response.status_code >= 500:
            return EmailAuthOutcome.PROVIDER_UNAVAILABLE

        code = ""
        try:
            payload = response.json()
            if isinstance(payload, dict):
                code = str(
                    payload.get("error_code") or payload.get("error") or ""
                ).lower()
        except ValueError:
            code = ""

        if "not_confirmed" in code or "email_not_confirmed" in code:
            return EmailAuthOutcome.VERIFICATION_REQUIRED
        if "over_email_send_rate" in code or "rate_limit" in code:
            return EmailAuthOutcome.RATE_LIMITED
        # Input-shaped refusals, matched on the provider's stable error_code
        # only. These have to stay distinct from INVALID_CREDENTIALS because
        # register/resend/reset answer INVALID_CREDENTIALS with the
        # anti-enumerating "check your email" — correct for "already
        # registered", a dead end for these. A project that requires a digit or
        # a symbol, or whose validator rejects the domain, would otherwise send
        # the person to an inbox that never receives anything, with nothing to
        # act on and no way to discover why.
        #
        # Reporting them enumerates nothing: both describe the string just
        # submitted, which the person can already see, and neither varies with
        # whether an account exists.
        if "weak_password" in code:
            return EmailAuthOutcome.WEAK_PASSWORD
        if (
            "email_address_invalid" in code
            or "email_address_not_authorized" in code
            or "validation_failed" in code
        ):
            return EmailAuthOutcome.INVALID_EMAIL
        # Signups turned off project-wide is an operational fact, not a
        # credential one. Anything but 503 here would report an outage as
        # delivery — the exact confusion this module refuses to make.
        if "signup_disabled" in code or "not_admin" in code:
            return EmailAuthOutcome.PROVIDER_UNAVAILABLE
        return EmailAuthOutcome.INVALID_CREDENTIALS

    async def _post(
        self,
        path: str,
        *,
        json_body: dict[str, Any],
        params: Optional[dict[str, str]] = None,
        bearer: Optional[str] = None,
    ) -> httpx.Response:
        try:
            async with httpx.AsyncClient(timeout=_TIMEOUT_SECONDS) as client:
                return await client.post(
                    f"{self._base}{path}",
                    json=json_body,
                    params=params,
                    headers=self._headers(bearer),
                )
        except httpx.HTTPError:
            # Deliberately swallows the transport exception rather than
            # chaining it: its string carries the project host, and on some
            # failures the request line. Neither may reach a caller or a log.
            raise EmailAuthError(EmailAuthOutcome.PROVIDER_UNAVAILABLE)

    @staticmethod
    def _provider_user_id_from(response: httpx.Response) -> Optional[str]:
        """The provider subject carried by a signup response.

        Supabase answers a confirmation-required signup with the bare user
        object (``{"id": ..., "email": ..., "confirmation_sent_at": ...}``) and
        a session-issuing signup with ``{"access_token": ..., "user": {...}}``.
        Both shapes are read here so no caller has to know which one a project
        produced.

        Returns None rather than raising for anything unexpected: a missing
        subject degrades the anonymous upgrade to the pre-existing behaviour,
        which must never be an outright registration failure.
        """
        try:
            payload = response.json()
        except ValueError:
            return None
        if not isinstance(payload, dict):
            return None
        candidate = payload.get("id")
        if not candidate:
            user = payload.get("user")
            if isinstance(user, dict):
                candidate = user.get("id")
        if not candidate:
            return None
        subject = str(candidate).strip()
        # Bounded: this value is written to an indexed identity column, so an
        # unbounded provider string is not accepted on trust.
        return subject if 0 < len(subject) <= 128 else None

    @staticmethod
    def _session_from(response: httpx.Response) -> Optional[EmailAuthSession]:
        try:
            payload = response.json()
        except ValueError:
            return None
        if not isinstance(payload, dict):
            return None
        token = payload.get("access_token")
        if not token:
            return None
        return EmailAuthSession(
            access_token=str(token),
            refresh_token=payload.get("refresh_token"),
            expires_in=payload.get("expires_in"),
        )

    # -- operations ------------------------------------------------------

    async def sign_up(self, *, email: str, password: str) -> EmailSignUpResult:
        """Create the provider user and let the provider mail the link.

        We never mint or store the verification token; it exists only inside
        the provider and the person's inbox.
        """
        response = await self._post(
            "/auth/v1/signup",
            json_body={
                "email": email,
                "password": password,
                # Supabase honours this as the confirmation link target.
                "options": {"email_redirect_to": _redirect_base()},
            },
            params={"redirect_to": _redirect_base()},
        )
        outcome = self._classify(response)
        if outcome is not EmailAuthOutcome.OK:
            raise EmailAuthError(outcome)
        session = self._session_from(response)
        return EmailSignUpResult(
            verification_required=session is None,
            session=session,
            provider_user_id=self._provider_user_id_from(response),
        )

    async def sign_in(self, *, email: str, password: str) -> EmailAuthSession:
        response = await self._post(
            "/auth/v1/token",
            json_body={"email": email, "password": password},
            params={"grant_type": "password"},
        )
        outcome = self._classify(response)
        if outcome is not EmailAuthOutcome.OK:
            raise EmailAuthError(outcome)
        session = self._session_from(response)
        if session is None:
            # A 2xx with no token is not a login. Fail closed rather than
            # treating an unparsable success as an authenticated person.
            raise EmailAuthError(EmailAuthOutcome.PROVIDER_UNAVAILABLE)
        return session

    async def resend_verification(self, *, email: str) -> None:
        response = await self._post(
            "/auth/v1/resend",
            json_body={"type": "signup", "email": email},
            params={"redirect_to": _redirect_base()},
        )
        outcome = self._classify(response)
        if outcome is not EmailAuthOutcome.OK:
            raise EmailAuthError(outcome)

    async def request_password_reset(self, *, email: str) -> None:
        response = await self._post(
            "/auth/v1/recover",
            json_body={"email": email},
            params={"redirect_to": _redirect_base()},
        )
        outcome = self._classify(response)
        if outcome is not EmailAuthOutcome.OK:
            raise EmailAuthError(outcome)

    async def refresh(self, *, refresh_token: str) -> EmailAuthSession:
        response = await self._post(
            "/auth/v1/token",
            json_body={"refresh_token": refresh_token},
            params={"grant_type": "refresh_token"},
        )
        outcome = self._classify(response)
        if outcome is not EmailAuthOutcome.OK:
            raise EmailAuthError(outcome)
        session = self._session_from(response)
        if session is None:
            raise EmailAuthError(EmailAuthOutcome.PROVIDER_UNAVAILABLE)
        return session

    async def sign_out(self, *, access_token: str) -> None:
        """Best-effort revocation of the PROVIDER session.

        Tono's own bearer is rotated by the caller regardless of what happens
        here — local sign-out must never depend on a reachable provider, or a
        person on a bad network could not log out of a shared device.
        """
        response = await self._post(
            "/auth/v1/logout", json_body={}, bearer=access_token
        )
        outcome = self._classify(response)
        if outcome is not EmailAuthOutcome.OK:
            raise EmailAuthError(outcome)


# ---------------------------------------------------------------------------
# FastAPI dependency indirection — override THIS in tests via
# app.dependency_overrides, exactly like social_auth/supabase_auth. Tests never
# need a network path, and production never gets a decode-only fallback.
# ---------------------------------------------------------------------------

EmailAuthClientFactory = Callable[[], "SupabaseEmailAuthClient"]


def get_email_auth_client() -> SupabaseEmailAuthClient:
    cfg = _config()
    if not cfg["base"] or not cfg["key"]:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "email sign-in is not configured",
        )
    return SupabaseEmailAuthClient(cfg["base"], cfg["key"])
