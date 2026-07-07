"""Bearer-token auth dependency for the Tono backend.

The iOS app issues a stable ``device_id`` on first launch (a UUID stored
in the App Group container) and POSTs it to ``/v1/register`` to mint an
opaque bearer token. Every subsequent request carries the token in the
``Authorization: Bearer ...`` header.

Why opaque tokens (not JWTs):
  - Single-issuer trust (this server).
  - We need to revoke on device uninstall / user request; opaque tokens
    let us just ``rotate_token`` and the old one stops working.
  - Stripe webhooks use a separate signature verification (see payments.py).

This module exposes a FastAPI ``Depends`` that returns the authenticated
``User`` or raises 401.
"""

from __future__ import annotations

from typing import Annotated, Optional

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .store import Store, User, get_store

# auto_error=False so we can return our own shaped error message rather
# than FastAPI's default "Not authenticated".
_bearer = HTTPBearer(auto_error=False)


def _store_dep() -> Store:
    return get_store()


StoreDep = Annotated[Store, Depends(_store_dep)]


def current_user(
    request: Request,
    creds: Annotated[Optional[HTTPAuthorizationCredentials], Depends(_bearer)],
    store: StoreDep,
) -> User:
    token = creds.credentials if creds else None
    if not token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="missing bearer token",
            headers={"WWW-Authenticate": 'Bearer realm="tono"'},
        )
    user = store.get_by_token(token)
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="invalid or revoked token",
            headers={"WWW-Authenticate": 'Bearer realm="tono"'},
        )
    # Stash on request.state for log lines / handlers downstream.
    request.state.user = user
    return user


CurrentUser = Annotated[User, Depends(current_user)]


def optional_current_user(
    creds: Annotated[Optional[HTTPAuthorizationCredentials], Depends(_bearer)],
    store: StoreDep,
) -> Optional[User]:
    """Like ``current_user`` but returns ``None`` instead of raising 401
    when the request has no / invalid bearer token.

    Used by endpoints that serve both the iOS app (authenticated) and
    the public website (anonymous checkout — see /v1/checkout). The iOS
    flow is unchanged; the website calls /v1/checkout with no
    Authorization header and we mint a Stripe-hosted Checkout Session
    that collects the buyer's email.
    """
    if not creds or not creds.credentials:
        return None
    return store.get_by_token(creds.credentials)


OptionalCurrentUser = Annotated[Optional[User], Depends(optional_current_user)]
