#!/usr/bin/env python3
"""Tono backend — proxy + auth + billing.

Two API surfaces share one FastAPI app:

  PUBLIC (no auth, used by Playground / integration tests):
    GET  /health
    POST /v1/analyze              -> tone-analysis passthrough. No API key,
                                    no rate limit; caller pays the cost.

  AUTHENTICATED (device bearer token, used by the keyboard + host app):
    POST /v1/register             -> mint/refresh a bearer token
    GET  /v1/me                   -> device plan + daily usage
    POST /api/analyze             -> rewrite draft, server holds the
                                    LLM API key, daily + IP rate limits applied
    POST /v1/event/axis           -> log which rewrite axis the user tapped
    POST /v1/checkout             -> Stripe Checkout Session for Pro (web/B2B)
    POST /v1/portal               -> Stripe Billing Portal
    POST /v1/stripe/webhook       -> Stripe -> our DB
    GET  /slack/install           -> Slack OAuth redirect
    GET  /slack/oauth             -> Slack OAuth callback
    POST /slack/command           -> /tono slash command handler

The system prompt + JSON schema mirror Shared/ToneEngine.swift on the
iOS side. Keep them in sync if you edit one, edit the other.

Run with ``uvicorn server:app --port 8765`` for local experimentation.
In production, ``Dockerfile`` + ``railway.toml`` / ``fly.toml``.
"""

from __future__ import annotations

import collections
import hashlib
import hmac
import logging
import os
import threading
import time
import uuid
from contextlib import asynccontextmanager
from typing import Annotated, Any, Literal, Optional

from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from . import passkeys, payments, slack, social_auth
from .analyze import (
    AnalyzeRequest,
    CoachContractError,
    RewriteSuggestion,
    ToneAnalysis,
    mock_analyze,
    openai_analyze,
    anthropic_analyze,
    build_user_prompt,
)
from .auth import CurrentUser, StoreDep, current_user
from .store import AccountConflictError, Store, User, get_store

# Locales the LLM providers can respond in. Defines the BCP-47 code → display
# name mapping for the /v1/locales endpoint AND for any client that wants to
# pick a language. Lives here (not in analyze.py) because we deliberately did
# not pull in Claude's analyze.py changes — we only need the locale *names*
# for /v1/locales; per-request locale handling stays the same.
SUPPORTED_LOCALES: dict[str, str] = {
    "en": "English",
    "es": "Spanish",
    "fr": "French",
    "de": "German",
    "ja": "Japanese",
    "pt-BR": "Brazilian Portuguese",
    "ar": "Arabic",
}

logging.basicConfig(
    level=os.environ.get("TONO_LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("tono.server")


# ---------------------------------------------------------------------------
# Abuse prevention
# ---------------------------------------------------------------------------

_DRAFT_MAX_CHARS = int(os.environ.get("DRAFT_MAX_CHARS", "2000"))
_IP_RATE_LIMIT = int(os.environ.get("IP_RATE_LIMIT_PER_MIN", "20"))
_ip_windows: dict[str, collections.deque] = {}
_ip_lock = threading.Lock()


def _get_client_ip(request: Request) -> str:
    xff = request.headers.get("X-Forwarded-For", "")
    return xff.split(",")[0].strip() or (
        request.client.host if request.client else "unknown"
    )


def _check_ip_rate(ip: str) -> bool:
    """Sliding-window rate limiter. Returns False if the IP is over limit."""
    now = time.time()
    with _ip_lock:
        dq = _ip_windows.setdefault(ip, collections.deque())
        while dq and now - dq[0] > 60:
            dq.popleft()
        if len(dq) >= _IP_RATE_LIMIT:
            return False
        dq.append(now)
        return True


def _analysis_cache_key(text: str, axes: list[str], voice: str | None, locale: str) -> str:
    raw = f"{text}|{','.join(sorted(axes))}|{voice or ''}|{locale}"
    return hashlib.sha256(raw.encode()).hexdigest()


# ---------------------------------------------------------------------------
# App-specific wire schemas (server.py only; shared models live in analyze.py)
# ---------------------------------------------------------------------------


class ApiAnalyzeRequest(BaseModel):
    text: str = Field(..., description="The draft message to analyze.")
    provider: Optional[str] = Field(
        default=None,
        description=(
            "Force a specific provider (openai | anthropic | mock). "
            "If omitted, the server picks based on TONO_PROVIDER env."
        ),
    )
    preferred_voice: Optional[str] = None
    axes: Optional[list[str]] = None
    recipient_hint: Optional[str] = None
    thread_context: Optional[str] = None
    context_hints: Optional[list[str]] = Field(
        default=None,
        description="Up to 5 short facts from the user's on-device memory, injected into the system prompt.",
    )
    mode: Literal["coach", "read"] = Field(
        default="coach",
        description="coach = analyze a draft you're about to send; read = interpret a message you received.",
    )
    locale: str = Field(
        default="en",
        description="BCP-47 locale for the response language, e.g. 'en', 'es', 'fr', 'de', 'ja', 'pt-BR', 'ar'.",
    )


class ApiAnalyzeResponse(ToneAnalysis):
    used_today: int
    daily_limit: int  # -1 means unlimited (Pro)
    plan: str


class AxisEventRequest(BaseModel):
    axis: str
    risk_level: str


class RedeemCouponRequest(BaseModel):
    code: str


class RedeemCouponResponse(BaseModel):
    coupon_pro_expires_at: str
    message: str


class CreateCouponRequest(BaseModel):
    code: str
    duration_days: int
    max_uses: int = 0
    expires_at: Optional[str] = None


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------


@asynccontextmanager
async def _lifespan(_: "FastAPI"):
    get_store()  # opens + migrates the DB
    logger.info(
        "tono backend ready: provider=%s stripe=%s slack=%s",
        os.environ.get("TONO_PROVIDER", "mock"),
        "configured" if os.environ.get("STRIPE_SECRET_KEY") else "off",
        "configured" if os.environ.get("SLACK_CLIENT_ID") else "off",
    )
    try:
        yield
    finally:
        get_store().close()


app = FastAPI(
    title="Tono backend",
    version="0.3.0",
    description=(
        "Proxy + auth + billing for the Social Tone Coach keyboard. "
        "See ../SCOPE.md for the product context."
    ),
    lifespan=_lifespan,
)

# CORS: needed by browser-based clients (apps/web, apps/desktop's renderer)
# that call this API directly with no server-side proxy in front of them.
# Native clients (iOS/Android/Slack) don't go through a browser so they're
# unaffected either way. Comma-separated allowlist; "*" (default) is fine
# for the public /v1/analyze passthrough but should be locked down to real
# origins in production once apps/web has a deployed domain.
_CORS_ORIGINS = [
    o.strip()
    for o in os.environ.get("CORS_ALLOWED_ORIGINS", "*").split(",")
    if o.strip()
]
app.add_middleware(
    CORSMiddleware,
    allow_origins=_CORS_ORIGINS,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# Error shape
# ---------------------------------------------------------------------------


@app.exception_handler(HTTPException)
async def http_exc_handler(_: Request, exc: HTTPException) -> JSONResponse:
    detail = exc.detail
    if isinstance(detail, dict):
        message = detail.pop("message", None) or "error"
        extra = detail
    else:
        message = detail if isinstance(detail, str) else "error"
        extra = None

    body: dict[str, Any] = {"error": {"code": exc.status_code, "message": message}}
    if extra:
        body["error"].update(extra)
    return JSONResponse(
        status_code=exc.status_code,
        content=body,
        headers=exc.headers,
    )


# ---------------------------------------------------------------------------
# Public endpoints
# ---------------------------------------------------------------------------


_PRIVACY_HTML = """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Tono Privacy Policy</title>
<style>
  body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:680px;
       margin:48px auto;padding:0 24px;color:#1a1a1a;line-height:1.6}
  h1{font-size:1.8rem;margin-bottom:4px}
  h2{font-size:1.1rem;margin-top:32px;margin-bottom:8px}
  p,li{font-size:.95rem;color:#444}
  a{color:#7c3aed}
  footer{margin-top:48px;font-size:.8rem;color:#999}
</style>
</head>
<body>
<h1>Privacy Policy</h1>
<p><em>Last updated: June 2026</em></p>

<h2>What we collect</h2>
<p>Tono collects only what is necessary to provide the service:</p>
<ul>
  <li><strong>Anonymous device ID</strong> — a random UUID generated on first launch. No name, email, or phone number.</li>
  <li><strong>Draft text (transient)</strong> — your message is sent to our server for analysis and immediately discarded. We never store message content.</li>
  <li><strong>Usage counters</strong> — how many rewrites you've run today, your plan tier. No content, no recipients.</li>
  <li><strong>Subscription status</strong> — plan (free/pro) and renewal date, via StoreKit 2 (iOS) or Stripe (web).</li>
</ul>

<h2>What we do not collect</h2>
<ul>
  <li>Message content (drafts are analyzed and discarded immediately)</li>
  <li>Recipient names or contact data</li>
  <li>Precise location</li>
  <li>Browsing history or cross-app behavior</li>
</ul>

<h2>How your data is used</h2>
<p>Device IDs are used solely to enforce the daily free-tier limit and track subscription status. Aggregate usage counts (how many rewrites per day) may be used to improve the product. No data is sold to or shared with third parties for advertising.</p>

<h2>How Tono learns and improves</h2>
<p>With your permission ("Help improve Tono" toggle in Settings, on by default), Tono records content-free outcome signals: which rewrite style you chose, whether you used the suggestion, and a rough message-length bucket (short / medium / long — never the actual length or any words). <strong>Your messages, your rewrites, and who you're messaging are never collected.</strong> These anonymous outcome signals accumulate across users and help us improve axis ordering and rewrite quality for everyone. You can opt out at any time in Settings → Preferences → Help improve Tono; opting out immediately stops any signal from leaving your device and does not affect your personal style memory.</p>
<p>Individual signals are kept for 90 days and then permanently deleted. Any pattern used to inform product changes must be backed by at least 50 distinct devices — this prevents any single person's behavior from being distinguishable in the aggregate.</p>

<h2>Third-party services</h2>
<ul>
  <li><strong>OpenAI / Anthropic</strong> — draft text is forwarded to one of these LLM APIs to generate rewrites. Each provider's privacy policy governs their handling of API inputs.</li>
  <li><strong>Stripe</strong> (web subscriptions only) — payment processing. Tono never sees or stores card numbers.</li>
  <li><strong>Apple StoreKit 2</strong> (iOS subscriptions) — Apple manages all payment data.</li>
</ul>

<h2>Data retention</h2>
<p>Device records (ID, token, plan) are retained as long as you use the app. You can request deletion by emailing us; we will remove your record within 30 days.</p>

<h2>Children</h2>
<p>Tono is not directed at children under 13. We do not knowingly collect data from anyone under 13.</p>

<h2>Contact</h2>
<p>Questions? <a href="mailto:privacy@tonocoach.com">privacy@tonocoach.com</a></p>

<footer>Tono / Social Tone Coach</footer>
</body>
</html>"""


@app.get("/privacy", response_class=HTMLResponse, include_in_schema=False)
async def privacy_policy() -> HTMLResponse:
    return HTMLResponse(content=_PRIVACY_HTML)


@app.get("/health")
async def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "ts": int(time.time()),
        "id": str(uuid.uuid4())[:8],
        "version": "0.3.0",
        "canonical_sha": os.environ.get("TONO_CANONICAL_SHA", "unknown"),
        "schema_revision": os.environ.get(
            "TONO_SCHEMA_REVISION", "legacy-sqlite-unversioned"
        ),
        "stripe_configured": bool(os.environ.get("STRIPE_SECRET_KEY")),
        "slack_configured": bool(os.environ.get("SLACK_CLIENT_ID")),
        "free_daily_limit": int(os.environ.get("FREE_DAILY_LIMIT", "10")),
    }


@app.get("/v1/whoami")
async def v1_whoami(request: Request) -> dict[str, Any]:
    """Public debug endpoint. Returns the client's apparent IP and a server
    timestamp so iOS / curl callers can sanity-check routing, proxies, and
    clock skew. No auth required, no PII stored.

    Ported forward from the pre-Path-A server (kept for iOS routing
    sanity-checks during the account-layer migration).
    """
    import datetime as dt
    return {
        "client_ip": _get_client_ip(request),
        "xff": request.headers.get("X-Forwarded-For", ""),
        "ua": request.headers.get("User-Agent", ""),
        "ts": int(time.time()),
        "iso": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
    }


@app.get("/v1/locales")
async def list_locales() -> dict[str, Any]:
    """Locales the LLM providers can respond in. Clients use this to build
    a language switcher without hardcoding the list."""
    return {"locales": [{"code": k, "name": v} for k, v in SUPPORTED_LOCALES.items()]}


@app.post("/v1/analyze", response_model=ToneAnalysis)
async def v1_analyze(req: AnalyzeRequest, request: Request) -> dict[str, Any]:
    """Unauthenticated passthrough kept for backward compatibility with
    the iOS Playground tab and integration tests. No billing is applied,
    but a per-IP cap protects the shared provider credentials from abuse.
    """
    if not _check_ip_rate(_get_client_ip(request)):
        raise HTTPException(
            status_code=429,
            detail="Too many requests. Please retry in a minute.",
            headers={"Retry-After": "60"},
        )
    provider = os.environ.get("TONO_PROVIDER", "mock")
    try:
        if provider == "mock":
            return mock_analyze(req)
        if provider == "openai":
            return await openai_analyze(req)
        if provider == "anthropic":
            return await anthropic_analyze(req)
        raise HTTPException(400, f"unknown provider: {provider}")
    except CoachContractError as error:
        logger.warning("Invalid Coach response from %s: %s", provider, error)
        raise HTTPException(502, "Coach response incomplete. Please retry.") from error


# ---------------------------------------------------------------------------
# Authenticated endpoints
# ---------------------------------------------------------------------------


class RegisterRequest(BaseModel):
    device_id: Optional[str] = None
    app_version: Optional[str] = None
    platform: Optional[str] = None  # "ios" | "android" | "macos" | "windows" | "web" | "slack"


class RegisterResponse(BaseModel):
    device_id: str
    api_token: str
    plan: str
    is_pro: bool


@app.post("/v1/register", response_model=RegisterResponse)
def register(body: RegisterRequest, store: StoreDep) -> RegisterResponse:
    user = store.register_device(body.device_id)
    return RegisterResponse(
        device_id=user.device_id,
        api_token=user.api_token,
        plan=user.plan,
        is_pro=user.is_pro,
    )


class MeResponse(BaseModel):
    device_id: str
    plan: str
    is_pro: bool
    used_today: int
    daily_limit: int  # -1 = unlimited
    subscription_status: Optional[str]
    subscription_renews_at: Optional[str]
    account_id: Optional[str] = None


@app.get("/v1/me", response_model=MeResponse)
def me(user: CurrentUser, store: StoreDep) -> MeResponse:
    today = _today_utc()
    # Once a device is linked to an account, the account is the source of
    # truth for plan/subscription/daily usage — see User.is_pro /
    # User.plan_resolved, and Store.consume_rewrite for why the counter
    # itself lives on the account row once signed in (pooled across every
    # device linked to it, not reset per device).
    quota_source = user.account if user.account else user
    used = quota_source.daily_count if quota_source.daily_day == today else 0
    limit = -1 if user.is_pro else int(os.environ.get("FREE_DAILY_LIMIT", "10"))
    subscription_status = user.account.subscription_status if user.account else user.subscription_status
    subscription_renews_at = user.account.subscription_renews_at if user.account else user.subscription_renews_at
    return MeResponse(
        device_id=user.device_id,
        plan=user.plan_resolved,
        is_pro=user.is_pro,
        used_today=used,
        daily_limit=limit,
        subscription_status=subscription_status,
        subscription_renews_at=subscription_renews_at,
        account_id=user.account_id,
    )


# ---------------------------------------------------------------------------
# Account sign-in (Apple / Google) — links the calling device to an account
# so Pro status and identity travel across every device that signs in.
# ---------------------------------------------------------------------------


class AppleSignInRequest(BaseModel):
    identity_token: str
    # False (default): plain sign-in — resolve/create the account for this
    # identity and point the calling device at it, switching away from
    # whatever account the device was previously linked to if any. This is
    # ordinary login (including "log in as someone else on this device")
    # and never conflicts.
    # True: explicit "add this as another way to sign in to MY CURRENT
    # account" — requires the device to already be signed in, and 409s if
    # the identity already belongs to a different account. Only pass this
    # from an authenticated "linked accounts" settings screen, never from
    # a login screen.
    link: bool = False


class GoogleSignInRequest(BaseModel):
    id_token: str
    link: bool = False


class SignInResponse(BaseModel):
    account_id: str
    plan: str
    is_pro: bool
    email: Optional[str] = None


def _resolve_provider_signin(
    store: Store, user: User, provider: str, sub: str, email: Optional[str], link: bool
):
    """Shared by /v1/auth/apple and /v1/auth/google. `link=False` (plain
    sign-in) always succeeds and switches the calling device to whichever
    account owns this identity — creating one on first use. `link=True`
    requires the device to already be signed in and refuses (409) to
    attach an identity that already belongs to someone else's account."""
    if link and not user.account_id:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "sign in before linking another provider")
    try:
        account = store.upsert_account_by_provider(
            provider, sub, email, link_into_account_id=user.account_id if link else None
        )
    except AccountConflictError as exc:
        raise HTTPException(status.HTTP_409_CONFLICT, str(exc))
    store.link_device_to_account(user.device_id, account.id)
    return account


@app.post("/v1/auth/apple", response_model=SignInResponse)
async def auth_apple(
    body: AppleSignInRequest,
    user: CurrentUser,
    store: StoreDep,
    verifier: Annotated[social_auth.IdentityVerifier, Depends(social_auth.get_apple_verifier)],
) -> SignInResponse:
    claims = await verifier(body.identity_token)
    account = _resolve_provider_signin(store, user, "apple", claims.sub, claims.email, body.link)
    return SignInResponse(account_id=account.id, plan=account.plan, is_pro=account.is_pro, email=account.email)


@app.post("/v1/auth/google", response_model=SignInResponse)
async def auth_google(
    body: GoogleSignInRequest,
    user: CurrentUser,
    store: StoreDep,
    verifier: Annotated[social_auth.IdentityVerifier, Depends(social_auth.get_google_verifier)],
) -> SignInResponse:
    claims = await verifier(body.id_token)
    account = _resolve_provider_signin(store, user, "google", claims.sub, claims.email, body.link)
    return SignInResponse(account_id=account.id, plan=account.plan, is_pro=account.is_pro, email=account.email)


@app.post("/api/analyze", response_model=ApiAnalyzeResponse)
async def api_analyze(
    body: ApiAnalyzeRequest,
    request: Request,
    user: CurrentUser,
    store: StoreDep,
) -> ApiAnalyzeResponse:
    """The keyboard's primary endpoint. Authenticated, rate-limited,
    server holds the LLM API key.
    """
    if not body.text or not body.text.strip():
        raise HTTPException(400, "text is required")
    if len(body.text) > _DRAFT_MAX_CHARS:
        raise HTTPException(400, f"text too long (max {_DRAFT_MAX_CHARS} chars)")

    # Per-IP sliding-window cap to block scripted abuse before it touches
    # any per-user counters or makes LLM calls.
    client_ip = _get_client_ip(request)
    if not _check_ip_rate(client_ip):
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="too many requests from this IP — try again in a minute",
            headers={"Retry-After": "60"},
        )

    provider = (body.provider or os.environ.get("TONO_PROVIDER", "mock")).lower()
    # Use client-provided ranking (per-user StyleMemory) when present; fall back
    # to the collective win order so new users inherit crowd wisdom.
    axes = body.axes or store.global_axis_ranking(days=30)

    # Cache lookup — hits don't consume the daily allowance.
    cache_key = (
        _analysis_cache_key(body.text, axes, body.preferred_voice, body.locale)
        if provider != "mock"
        else None
    )
    if cache_key:
        cached = store.get_cached_response(cache_key)
        if cached:
            today = _today_utc()
            # Pooled on the account once signed in — see consume_rewrite.
            quota_source = user.account if user.account else user
            snap_used = quota_source.daily_count if quota_source.daily_day == today else 0
            snap_limit = -1 if user.is_pro else int(os.environ.get("FREE_DAILY_LIMIT", "10"))
            store.log_usage(
                user.device_id, "/api/analyze", 200, provider="cache",
                drafts_chars=len(body.text),
            )
            return ApiAnalyzeResponse(
                **cached, used_today=snap_used, daily_limit=snap_limit, plan=user.plan_resolved
            )

    # Rate limit BEFORE we call the LLM so a bad actor can't burn $.
    allowed, used, limit = store.consume_rewrite(user.device_id)
    if not allowed:
        store.log_usage(user.device_id, "/api/analyze", 429, drafts_chars=len(body.text))
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail={
                "message": "daily free limit reached",
                "used_today": used,
                "daily_limit": limit,
                "plan": user.plan,
            },
            headers={"Retry-After": "86400"},
        )

    internal = AnalyzeRequest(
        draft=body.text,
        recipient_hint=body.recipient_hint,
        preferred_voice=body.preferred_voice,
        axes=axes,
        context_hints=body.context_hints,
        thread_context=body.thread_context,
        mode=body.mode,
        locale=body.locale,
    )

    try:
        if provider == "mock":
            result = mock_analyze(internal)
        elif provider == "openai":
            result = await openai_analyze(internal)
        elif provider == "anthropic":
            result = await anthropic_analyze(internal)
        else:
            raise HTTPException(400, f"unknown provider: {provider}")
    except CoachContractError as e:
        logger.warning("Invalid Coach response from %s: %s", provider, e)
        store.log_usage(
            user.device_id, "/api/analyze", 502, provider=provider,
            drafts_chars=len(body.text),
        )
        raise HTTPException(502, "Coach response incomplete. Please retry.") from e
    except HTTPException:
        store.log_usage(
            user.device_id, "/api/analyze", 502, provider=provider,
            drafts_chars=len(body.text),
        )
        raise
    except Exception as e:
        logger.exception("/api/analyze failed")
        store.log_usage(
            user.device_id, "/api/analyze", 500, provider=provider,
            drafts_chars=len(body.text),
        )
        raise HTTPException(500, f"analyze failed: {e}")

    if cache_key:
        store.set_cached_response(cache_key, result)
    store.log_usage(
        user.device_id, "/api/analyze", 200, provider=provider,
        drafts_chars=len(body.text),
    )
    return ApiAnalyzeResponse(**result, used_today=used, daily_limit=limit, plan=user.plan_resolved)


@app.post("/v1/event/axis", status_code=204)
def log_axis_event(
    body: AxisEventRequest,
    user: CurrentUser,
    store: StoreDep,
) -> None:
    """Record which rewrite axis the user tapped. Used for product analytics
    (which axes resonate most) and eventually for personalized axis ordering.
    """
    store.log_axis_event(user.device_id, body.axis, body.risk_level)


# ---------------------------------------------------------------------------
# A3: Lean first-party analytics event stream
# ---------------------------------------------------------------------------

# A4 PRIVACY GUARDRAIL: permitted event names only.
_PERMITTED_EVENT_NAMES = {
    "coach_requested",
    "analysis_shown",
    "rewrite_inserted",
    "rewrite_edited_after_insert",
    "axis_rejected",
    # Collective improvement signal — content-free behavioral outcomes.
    # See brief: risk/axis/mode/bucket only; never message text or recipient.
    "improvement_outcome",
}


class EventRequest(BaseModel):
    # A4: extra="forbid" makes the permitted-key allowlist structural — any
    # field not declared below (e.g. a client bug that tries to attach
    # message_text or a recipient name) is REJECTED with 422, not silently
    # dropped. The privacy contract fails loud, in tests, instead of leaking.
    model_config = ConfigDict(extra="forbid")

    event: str
    ts: Optional[int] = None
    mode: Optional[str] = None
    risk_level: Optional[str] = None
    latency_ms: Optional[int] = None
    source: Optional[str] = None
    selected_axis: Optional[str] = None
    shown_axes: Optional[list[str]] = None
    picked_axis: Optional[str] = None
    # Collective improvement signal fields (improvement_outcome event only).
    # msg_len_bucket: bucketed on-device (short/medium/long) — NEVER the raw
    # character count. rewrite_used and edit_after are boolean outcome flags.
    # These three fields are the ONLY new data the improvement_outcome event
    # adds beyond what analytics events already carry; all other signal
    # (risk_level, selected_axis, mode) reuses existing permitted fields.
    msg_len_bucket: Optional[str] = None   # "short" | "medium" | "long"
    rewrite_used: Optional[bool] = None
    edit_after: Optional[bool] = None


@app.post("/v1/events", status_code=204)
def log_analytics_event(
    body: EventRequest,
    user: CurrentUser,
    store: StoreDep,
) -> None:
    """A3: First-party analytics event ingestion. Fire-and-forget;
    failures do not surface to the client.

    A4 enforced: only event-type strings, axis enums, risk levels, latency,
    and mode strings are accepted. No message content, no recipient names,
    no free-text user input reaches this endpoint.

    improvement_outcome: stored to improvement_events only when the device's
    'improve_tono' flag is enabled (respects opt-out). k-anonymity floor is
    enforced at aggregation query time, not here.
    """
    if body.event not in _PERMITTED_EVENT_NAMES:
        # Silently drop unknown events rather than erroring — keeps clients simple.
        return

    if body.event == "improvement_outcome":
        # Defense-in-depth: also check server-side flag so an opt-out is
        # honored even if the client ignores it.
        flags = store.get_features(user.device_id, user.is_pro)
        if flags.get("improve_tono", True) and body.risk_level and body.msg_len_bucket:
            store.log_improvement_event(
                device_id=user.device_id,
                risk_predicted=body.risk_level,
                axis_selected=body.selected_axis,
                mode=body.mode or "coach",
                msg_len_bucket=body.msg_len_bucket,
                rewrite_used=body.rewrite_used or False,
                edit_after=body.edit_after or False,
            )

    logger.info(
        "analytics event=%s device=%s mode=%s risk=%s latency_ms=%s axis=%s",
        body.event,
        user.device_id[:8],
        body.mode or "-",
        body.risk_level or "-",
        body.latency_ms or "-",
        body.selected_axis or body.picked_axis or "-",
    )


# ---------------------------------------------------------------------------
# A2: MetricKit diagnostics ingestion
# ---------------------------------------------------------------------------


class MetricsRequest(BaseModel):
    # A4: same fail-closed stance as EventRequest — only the declared
    # diagnostic counters are accepted; anything else is rejected.
    model_config = ConfigDict(extra="forbid")

    type: str              # "daily_metrics" | "diagnostics"
    end_ts: Optional[float] = None
    ts: Optional[int] = None
    # Memory + exit counts (daily_metrics)
    avg_memory_mb: Optional[float] = None
    fg_normal: Optional[int] = None
    fg_oom: Optional[int] = None
    bg_oom: Optional[int] = None
    bg_watchdog: Optional[int] = None
    bg_normal: Optional[int] = None
    # Diagnostic counts
    crash_count: Optional[int] = None
    hang_count: Optional[int] = None
    disk_write_exception_count: Optional[int] = None


@app.post("/v1/metrics", status_code=204)
def ingest_metrics(
    body: MetricsRequest,
    user: CurrentUser,
) -> None:
    """A2: Receive MetricKit daily summaries from the host app.
    Logged to stdout for now; wire to a time-series store when
    device fleet grows large enough to need dashboards.
    """
    logger.info(
        "metrics type=%s device=%s avg_mem=%.1f fg_oom=%s bg_oom=%s watchdog=%s crashes=%s",
        body.type,
        user.device_id[:8],
        body.avg_memory_mb or 0.0,
        body.fg_oom or 0,
        body.bg_oom or 0,
        body.bg_watchdog or 0,
        body.crash_count or 0,
    )


# ---------------------------------------------------------------------------
# Feature flags (user-facing)
# ---------------------------------------------------------------------------

_USER_CONTROLLABLE_FLAGS = {
    "thread_context", "weekly_digest", "risk_delta",
    "memory_inference", "memory_context_hints",
    "improve_tono",
}

_COLLECTIVE_MIN_DEVICES = int(os.environ.get("COLLECTIVE_MIN_DEVICES", "50"))


@app.get("/v1/features")
def get_features(user: CurrentUser, store: StoreDep) -> dict[str, bool]:
    """Return the resolved feature flags for the authenticated device."""
    return store.get_features(user.device_id, user.is_pro)


class SetFeatureRequest(BaseModel):
    enabled: bool


@app.put("/v1/features/{key}", status_code=200)
def set_feature_preference(
    key: str,
    body: SetFeatureRequest,
    user: CurrentUser,
    store: StoreDep,
) -> dict[str, Any]:
    """Let users toggle their own user-controllable flags (e.g. opt out of weekly digest)."""
    if key not in _USER_CONTROLLABLE_FLAGS:
        raise HTTPException(403, f"flag '{key}' is not user-controllable")
    store.set_user_flag_override(user.device_id, key, body.enabled, set_by="user")
    return {"ok": True, "key": key, "enabled": body.enabled}


@app.get("/v1/digest")
def get_digest(user: CurrentUser, store: StoreDep) -> dict[str, Any]:
    """Weekly tone digest — rewrites, days active, axis breakdown."""
    return store.get_weekly_digest(user.device_id)


# ---------------------------------------------------------------------------
# Admin endpoints (all protected by X-Admin-Secret header)
# ---------------------------------------------------------------------------


def _check_admin(request: Request) -> None:
    secret = os.environ.get("TONO_ADMIN_SECRET", "")
    provided = request.headers.get("X-Admin-Secret", "")
    if not secret or not hmac.compare_digest(secret.encode(), provided.encode()):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="forbidden")


@app.get("/admin/stats")
def admin_stats(request: Request, store: StoreDep) -> dict[str, Any]:
    """Aggregate product analytics: axis usage, registration count, active pro count."""
    _check_admin(request)

    def _do() -> dict[str, Any]:
        cur = store._conn.cursor()
        cur.execute("SELECT COUNT(*) as total FROM users")
        total_devices = cur.fetchone()["total"]

        cur.execute(
            "SELECT COUNT(*) as cnt FROM users WHERE plan='pro' AND subscription_status IN ('active','trialing')"
        )
        stripe_pro = cur.fetchone()["cnt"]

        import datetime as dt
        now_iso = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
        cur.execute(
            "SELECT COUNT(*) as cnt FROM users WHERE coupon_pro_expires_at IS NOT NULL AND coupon_pro_expires_at > ?",
            (now_iso,),
        )
        coupon_pro = cur.fetchone()["cnt"]

        cur.execute("SELECT COUNT(*) as cnt FROM coupon_redemptions")
        total_redemptions = cur.fetchone()["cnt"]

        today = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
        cur.execute(
            "SELECT SUM(daily_count) as s FROM users WHERE daily_day = ?", (today,)
        )
        rewrites_today = cur.fetchone()["s"] or 0

        cutoff = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=30)).strftime("%Y-%m-%d")
        cur.execute(
            "SELECT axis, COUNT(*) as cnt FROM axis_events WHERE ts >= ? GROUP BY axis ORDER BY cnt DESC",
            (cutoff,),
        )
        axis_stats = {row["axis"]: row["cnt"] for row in cur.fetchall()}

        return {
            "total_devices": total_devices,
            "pro_stripe": stripe_pro,
            "pro_coupon": coupon_pro,
            "coupon_redemptions": total_redemptions,
            "rewrites_today": rewrites_today,
            "axis_stats_30d": axis_stats,
        }

    return store._run(_do).result()


# ---------------------------------------------------------------------------
# Admin axis analytics
# ---------------------------------------------------------------------------


@app.get("/admin/axis-stats")
def admin_axis_stats(
    request: Request,
    store: StoreDep,
    days: int = 30,
) -> dict[str, Any]:
    """Per-axis win counts broken down by risk level, plus global ranking.

    ``overall`` — axis tap totals across all risk levels.
    ``by_risk_level`` — per-risk breakdown so we can see which axes resonate
      when a message is high-risk vs. low-risk (feeds prompt tuning).
    ``global_ranking`` — the collective-intelligence axis order currently
      used as the default for new users who have no per-user StyleMemory.
    """
    _check_admin(request)
    overall = store.axis_stats(days=days)
    by_risk = store.axis_stats_by_risk(days=days)
    ranking = store.global_axis_ranking(days=days)
    return {
        "days": days,
        "overall": overall,
        "by_risk_level": by_risk,
        "global_ranking": ranking,
    }


# ---------------------------------------------------------------------------
# Collective improvement analytics (admin-only, k-anon enforced)
# ---------------------------------------------------------------------------


@app.get("/admin/improvement-stats")
def admin_improvement_stats(
    request: Request,
    store: StoreDep,
    days: int = 30,
    min_devices: int = _COLLECTIVE_MIN_DEVICES,
) -> dict[str, Any]:
    """Collective improvement aggregates with k-anonymity floor enforced at query level.

    - ``axis_effectiveness``: which axes win by risk level. Only patterns
      backed by >= min_devices distinct devices are returned; patterns with
      fewer contributors are discarded to prevent any individual's behavior
      from being distinguishable in the aggregate.
    - ``rewrite_quality``: edit-after-insert rates by axis. High rate signals
      close-but-wrong rewrites — candidate for prompt revision.
    - ``min_devices_floor``: the k-anon floor applied to every query above.

    Use these aggregates to tune default axis ordering and prompt quality.
    All individual event rows are aged out after 90 days; only aggregates
    survive long-term.
    """
    _check_admin(request)
    effectiveness = store.get_axis_effectiveness(days=days, min_devices=min_devices)
    quality = store.get_rewrite_quality(days=days, min_devices=min_devices)
    return {
        "days": days,
        "min_devices_floor": min_devices,
        "axis_effectiveness_by_risk": effectiveness,
        "rewrite_quality_by_axis": quality,
    }


@app.post("/admin/maintenance/age-out-events", status_code=200)
def admin_age_out_events(
    request: Request,
    store: StoreDep,
    retain_days: int = 90,
) -> dict[str, Any]:
    """Age out raw improvement_events older than retain_days.

    Raw events are kept only long enough to compute rolling aggregates.
    Call this nightly (e.g. from a Railway cron or a scheduled job).
    """
    _check_admin(request)
    deleted = store.age_out_improvement_events(retain_days=retain_days)
    return {"deleted": deleted, "retain_days": retain_days}


# ---------------------------------------------------------------------------
# Admin flag management
# ---------------------------------------------------------------------------


@app.get("/admin/flags")
def admin_list_flags(request: Request, store: StoreDep) -> list[dict[str, Any]]:
    """List all feature flags with their current state."""
    _check_admin(request)
    return store.get_all_flags()


class AdminUpdateFlagRequest(BaseModel):
    enabled: Optional[bool] = None
    plan_required: Optional[str] = "UNCHANGED"
    rollout_pct: Optional[int] = None


@app.patch("/admin/flags/{key}")
def admin_update_flag(
    key: str,
    body: AdminUpdateFlagRequest,
    request: Request,
    store: StoreDep,
) -> dict[str, Any]:
    """Update a feature flag globally."""
    _check_admin(request)
    ok = store.update_flag(
        key,
        enabled=body.enabled,
        plan_required=body.plan_required,
        rollout_pct=body.rollout_pct,
    )
    if not ok:
        raise HTTPException(404, f"flag '{key}' not found")
    return {"ok": True, "key": key}


class AdminFlagOverrideRequest(BaseModel):
    device_id: str
    enabled: bool


@app.post("/admin/flags/{key}/override", status_code=200)
def admin_set_flag_override(
    key: str,
    body: AdminFlagOverrideRequest,
    request: Request,
    store: StoreDep,
) -> dict[str, Any]:
    """Force-enable or force-disable a flag for one device (beta access, support exceptions)."""
    _check_admin(request)
    store.set_user_flag_override(body.device_id, key, body.enabled, set_by="admin")
    return {"ok": True, "key": key, "device_id": body.device_id, "enabled": body.enabled}


@app.delete("/admin/flags/{key}/override/{device_id}", status_code=200)
def admin_delete_flag_override(
    key: str,
    device_id: str,
    request: Request,
    store: StoreDep,
) -> dict[str, Any]:
    """Remove an admin override so the device falls back to the global flag."""
    _check_admin(request)
    store.delete_user_flag_override(device_id, key)
    return {"ok": True, "key": key, "device_id": device_id}


# ---------------------------------------------------------------------------
# Coupon / promo code endpoints
# ---------------------------------------------------------------------------


@app.post("/v1/coupon/redeem", response_model=RedeemCouponResponse)
def redeem_coupon(
    body: RedeemCouponRequest,
    user: CurrentUser,
    store: StoreDep,
) -> RedeemCouponResponse:
    """Redeem a promo/coupon code. Grants Pro access for the code's duration."""
    try:
        exp = store.redeem_coupon(user.device_id, body.code.strip().upper())
        return RedeemCouponResponse(
            coupon_pro_expires_at=exp,
            message="Pro access activated!",
        )
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))


@app.post("/admin/coupon/create", status_code=201)
def admin_create_coupon(
    body: CreateCouponRequest,
    request: Request,
    store: StoreDep,
) -> dict[str, Any]:
    """Create a new coupon code. Protected by TONO_ADMIN_SECRET header."""
    _check_admin(request)
    ok = store.create_coupon(
        body.code.strip().upper(),
        body.duration_days,
        body.max_uses,
        body.expires_at,
    )
    if not ok:
        raise HTTPException(status_code=409, detail="code already exists")
    return {"code": body.code.strip().upper(), "status": "created"}


# ---------------------------------------------------------------------------
# Mount routers
# ---------------------------------------------------------------------------

app.include_router(payments.router)
app.include_router(slack.router)
app.include_router(passkeys.router)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _today_utc() -> str:
    import datetime as dt
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("Backend.server:app", host="127.0.0.1", port=8765, reload=True)
