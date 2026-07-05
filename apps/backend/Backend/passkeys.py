"""Passkey (WebAuthn) registration + login.

This is the actual mechanism behind "sign in with Face ID / Touch ID /
Windows Hello / Android fingerprint" on web and desktop: the browser or OS
shows the biometric prompt and hands us back a cryptographically signed
assertion. We never see, receive, or store any biometric data — only a
public key and a signature, the same trust model as SSH keys.

Two ceremonies, each split into an "options" step (we hand the client a
challenge) and a "verify" step (the client sends back what the
authenticator signed):

  POST /v1/auth/passkey/register/options  (authenticated device)
  POST /v1/auth/passkey/register/verify   (authenticated device)
  POST /v1/auth/passkey/login/options     (public — this is how sign-in starts)
  POST /v1/auth/passkey/login/verify      (authenticated device — see note below)

Registering with no existing account creates one on the spot — a passkey
can be someone's first and only sign-in method, not just an add-on to
Apple/Google.

Why login/verify still requires CurrentUser: every other sign-in endpoint
in server.py (Apple, Google) takes a bearer token for the calling device
and links it to whatever account the identity resolves to — passkey login
follows the same shape for consistency, so the client flow is always
"register a device (`POST /v1/register`) once, then authenticate however
you like." It's not an extra step in practice: no client can call
`/api/analyze` or anything else without a device token anyway.
"""

from __future__ import annotations

import json
import os
from typing import Optional

from fastapi import APIRouter, HTTPException, status
from fastapi.responses import Response
from pydantic import BaseModel
from webauthn import (
    generate_authentication_options,
    generate_registration_options,
    options_to_json,
    verify_authentication_response,
    verify_registration_response,
)
from webauthn.helpers import base64url_to_bytes, bytes_to_base64url
from webauthn.helpers.exceptions import InvalidAuthenticationResponse, InvalidRegistrationResponse
from webauthn.helpers.structs import (
    AuthenticatorSelectionCriteria,
    PublicKeyCredentialDescriptor,
    ResidentKeyRequirement,
    UserVerificationRequirement,
)

from .auth import CurrentUser, StoreDep
from .redis_client import get_redis

router = APIRouter(prefix="/v1/auth/passkey", tags=["passkeys"])

_CHALLENGE_TTL_SECONDS = 300


def _rp_id() -> str:
    return os.environ.get("WEBAUTHN_RP_ID", "localhost")


def _rp_name() -> str:
    return os.environ.get("WEBAUTHN_RP_NAME", "Tono")


def _expected_origins() -> list[str]:
    raw = os.environ.get("WEBAUTHN_ORIGIN", "http://localhost:3300")
    return [o.strip() for o in raw.split(",") if o.strip()]


# ---------------------------------------------------------------------------
# Challenge store — short-lived, single-use, Redis-backed. Used to live in a
# plain module-level dict, which is only correct with exactly one worker
# process; Redis's native TTL (SETEX) also replaces the manual
# expiry-timestamp bookkeeping the dict version needed.
# ---------------------------------------------------------------------------


async def _put_registration_challenge(device_id: str, challenge: bytes) -> None:
    await get_redis().setex(f"webauthn:reg:{device_id}", _CHALLENGE_TTL_SECONDS, challenge)


async def _pop_registration_challenge(device_id: str) -> bytes:
    r = get_redis()
    key = f"webauthn:reg:{device_id}"
    async with r.pipeline(transaction=True) as pipe:
        pipe.get(key)
        pipe.delete(key)
        value, _ = await pipe.execute()
    if not value:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "registration challenge expired or missing — call options again")
    return value


async def _put_login_challenge(challenge_b64: str) -> None:
    await get_redis().setex(f"webauthn:login:{challenge_b64}", _CHALLENGE_TTL_SECONDS, "1")


async def _pop_login_challenge(challenge_b64: str) -> None:
    deleted = await get_redis().delete(f"webauthn:login:{challenge_b64}")
    if not deleted:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "login challenge expired or missing — call options again")


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------


@router.post("/register/options")
async def passkey_register_options(user: CurrentUser, store: StoreDep):
    account = user.account
    if account is None:
        account = await store.create_bare_account()
        await store.link_device_to_account(user.device_id, account.id)

    existing = await store.list_webauthn_credentials(account.id)
    options = generate_registration_options(
        rp_id=_rp_id(),
        rp_name=_rp_name(),
        user_name=account.email or account.id,
        user_id=account.id.encode("utf-8"),
        user_display_name=account.email or "Tono account",
        exclude_credentials=[
            PublicKeyCredentialDescriptor(id=base64url_to_bytes(c.credential_id)) for c in existing
        ],
        authenticator_selection=AuthenticatorSelectionCriteria(
            resident_key=ResidentKeyRequirement.PREFERRED,
            user_verification=UserVerificationRequirement.PREFERRED,
        ),
    )
    await _put_registration_challenge(user.device_id, options.challenge)
    return Response(content=options_to_json(options), media_type="application/json")


class PasskeyRegisterVerifyRequest(BaseModel):
    credential: dict
    nickname: Optional[str] = None


class PasskeyRegisterVerifyResponse(BaseModel):
    account_id: str
    credential_id: str


@router.post("/register/verify", response_model=PasskeyRegisterVerifyResponse)
async def passkey_register_verify(
    body: PasskeyRegisterVerifyRequest, user: CurrentUser, store: StoreDep
) -> PasskeyRegisterVerifyResponse:
    if not user.account_id:
        # Shouldn't happen in the normal flow (options always creates one),
        # but a device could theoretically call verify without ever calling
        # options first.
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "call /register/options first")

    challenge = await _pop_registration_challenge(user.device_id)
    try:
        verification = verify_registration_response(
            credential=body.credential,
            expected_challenge=challenge,
            expected_rp_id=_rp_id(),
            expected_origin=_expected_origins(),
        )
    except InvalidRegistrationResponse as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, f"invalid passkey registration: {exc}")

    credential_id_b64 = bytes_to_base64url(verification.credential_id)
    await store.add_webauthn_credential(
        credential_id=credential_id_b64,
        account_id=user.account_id,
        public_key=verification.credential_public_key,
        sign_count=verification.sign_count,
        transports=body.credential.get("response", {}).get("transports"),
        nickname=body.nickname,
    )
    return PasskeyRegisterVerifyResponse(account_id=user.account_id, credential_id=credential_id_b64)


# ---------------------------------------------------------------------------
# Login
# ---------------------------------------------------------------------------


@router.post("/login/options")
async def passkey_login_options():
    """Public — no bearer token needed to *start* a passkey login. Uses
    discoverable credentials (no `allow_credentials` list), so the
    authenticator itself prompts the user to pick which passkey to use —
    we don't need to know who's signing in until they've done it."""
    options = generate_authentication_options(
        rp_id=_rp_id(),
        user_verification=UserVerificationRequirement.PREFERRED,
    )
    await _put_login_challenge(bytes_to_base64url(options.challenge))
    return Response(content=options_to_json(options), media_type="application/json")


class PasskeyLoginVerifyRequest(BaseModel):
    credential: dict


class PasskeyLoginVerifyResponse(BaseModel):
    account_id: str
    plan: str
    is_pro: bool
    email: Optional[str] = None


@router.post("/login/verify", response_model=PasskeyLoginVerifyResponse)
async def passkey_login_verify(
    body: PasskeyLoginVerifyRequest, user: CurrentUser, store: StoreDep
) -> PasskeyLoginVerifyResponse:
    client_data = body.credential.get("response", {}).get("clientDataJSON")
    if not client_data:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "malformed credential")

    challenge_b64 = json.loads(base64url_to_bytes(client_data))["challenge"]
    await _pop_login_challenge(challenge_b64)

    raw_credential_id = body.credential.get("rawId") or body.credential.get("id")
    credential_id_b64 = _normalize_credential_id(raw_credential_id)
    stored_credential = await store.get_webauthn_credential(credential_id_b64)
    if not stored_credential:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "unknown passkey")

    try:
        verification = verify_authentication_response(
            credential=body.credential,
            expected_challenge=base64url_to_bytes(challenge_b64),
            expected_rp_id=_rp_id(),
            expected_origin=_expected_origins(),
            credential_public_key=stored_credential.public_key,
            credential_current_sign_count=stored_credential.sign_count,
        )
    except InvalidAuthenticationResponse as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, f"invalid passkey assertion: {exc}")

    await store.update_webauthn_sign_count(credential_id_b64, verification.new_sign_count)

    # Passkey login is always a plain sign-in (never `link`) — see
    # server.py's _resolve_provider_signin for why link vs. plain sign-in
    # is a client-intent choice, not something inferable from the request.
    await store.link_device_to_account(user.device_id, stored_credential.account_id)
    account = await store.get_account(stored_credential.account_id)

    return PasskeyLoginVerifyResponse(
        account_id=account.id, plan=account.plan, is_pro=account.is_pro, email=account.email
    )


def _normalize_credential_id(raw_id: str) -> str:
    """Browsers send `id`/`rawId` as base64url already; be defensive about
    padding differences rather than assuming exact byte-for-byte match with
    what we stored."""
    return bytes_to_base64url(base64url_to_bytes(raw_id))


# ---------------------------------------------------------------------------
# Management — list/remove registered passkeys (settings-page UI)
# ---------------------------------------------------------------------------


class PasskeyListItem(BaseModel):
    credential_id: str
    nickname: Optional[str] = None
    transports: list[str] = []
    created_at: str
    last_used_at: Optional[str] = None


@router.get("", response_model=list[PasskeyListItem])
async def passkey_list(user: CurrentUser, store: StoreDep) -> list[PasskeyListItem]:
    if not user.account_id:
        return []
    credentials = await store.list_webauthn_credentials(user.account_id)
    return [
        PasskeyListItem(
            credential_id=c.credential_id,
            nickname=c.nickname,
            transports=c.transports,
            created_at=c.created_at,
            last_used_at=c.last_used_at,
        )
        for c in credentials
    ]


@router.delete("/{credential_id}", status_code=status.HTTP_204_NO_CONTENT)
async def passkey_delete(credential_id: str, user: CurrentUser, store: StoreDep) -> Response:
    deleted = user.account_id and await store.delete_webauthn_credential(credential_id, user.account_id)
    if not deleted:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such passkey on this account")
    return Response(status_code=status.HTTP_204_NO_CONTENT)
