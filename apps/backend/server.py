#!/usr/bin/env python3
"""Tono backend — proxy + auth + billing.

Two API surfaces share one FastAPI app:

  PUBLIC (no auth):
    GET  /health                  -> liveness + non-PII config disclosure

  AUTHENTICATED (device bearer token; every rewrite route also requires an
  active entitlement — the shared server gate fails closed with a distinct
  402 before any provider call, and there is NO free daily tier):
    POST /v1/register             -> mint/refresh a bearer token
    GET  /v1/me                   -> device plan + usage
    POST /v1/analyze              -> tone-analysis passthrough (back-compat).
                                    Bearer token + entitlement gate; 401/402
                                    fail-closed before any provider call.
    POST /api/analyze             -> rewrite draft, server holds the
                                    LLM API key; entitlement gate + IP rate limit
    POST /v1/event/axis           -> log which rewrite axis the user tapped
    POST /v1/checkout             -> Stripe Checkout Session for Pro (web/B2B)
    POST /v1/portal               -> Stripe Billing Portal
    POST /v1/stripe/webhook       -> Stripe -> our DB
    GET  /slack/install           -> Slack OAuth redirect
    GET  /slack/oauth             -> Slack OAuth callback
    POST /slack/command           -> /tono slash command handler

The system prompt + JSON schema mirror Shared/ToneEngine.swift on the
iOS side. Keep them in sync if you edit one, edit the other.

Run with ``uvicorn backend.server:app --port 8765`` from ``apps/`` for local
experimentation — the module uses package-relative imports, so it cannot be run
as a bare script. In production, ``Dockerfile`` (whose CMD is exactly
``uvicorn backend.server:app``) + ``railway.toml`` / ``fly.toml``.
"""

from __future__ import annotations

import contextlib
import hashlib
import hmac
import json
import logging
import os
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated, Any, Literal, Optional

from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from . import (
    app_store,
    email_auth,
    email_identity,
    google_play,
    passkeys,
    payments,
    rate_limit,
    slack,
    social_auth,
    supabase_auth,
)
from . import store as store_module
from .app_store import compute_me_fields
from .analyze import (
    AnalyzeRequest,
    CANONICAL_COACH_AXES,
    CoachContractError,
    RewriteSuggestion,
    ToneAnalysis,
    mock_analyze,
    mock_variant_analyze,
    openai_analyze,
    anthropic_analyze,
    build_user_prompt,
    enforce_coach_contract,
    # P0 BUILD-95 selected-variant contract: imported from the same
    # module so the slack dispatch and tests can reuse the helpers.
    VARIANT_ALLOWLIST,
    VariantBlockedReason,
    VariantRequest,
    VariantResponse,
    aclose_provider_client,
    invoke_single_variant,
    preflight_variant,
    select_model_for_variant,
)
from .auth import CurrentUser, OptionalCurrentUser, StoreDep, current_user
# Build 117 — Read the Ask. Its own module because its response contract is a
# different product from a rewrite, not a variation on one.
from .read_ask import (
    READ_ASK_MODE,
    ReadAskContractError,
    ReadAskRequest,
    ReadAskResponse,
    invoke_read_ask,
)
from .store import AccountConflictError, DeviceRegistrationProofError, Store, User, get_store

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

_PROVENANCE_PATH = Path(__file__).with_name("build-provenance.json")


def _build_provenance() -> dict[str, str]:
    """Return the immutable source/contract/schema identity for this artifact."""
    try:
        payload = json.loads(_PROVENANCE_PATH.read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        payload = {}
    return {
        "canonical_sha": str(
            payload.get("canonical_sha")
            or os.environ.get("TONO_CANONICAL_SHA")
            or os.environ.get("RAILWAY_GIT_COMMIT_SHA")
            or "unknown"
        ),
        "contract_sha256": str(
            payload.get("contract_sha256")
            or os.environ.get("TONO_CONTRACT_SHA256")
            or "unknown"
        ),
        "schema_revision": str(
            payload.get("schema_revision")
            or os.environ.get("TONO_SCHEMA_REVISION")
            or "legacy-sqlite-unversioned"
        ),
    }


# ---------------------------------------------------------------------------
# Abuse prevention
# ---------------------------------------------------------------------------

_DRAFT_MAX_CHARS = int(os.environ.get("DRAFT_MAX_CHARS", "2000"))
_IP_RATE_LIMIT = int(os.environ.get("IP_RATE_LIMIT_PER_MIN", "20"))

# Scope name for the rewrite routes' per-IP budget inside the shared limiter.
# Distinct from "register"/"auth"/"coupon" so a flood on one endpoint family
# cannot eat another's budget.
_IP_RATE_SCOPE = "analyze"


def _get_client_ip(request: Request) -> str:
    xff = request.headers.get("X-Forwarded-For", "")
    return xff.split(",")[0].strip() or (
        request.client.host if request.client else "unknown"
    )


def _check_ip_rate(ip: str) -> bool:
    """Per-IP sliding-window cap for the rewrite routes. False = over limit.

    Delegates to ``rate_limit.check_ip_rate`` — the SAME limiter ``/v1/register``
    already uses — rather than keeping a second, parallel implementation here.
    The local copy this replaced held its windows in a module-level dict that was
    never evicted, so every distinct key it ever saw was retained for the life of
    the process. ``_get_client_ip`` derives that key from the client-supplied
    ``X-Forwarded-For`` header, so a caller rotating that header grew the dict
    without bound (and, separately, side-stepped the cap — see the deployment
    note in docs/verification about terminating-proxy trust).

    Limit and window are unchanged: ``IP_RATE_LIMIT_PER_MIN`` (default 20) over
    60 seconds. ``_IP_RATE_LIMIT`` is read at call time so tests can monkeypatch
    it. One deliberate semantic delta: the shared limiter records the attempt
    even when it is rejected, so sustained flooding keeps the window extended
    instead of letting an attacker pace exactly at the cap — this is already how
    ``/v1/register`` behaves.
    """
    allowed, _ = rate_limit.check_ip_rate(_IP_RATE_SCOPE, ip, _IP_RATE_LIMIT, 60.0)
    return allowed


def _analysis_cache_key(internal: AnalyzeRequest, *, locale: str, provider: str) -> str:
    """Cache identity for one ``/api/analyze`` response.

    ``response_cache`` is a GLOBAL, account-agnostic table keyed ONLY by this
    digest (see ``store.get_cached_response``), so the key must cover every
    input that can shape the provider's output. Any prompt-shaping field left
    out of the key lets one caller's cached response be served verbatim to a
    DIFFERENT account.

    That is not hypothetical: ``thread_context`` (the other party's message),
    ``recipient_hint``, and ``context_hints`` (facts inferred from the caller's
    private history) all reach the provider through ``build_system_prompt`` /
    ``build_user_prompt``. A key built from only (text, axes, voice, locale)
    therefore let account B receive a rewrite shaped by account A's private
    thread and inferred personal patterns.

    The key is derived from the canonical ``AnalyzeRequest`` that is actually
    handed to the provider, so a field added to that model is covered
    automatically instead of silently widening the leak again. ``locale`` and
    ``provider`` are wire-level inputs that are not carried on the internal
    model, so they are mixed in explicitly under reserved keys.

    Two requests share an entry only when their ENTIRE provider input is
    byte-identical — so the requester already possesses every input the cached
    answer was derived from, and no private data can cross accounts.
    """
    payload: dict[str, Any] = internal.model_dump(mode="json")
    # Reserved keys — the leading NULs cannot collide with a pydantic field name.
    payload["\x00locale"] = locale
    payload["\x00provider"] = provider
    raw = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------------


# Privacy-safe phase timings (P0 t_76fd6364 / t_79f14548).
#
# Logs ONLY: phase name, request id (random per-request UUID), duration
# in milliseconds. Never logs: request text, tokens, device id, account
# id, IP, provider response body, user agent, or anything else that
# could correlate to a specific user or message. The request id is
# generated locally and is not shared with the provider.
# ---------------------------------------------------------------------------

# Phase-name constants — kept short so log lines stay one-liners.
_PHASE_REQUEST_ACCEPTED = "request_accepted"
_PHASE_PROVIDER_START = "provider_start"
_PHASE_PROVIDER_END = "provider_end"
_PHASE_VALIDATION_END = "validation_end"
_PHASE_RESPONSE_SENT = "response_sent"

# P0 BUILD-95: additional phase for the selected-variant endpoint. The
# variant handler emits a ``preflight_end`` phase BEFORE ``provider_start``
# so we can measure preflight latency (deterministic, zero provider calls)
# separately from provider latency. Phase ordering for the new endpoint:
#   request_accepted -> preflight_end -> provider_start -> provider_end -> response_sent
_PHASE_PREFLIGHT_END = "preflight_end"


def _new_request_id() -> str:
    """Per-request UUID4. Not persisted; only used to correlate the
    five phase-timing log lines emitted for each analyze request.
    """
    return uuid.uuid4().hex


def _log_phase(request_id: str, phase: str, t_start: float) -> None:
    """Emit a privacy-safe phase-timing log line.

    Format: ``tono.phase request_id=<hex> phase=<phase> dt_ms=<int>``
    No payload data, no identifiers other than the local request id.
    """
    dt_ms = int((time.time() - t_start) * 1000)
    logger.info(
        "tono.phase request_id=%s phase=%s dt_ms=%d",
        request_id, phase, dt_ms,
    )


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
    store = get_store()  # opens + migrates the DB

    # Operational account backfill (contract §1). Runs transactionally and
    # idempotently on every startup BEFORE any purchase/register route is
    # served, so no legacy device is left with a NULL entitlement principal.
    try:
        backfill = store.backfill_missing_accounts()
        store.backfill_stripe_trial_ledger()
        if backfill.get("backfilled"):
            logger.info(
                "account backfill: linked %s legacy device(s); %s remain null",
                backfill["backfilled"], backfill["remaining_null"],
            )
    except Exception:  # never block startup on a backfill hiccup — it retries next boot
        logger.exception("account backfill failed on startup; will retry next boot")

    # Best-effort drain of pending Set-App-Account-Token operations recorded
    # after tokenless legacy claims (contract §5/§9). Only runs when the App
    # Store Server API is configured; a transient failure leaves the op retriable
    # and NEVER erases an already-verified entitlement.
    try:
        sender = app_store.get_set_token_sender()
        if sender is not None:
            tally = app_store.reconcile_set_app_account_token(store, sender)
            if tally.get("succeeded") or tally.get("failed"):
                logger.info("set-app-account-token reconcile: %s", tally)
    except Exception:
        logger.exception("set-app-account-token reconcile failed on startup; will retry")

    # Best-effort drain of pending Google Play acknowledge ops (contract §5).
    # Only runs when the Play Developer API is configured; a transient failure
    # leaves the op retriable and NEVER erases an already-verified entitlement.
    try:
        gverifier = google_play.get_reconcile_verifier()
        if gverifier is not None:
            gtally = google_play.reconcile_google_acknowledgements(
                store, gverifier, google_play.get_google_play_config()
            )
            if any(gtally.values()):
                logger.info("google-play acknowledge reconcile: %s", gtally)
    except Exception:
        logger.exception("google-play acknowledge reconcile failed on startup; will retry")

    logger.info(
        # Build 114 adds `email=`. A project missing its auth configuration
        # fails closed at 503, which a person meets as "email sign-in isn't
        # available" — truthful, but the first place anyone would notice was a
        # real signup. Saying it at boot makes the misconfiguration visible
        # before it costs a registration. It logs the WORD "configured", never
        # the key.
        "tono backend ready: provider=%s stripe=%s slack=%s apple=%s google=%s email=%s",
        os.environ.get("TONO_PROVIDER", "mock"),
        "configured" if os.environ.get("STRIPE_SECRET_KEY") else "off",
        "configured" if os.environ.get("SLACK_CLIENT_ID") else "off",
        "configured" if os.environ.get("TONO_APPLE_ROOT_CA_PEM") else "off",
        "configured" if os.environ.get("TONO_GOOGLE_SERVICE_ACCOUNT_JSON") else "off",
        "configured" if email_auth.config_is_valid() else "off",
    )
    try:
        yield
    finally:
        # Drain the pooled provider keep-alive connections on a graceful stop
        # so shutdown closes them instead of dropping sockets. Best-effort:
        # a transport hiccup here must never mask a real shutdown error or
        # prevent the store from being closed.
        try:
            await aclose_provider_client()
        except Exception:
            logger.exception("provider client close failed during shutdown")
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
# for local development but should be locked down to real origins in
# production once apps/web has a deployed domain.
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
  <li><strong>Subscription status</strong> — entitlement state and renewal date, via StoreKit 2 (iOS), Google Play, or Stripe (web).</li>
</ul>

<h2>What we do not collect</h2>
<ul>
  <li>Message content (drafts are analyzed and discarded immediately)</li>
  <li>Recipient names or contact data</li>
  <li>Precise location</li>
  <li>Browsing history or cross-app behavior</li>
</ul>

<h2>How your data is used</h2>
<p>Device IDs are used solely to associate your subscription entitlement with your device. Aggregate usage counts may be used to improve the product. No data is sold to or shared with third parties for advertising.</p>

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
    provenance = _build_provenance()
    return {
        "status": "ok",
        "ts": int(time.time()),
        "id": str(uuid.uuid4())[:8],
        "version": "0.3.0",
        "canonical_sha": provenance["canonical_sha"],
        "contract_sha256": provenance["contract_sha256"],
        "schema_revision": provenance["schema_revision"],
        "stripe_configured": bool(os.environ.get("STRIPE_SECRET_KEY")),
        "slack_configured": bool(os.environ.get("SLACK_CLIENT_ID")),
        "apple_configured": bool(os.environ.get("TONO_APPLE_ROOT_CA_PEM")),
        "google_play_configured": bool(os.environ.get("TONO_GOOGLE_SERVICE_ACCOUNT_JSON")),
    }


@app.get("/build-provenance.json", include_in_schema=False)
async def build_provenance() -> JSONResponse:
    return JSONResponse(
        content=_build_provenance(),
        headers={"Cache-Control": "public, max-age=31536000, immutable"},
    )


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
async def v1_analyze(
    req: AnalyzeRequest,
    request: Request,
    user: CurrentUser,
) -> dict[str, Any]:
    """Tone-analysis passthrough kept for backward compatibility with the
    host-app Playground tab and integration tests. There is NO anonymous or
    free rewrite path: the caller must present a valid bearer token
    (``CurrentUser`` -> 401 otherwise) AND hold a server-authoritative rewrite
    entitlement (the shared gate -> a DISTINCT 402 otherwise), both enforced
    BEFORE the per-IP window and BEFORE any provider invocation. Mirrors the
    gate on /api/analyze and /api/analyze/variant, so this route can never be
    the free/anonymous rewrite bypass it once was.
    """
    # Shared server-authoritative entitlement gate — the SAME chokepoint as
    # /api/analyze and /api/analyze/variant. Fail closed with an honest 402
    # (never the IP-rate 429) BEFORE the per-IP window and BEFORE any provider
    # call. Registration / sign-in is a PRINCIPAL, not a grant.
    _require_rewrite_entitlement(user)

    if not _check_ip_rate(_get_client_ip(request)):
        raise HTTPException(
            status_code=429,
            detail="Too many requests. Please retry in a minute.",
            headers={"Retry-After": "60"},
        )
    provider = os.environ.get("TONO_PROVIDER", "mock")
    try:
        if req.optional_variants is not None:
            # Build 94 is always safer-first Sonnet in production. Mock remains
            # available for deterministic offline tests; OpenAI is never used.
            if provider == "mock":
                return await mock_variant_analyze(req)
            return await anthropic_analyze(req)
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
    device_id: Optional[uuid.UUID] = None
    device_credential: Optional[str] = Field(default=None, min_length=43, max_length=256)
    app_version: Optional[str] = Field(default=None, max_length=64)
    platform: Optional[Literal["ios", "android", "macos", "windows", "web", "slack"]] = None


class RegisterResponse(BaseModel):
    device_id: str
    api_token: str
    device_credential: Optional[str] = None
    plan: str
    is_pro: bool
    # Server-issued immutable anonymous account UUID — the only entitlement
    # principal, and what new purchases bind as appAccountToken (contract §1).
    account_id: str


@app.post("/v1/register", response_model=RegisterResponse)
def register(body: RegisterRequest, request: Request, store: StoreDep) -> RegisterResponse:
    ip = _get_client_ip(request)
    allowed, _ = rate_limit.check_ip_rate(
        "register", ip, rate_limit.RATE_SCOPES["register"]
    )
    if not allowed:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="registration rate limit exceeded",
            headers={"Retry-After": "60"},
        )

    authorization = request.headers.get("Authorization", "")
    scheme, _, supplied_token = authorization.partition(" ")
    bearer_token = supplied_token if scheme.lower() == "bearer" else None
    try:
        registration = store.register_device(
            str(body.device_id) if body.device_id else None,
            device_credential=body.device_credential,
            bearer_token=bearer_token,
            legacy_grace_seconds=int(
                os.environ.get("TONO_LEGACY_TOKEN_GRACE_SECONDS", "86400")
            ),
        )
    except DeviceRegistrationProofError as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="device registration requires recovery proof",
        ) from exc

    user = registration.user
    if not user.account_id:
        # Registration must always yield a canonical account (contract §1).
        # This should be unreachable — surfacing it fails closed rather than
        # returning a device with no entitlement principal.
        raise HTTPException(
            status.HTTP_500_INTERNAL_SERVER_ERROR, "registration did not establish an account"
        )
    return RegisterResponse(
        device_id=user.device_id,
        api_token=user.api_token,
        device_credential=registration.device_credential,
        plan=user.plan_resolved,
        is_pro=user.is_pro,
        account_id=user.account_id,
    )


class MeResponse(BaseModel):
    device_id: str
    plan: str
    is_pro: bool
    used_today: int
    daily_limit: int  # -1 = unlimited
    subscription_status: Optional[str]
    subscription_renews_at: Optional[str]
    coupon_pro_expires_at: Optional[str]
    # Required non-null after migration — the canonical entitlement principal
    # (contract §1). A null here is a contract violation.
    account_id: str
    # Build 114 — account-path projection. Optional so a legacy/anonymous
    # device is described truthfully rather than with a fabricated address.
    email: Optional[str] = None
    email_verified_at: Optional[str] = None
    lifecycle_state: str = "anonymous"


@app.get("/v1/me", response_model=MeResponse)
def me(user: CurrentUser, store: StoreDep) -> MeResponse:
    # Defensive: a legacy device registered before the account-first contract
    # may still carry a null account_id until migration runs. Backfill on read
    # so /v1/me never returns a null principal (contract §1).
    if not user.account_id:
        reloaded = store.ensure_account(user.device_id)
        if reloaded is not None:
            user = reloaded
    # Field resolution (identified-account routing, entitlement grants, pooled
    # quota) lives in the shared entitlement projection so /v1/me and the App
    # Store endpoint always agree.
    return MeResponse(**compute_me_fields(user, store))


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
    """Shared by /v1/auth/apple, /v1/auth/google, /v1/auth/web and the email
    login. `link=False` (plain sign-in) always succeeds and switches the
    calling device to whichever account owns this identity — creating one on
    first use. `link=True` requires the device to already be signed in and
    refuses (409) to attach an identity that already belongs to someone else's
    account.

    Resolution order for a plain sign-in, most specific first:

      1. an account that ALREADY owns this provider subject;
      2. the account that RESERVED this subject when it started an email
         registration, before anyone had proved the address;
      3. the calling device's own anonymous account, upgraded in place;
      4. a brand-new account.

    Step 2 is Build 114's correction. The verification click arrives in a
    browser with no bearer and no session, so steps 3 and 4 were the only ones
    reachable there — and step 4 minted a second canonical account, orphaning
    the one the person had been using. It is placed ABOVE step 3 deliberately:
    the browser that opens the link has an anonymous account of its own (it was
    just minted to carry the request), and that throwaway must never outrank the
    account that actually started the registration.
    """
    try:
        if link:
            if not user.account_id:
                raise HTTPException(
                    status.HTTP_400_BAD_REQUEST, "sign in before linking another provider"
                )
            account = store.upsert_account_by_provider(
                provider, sub, email, link_into_account_id=user.account_id
            )
        else:
            existing = store.get_account_by_provider(provider, sub)
            claimant = (
                None if existing is not None
                else store.claim_pending_registration_account(sub)
            )
            if existing is not None:
                # Plain sign-in: switch to (or reuse) the account that already
                # owns this identity — never a conflict (existing behavior).
                account = existing
            elif claimant is not None:
                # The account that started this registration gets the identity
                # it reserved, whichever surface finally proved the address.
                account = store.upsert_account_by_provider(
                    provider, sub, email, link_into_account_id=claimant
                )
            elif user.account is not None and not user.account.is_identified:
                # Brand-new identity while on an anonymous auto-account: upgrade
                # that account IN PLACE so its UUID, history, and entitlement
                # grants carry over (contract §1, hostile 4).
                account = store.upsert_account_by_provider(
                    provider, sub, email, link_into_account_id=user.account_id
                )
            else:
                # Brand-new identity while already identified: mint a fresh
                # account and switch to it.
                account = store.upsert_account_by_provider(provider, sub, email)
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
    refreshed = store.get_by_device(user.device_id) or user
    projection = compute_me_fields(refreshed, store)
    return SignInResponse(account_id=account.id, plan=projection["plan"], is_pro=projection["is_pro"], email=account.email)


@app.post("/v1/auth/google", response_model=SignInResponse)
async def auth_google(
    body: GoogleSignInRequest,
    user: CurrentUser,
    store: StoreDep,
    verifier: Annotated[social_auth.IdentityVerifier, Depends(social_auth.get_google_verifier)],
) -> SignInResponse:
    claims = await verifier(body.id_token)
    account = _resolve_provider_signin(store, user, "google", claims.sub, claims.email, body.link)
    refreshed = store.get_by_device(user.device_id) or user
    projection = compute_me_fields(refreshed, store)
    return SignInResponse(account_id=account.id, plan=projection["plan"], is_pro=projection["is_pro"], email=account.email)


# ---------------------------------------------------------------------------
# Web account sign-in (Supabase). The website authenticates a person with
# Supabase (Apple/Google/magic-link) and forwards the Supabase access token
# here. We verify it cryptographically, then converge the browser onto the
# ONE canonical account keyed by the Supabase user id — so the same person on
# a second browser lands on the identical account_id. Unlike /v1/auth/apple,
# the caller need not already hold a device bearer: a fresh browser has none,
# so we register a random per-browser device (durable credential) and return
# its bearer for the web app to store in an httpOnly cookie.
# ---------------------------------------------------------------------------


class WebSignInRequest(BaseModel):
    access_token: str
    # Build 114 — so a web sign-in is recorded on the same registration ledger
    # the native surfaces write to. Optional: an older web build sends neither
    # and is described as `web`/no-build rather than rejected.
    app_version: Optional[str] = None


class WebSignInResponse(BaseModel):
    device_id: str
    api_token: str
    device_credential: Optional[str] = None
    account_id: str
    plan: str
    is_pro: bool
    email: Optional[str] = None


@app.post("/v1/auth/web", response_model=WebSignInResponse)
async def auth_web(
    body: WebSignInRequest,
    user: OptionalCurrentUser,
    store: StoreDep,
    verifier: Annotated[
        supabase_auth.SupabaseVerifier, Depends(supabase_auth.get_supabase_verifier)
    ],
) -> WebSignInResponse:
    # Fail closed: an invalid/expired/wrong-audience token raises 401 inside
    # the verifier before we touch any account state.
    claims = await verifier(body.access_token)

    # NEVER merge on an unverified email: Supabase dedupes identities onto one
    # user by *verified* email, and account resolution keys on the immutable
    # ``sub`` — but we still refuse to persist an unverified address as contact
    # data, so it can't leak into email-based flows later.
    email = claims.email if claims.email_verified else None

    # A fresh browser carries no device bearer — mint a random per-browser
    # device with a durable credential. A returning browser that presented a
    # valid bearer reuses its device (so its anonymous account upgrades in
    # place rather than orphaning).
    device_credential: Optional[str] = None
    if user is None:
        registration = store.register_device()
        user = registration.user
        device_credential = registration.device_credential

    # Reuse the exact provider-linking primitive Apple/Google use: same-subject
    # convergence, anonymous-account upgrade-in-place, and 409-on-collision all
    # come for free (link=False = plain sign-in).
    account = _resolve_provider_signin(store, user, "supabase", claims.sub, email, link=False)

    # Build 114 — one registration ledger for every surface. A person who signs
    # up on the website is a registration Tono must be able to count and audit,
    # exactly like an iOS or Android one; before this, only the native email
    # path wrote a row, so the web population was invisible. Records the fact
    # the provider proved (a confirmed address) and never the token that carried
    # it. `record_registration_event` is monotonic, so a returning browser adds
    # a sign-in event without ever walking the state back.
    if email:
        with contextlib.suppress(AccountConflictError):
            store.mark_email_verified(
                account_id=account.id,
                email=email,
                source_surface=email_identity.SURFACE_WEB,
                app_version=body.app_version,
            )
    store.record_registration_event(
        account_id=account.id,
        event_type=email_identity.EVENT_SIGN_IN,
        source_surface=email_identity.SURFACE_WEB,
        app_version=body.app_version,
    )

    # Project the entitlement through the SAME authority `/v1/me` and the email
    # login use, by re-reading the device now that it has been re-linked.
    #
    # `account.is_pro` alone is not the entitlement answer: it reads
    # plan/subscription/coupon, which is the Stripe-shaped half. An App Store or
    # Play subscription attaches to the canonical account as a provider
    # ENTITLEMENT GRANT, and only `User.is_pro` (via `_attach_account`'s
    # `provider_entitlement_active`) accounts for it. Returning the raw account
    # projection here told every mobile subscriber who signed in on the website
    # `is_pro: false` — the same defect the email login already documents and
    # fixes, left in place on its sibling.
    refreshed = store.get_by_device(user.device_id) or user
    projection = compute_me_fields(refreshed, store)

    return WebSignInResponse(
        device_id=user.device_id,
        api_token=user.api_token,
        device_credential=device_credential,
        account_id=account.id,
        plan=projection["plan"],
        is_pro=projection["is_pro"],
        email=account.email,
    )


# ---------------------------------------------------------------------------
# Build 114 — email registration, verification, login, reset, logout.
#
# One architecture, not a second login silo. Supabase keeps owning auth.users,
# the password material and the verification/reset mail (see email_auth.py);
# this server keeps owning the canonical account. Every endpoint below ends in
# the SAME `_resolve_provider_signin` primitive that Apple/Google/web sign-in
# uses, so an email login converges on the identical canonical person and the
# identical entitlement projection. Nothing here writes a plan, a subscription
# column, or a grant: verification proves an address, never a purchase.
#
# Anti-enumeration: register, resend and reset ALWAYS answer with the same
# accepted shape for a known and an unknown address. The only ways these
# endpoints answer differently are ones that carry no information about whether
# an account exists: being throttled (429) and the provider being down (503),
# both already observable from outside, and a refusal of the submitted string
# itself (400 — malformed address, password the provider calls too weak), which
# describes what the person just typed and nothing else.
# ---------------------------------------------------------------------------


# One bounded budget per email-auth family, so a flood against `login` cannot
# starve a legitimate `resend`, and a per-address lockout bounds brute force
# independently of how many IPs the attacker rotates through.
_EMAIL_AUTH_IP_LIMIT = rate_limit.RATE_SCOPES["auth"]
_EMAIL_AUTH_KEY_LIMIT = rate_limit.OTP_LOCKOUT_LIMIT
_EMAIL_AUTH_KEY_WINDOW = rate_limit.OTP_LOCKOUT_WINDOW


def _email_auth_rate_gate(request: Request, scope: str, normalized_email: Optional[str]) -> None:
    """Bound attempts per IP and per address. Raises 429 — which the clients
    render as wait-and-retry, never as a credential failure and never as a
    paywall (Build 113's protected property)."""
    ip = _get_client_ip(request)
    allowed, _ = rate_limit.check_ip_rate(f"email_{scope}", ip, _EMAIL_AUTH_IP_LIMIT)
    if not allowed:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="too many attempts — try again in a minute",
            headers={"Retry-After": "60"},
        )
    if normalized_email:
        allowed, _ = rate_limit.check_keyed_rate(
            f"email_{scope}",
            normalized_email,
            _EMAIL_AUTH_KEY_LIMIT,
            _EMAIL_AUTH_KEY_WINDOW,
        )
        if not allowed:
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail="too many attempts — try again shortly",
                headers={"Retry-After": str(_EMAIL_AUTH_KEY_WINDOW)},
            )


def _email_auth_failure(outcome: email_auth.EmailAuthOutcome) -> HTTPException:
    """Map a provider outcome to a status the clients already know how to
    render. The provider's own message is never consulted, so no provider or
    transport text can reach a screen.

    Note what is deliberately absent: there is no branch that turns a provider
    outage into "we sent you an email". An operational failure is always 503.
    """
    if outcome is email_auth.EmailAuthOutcome.RATE_LIMITED:
        return HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="too many attempts — try again shortly",
            headers={"Retry-After": "60"},
        )
    if outcome is email_auth.EmailAuthOutcome.VERIFICATION_REQUIRED:
        return HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="email_verification_required"
        )
    # Input-shaped refusals get a plain, actionable answer. They describe the
    # string the person just typed — never an account — so they are not
    # enumeration signals, and they must NOT ride the anti-enumerating
    # "verification_pending" path: telling someone to check their inbox when
    # the provider refused the request is the one failure they can never
    # recover from on their own.
    if outcome is email_auth.EmailAuthOutcome.WEAK_PASSWORD:
        return HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="choose a stronger password and try again",
        )
    if outcome is email_auth.EmailAuthOutcome.INVALID_EMAIL:
        return HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="that email address can't be used — try another",
        )
    if outcome in (
        email_auth.EmailAuthOutcome.NOT_CONFIGURED,
        email_auth.EmailAuthOutcome.PROVIDER_UNAVAILABLE,
    ):
        return HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="email sign-in is temporarily unavailable",
        )
    return HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid_credentials")


def _require_email(raw: str) -> str:
    normalized = store_module.normalize_email(raw)
    if not normalized:
        # Shape-only rejection. This is NOT enumeration: it says the string is
        # not an address, which the caller can see for themselves.
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "enter a valid email address")
    return normalized


def _require_password(raw: str) -> str:
    # A floor, not a policy lecture: the provider enforces its own rules and we
    # never store or hash the value. Bounded above so a multi-megabyte body
    # cannot be pushed through to the provider.
    if len(raw) < 8:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST, "use at least 8 characters for your password"
        )
    if len(raw) > 512:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "that password is too long")
    return raw


class EmailRegisterRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    email: str
    password: str
    source_surface: Optional[str] = None
    app_version: Optional[str] = None
    promo_code: Optional[str] = None


class EmailAcceptedResponse(BaseModel):
    """The single anti-enumerating answer for register / resend / reset.

    `status` is a constant. There is intentionally no field that varies with
    whether the address exists, whether it is already verified, or whether the
    person has an account — those are exactly the bits an attacker wants.
    """

    status: Literal["verification_pending"] = "verification_pending"


class EmailSessionResponse(BaseModel):
    device_id: str
    api_token: str
    device_credential: Optional[str] = None
    account_id: str
    plan: str
    is_pro: bool
    email: Optional[str] = None
    email_verified: bool = False


@app.post(
    "/v1/auth/email/register",
    response_model=EmailAcceptedResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
async def auth_email_register(
    body: EmailRegisterRequest,
    request: Request,
    user: OptionalCurrentUser,
    store: StoreDep,
    client: Annotated[
        email_auth.SupabaseEmailAuthClient, Depends(email_auth.get_email_auth_client)
    ],
) -> EmailAcceptedResponse:
    """Start an email registration.

    Answers `verification_pending` for every outcome that depends on whether
    the address is already registered — which is the whole anti-enumeration
    property. It does NOT answer that way when the provider refused the
    submitted address or password on its own validation rules: that is a fact
    about the input, and reporting it is the difference between a person
    fixing their password and a person waiting forever for mail that was
    never sent.

    The canonical account is bound here, BEFORE verification, so that an
    anonymous device that has been coaching drafts for weeks upgrades in place
    — its account UUID, history, usage and any purchase ownership all survive
    the registration. The account stays in the `pending` lifecycle state and
    unidentified until the person proves the address, so binding early costs
    no access.
    """
    normalized = _require_email(body.email)
    password = _require_password(body.password)
    _email_auth_rate_gate(request, "register", normalized)

    try:
        signup = await client.sign_up(email=normalized, password=password)
    except email_auth.EmailAuthError as exc:
        if exc.outcome is email_auth.EmailAuthOutcome.INVALID_CREDENTIALS:
            # Supabase answers 4xx for "already registered". Revealing that
            # would enumerate the address, so we record the attempt and return
            # the same accepted shape a brand-new address gets. A person who
            # genuinely owns it still receives provider mail; one who does not
            # learns nothing.
            #
            # No provider subject is available on this branch, and that is the
            # right outcome rather than a gap: the provider refused to create
            # anything, so there is no new identity to reserve, and an existing
            # account's binding is left exactly as it was. It is specifically
            # what stops a stranger who types someone else's address from
            # claiming the verification that address is already waiting for.
            _record_email_registration_intent(
                store, user, normalized, body.source_surface, body.app_version
            )
            return EmailAcceptedResponse()
        _record_provider_outage(
            store,
            exc.outcome,
            account_id=user.account_id if user else None,
            source_surface=body.source_surface,
            app_version=body.app_version,
        )
        raise _email_auth_failure(exc.outcome) from None

    if user is not None:
        _record_email_registration_intent(
            store,
            user,
            normalized,
            body.source_surface,
            body.app_version,
            provider_subject=signup.provider_user_id,
            promo_code=body.promo_code,
        )
    else:
        # A bearer-less web signup still gets a pending canonical principal,
        # but not a fake device slot. The provider-subject claim is what the
        # later verified callback resolves; no credential is minted/exposed.
        pending = store.create_bare_account()
        with contextlib.suppress(AccountConflictError):
            store.begin_email_registration(
                account_id=pending.id,
                email=normalized,
                source_surface=body.source_surface,
                app_version=body.app_version,
                provider_subject=signup.provider_user_id,
                pending_coupon_code=body.promo_code,
            )
    return EmailAcceptedResponse()


def _record_email_registration_intent(
    store: Store,
    user: Optional[User],
    normalized_email: str,
    source_surface: Optional[str],
    app_version: Optional[str],
    *,
    provider_subject: Optional[str] = None,
    promo_code: Optional[str] = None,
) -> None:
    """Move the CALLER'S existing canonical account into `pending`, when there
    is one, and reserve the provider identity the signup just created for it.

    A bearer-less web signup is assigned a pending anonymous canonical account
    by the caller after provider signup succeeds. The subject claim below makes
    the later verified callback converge onto it without exposing a credential.

    ``provider_subject`` is what makes the anonymous upgrade real. Binding only
    the ADDRESS was not enough, because the step that proves the address happens
    somewhere this account is not: the person opens the link from their mail app,
    which lands in a browser carrying no bearer and no session. With nothing tying
    that click back to the caller, it minted a fresh canonical account and the
    person's own one — the one holding their history, usage and any purchase —
    was orphaned at the exact step the product's UI instructs. The subject is the
    one durable thing both halves of that sequence can see.

    It is recorded on the registration row and NOT on `accounts`: the account must
    stay unidentified and its lifecycle must keep reading `pending` until the
    address is actually proven. See `store.begin_email_registration`.

    Never raises into the response: an audit write must not be able to turn a
    successful registration into a visible failure, and a conflict here (the
    account already has a different verified address) is a legitimate refusal
    to re-point a live identity, not a reason to tell the caller anything.
    """
    if user is None or not user.account_id:
        return
    with contextlib.suppress(AccountConflictError):
        store.begin_email_registration(
            account_id=user.account_id,
            email=normalized_email,
            source_surface=source_surface,
            app_version=app_version,
            provider_subject=provider_subject,
            pending_coupon_code=promo_code,
        )


# The outcomes that mean "we could not serve this", as opposed to "we served
# it and the answer was no". Kept as one set so every path agrees about which
# failures are operational — a rate limit and a wrong password are emphatically
# not outages, and auditing them as such would make the outage count useless.
_OUTAGE_OUTCOMES = frozenset(
    {
        email_auth.EmailAuthOutcome.PROVIDER_UNAVAILABLE,
        email_auth.EmailAuthOutcome.NOT_CONFIGURED,
    }
)


def _record_provider_outage(
    store: Store,
    outcome: email_auth.EmailAuthOutcome,
    *,
    account_id: Optional[str],
    source_surface: Optional[str],
    app_version: Optional[str],
) -> None:
    """Audit an attempt the auth provider could not serve.

    Worth writing down because the alternative is that "how many people could
    not register while the provider was down" is unanswerable afterwards — a
    503 that is only ever a status code leaves no trace, and the person who
    never got their link has no way to prove they tried.

    `account_id` is frequently None here, and deliberately so: an
    unauthenticated attempt has no caller account, and an outage is not a
    reason to mint one. The row records that an attempt could not be served;
    it carries no address, so it identifies nobody.

    Swallows everything. An audit write must never be able to turn one failure
    into two, and the caller is already on its way to raising the real one.
    """
    if outcome not in _OUTAGE_OUTCOMES:
        return
    with contextlib.suppress(Exception):
        store.record_registration_event(
            account_id=account_id,
            event_type=email_identity.EVENT_PROVIDER_UNAVAILABLE,
            source_surface=source_surface,
            app_version=app_version,
        )


class EmailLoginRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    email: str
    password: str
    source_surface: Optional[str] = None
    app_version: Optional[str] = None


@app.post("/v1/auth/email/login", response_model=EmailSessionResponse)
async def auth_email_login(
    body: EmailLoginRequest,
    request: Request,
    user: OptionalCurrentUser,
    store: StoreDep,
    client: Annotated[
        email_auth.SupabaseEmailAuthClient, Depends(email_auth.get_email_auth_client)
    ],
    verifier: Annotated[
        supabase_auth.SupabaseVerifier, Depends(supabase_auth.get_supabase_verifier)
    ],
) -> EmailSessionResponse:
    """Sign in with email and password.

    Two independent gates, both fail-closed:

      1. The provider must accept the credentials AND consider the address
         confirmed. Supabase withholds a session for an unconfirmed address,
         which surfaces as 403 `email_verification_required`.
      2. We re-verify the returned access token cryptographically through the
         SAME verifier the web callback uses, and refuse to proceed unless its
         `email_verified` claim is true. So even a misconfigured project with
         confirmations switched off cannot mint a verified identity here.
    """
    normalized = _require_email(body.email)
    password = _require_password(body.password)
    _email_auth_rate_gate(request, "login", normalized)

    try:
        session = await client.sign_in(email=normalized, password=password)
    except email_auth.EmailAuthError as exc:
        if exc.outcome is email_auth.EmailAuthOutcome.VERIFICATION_REQUIRED:
            # The provider knows this address and refused it for the one reason
            # the person can fix. Recorded so "I never got the email" is
            # answerable from the account's own history rather than from a
            # status code nobody kept.
            _record_email_audit(
                store,
                normalized,
                email_identity.EVENT_VERIFICATION_PENDING_BLOCKED,
                body,
                caller=user,
            )
        _record_provider_outage(
            store,
            exc.outcome,
            account_id=user.account_id if user else None,
            source_surface=body.source_surface,
            app_version=body.app_version,
        )
        raise _email_auth_failure(exc.outcome) from None

    claims = await verifier(session.access_token)
    if not claims.email_verified:
        # Gate 2. A project with confirmations switched off can hand back a
        # session for an unproven address; this is where that is refused, and
        # it is the same refusal a person sees from gate 1, audited the same
        # way — the two must not be distinguishable from outside.
        _record_email_audit(
            store,
            normalized,
            email_identity.EVENT_VERIFICATION_PENDING_BLOCKED,
            body,
            caller=user,
        )
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="email_verification_required"
        )

    # A successful login clears the per-address lockout so a person who simply
    # mistyped once is not held out by their own earlier attempts.
    rate_limit.reset_keyed_rate("email_login", normalized)

    device_credential: Optional[str] = None
    if user is None:
        registration = store.register_device()
        user = registration.user
        device_credential = registration.device_credential

    verified_email = claims.email or normalized
    account = _resolve_provider_signin(
        store, user, "supabase", claims.sub, verified_email, link=False
    )
    try:
        account = store.mark_email_verified(
            account_id=account.id,
            email=verified_email,
            source_surface=body.source_surface,
            app_version=body.app_version,
        )
    except AccountConflictError:
        # The address is already the verified identity of a DIFFERENT canonical
        # account — a second provider subject presenting the same spelling. The
        # store is right to refuse (merging would hand this person someone
        # else's history and entitlement), but the refusal has to arrive as a
        # reviewed consumer answer.
        #
        # Uncaught, this propagated as a raw 500: the one shape Build 112
        # established must never reach a screen, and the least recoverable one
        # here — a person cannot tell "the server broke" from "try again later"
        # and has no next step either way. 409 carries the shared vocabulary
        # code the clients already map to "this address is spoken for; sign in
        # the way you did before, or use a different address".
        #
        # `mark_email_verified` has already written the `identity_conflict`
        # audit event, so the refusal is visible to support without the
        # response having to describe the other account in any way.
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=email_identity.OUTCOME_ACCOUNT_CONFLICT,
        ) from None
    store.record_registration_event(
        account_id=account.id,
        event_type=email_identity.EVENT_SIGN_IN,
        source_surface=body.source_surface,
        app_version=body.app_version,
    )

    # Project the entitlement through the SAME authority `/v1/me` uses, by
    # re-reading the device now that it has been re-linked.
    #
    # `Account.is_pro` alone is not the entitlement answer and never was. It
    # reads plan/subscription/coupon, which is the Stripe-shaped half; an
    # Apple or Play subscription attaches to the canonical account as a
    # provider ENTITLEMENT GRANT, and only `User.is_pro` (via
    # `_attach_account`'s `provider_entitlement_active`) accounts for it.
    #
    # Returning `account.is_pro` therefore told every returning App Store and
    # Play subscriber `is_pro: false` at the exact moment they signed back in to
    # recover their subscription — the reinstall case this whole lane exists to
    # serve. Re-reading here is what makes a login a genuine entitlement
    # refresh, and what makes a same-account 402 resolve in one call instead of
    # needing a Restore tap.
    refreshed = store.get_by_device(user.device_id) or user
    projection = compute_me_fields(refreshed, store)
    return EmailSessionResponse(
        device_id=user.device_id,
        api_token=user.api_token,
        device_credential=device_credential,
        account_id=account.id,
        plan=projection["plan"],
        is_pro=projection["is_pro"],
        email=account.email,
        email_verified=account.email_is_verified,
    )


class EmailAddressRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    email: str
    source_surface: Optional[str] = None
    app_version: Optional[str] = None


@app.post(
    "/v1/auth/email/resend",
    response_model=EmailAcceptedResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
async def auth_email_resend(
    body: EmailAddressRequest,
    request: Request,
    user: OptionalCurrentUser,
    store: StoreDep,
    client: Annotated[
        email_auth.SupabaseEmailAuthClient, Depends(email_auth.get_email_auth_client)
    ],
) -> EmailAcceptedResponse:
    """Resend the verification link. Anti-enumerating: an unknown address and
    an already-verified address produce the identical accepted answer.

    The bearer is OPTIONAL and changes nothing a caller can observe — the
    response, the rate gate and the provider call are identical with and without
    it. It is read only to decide whether this caller's `source_surface` claim
    may be attributed to the account being audited (see `_record_email_audit`).
    """
    normalized = _require_email(body.email)
    _email_auth_rate_gate(request, "resend", normalized)
    try:
        await client.resend_verification(email=normalized)
    except email_auth.EmailAuthError as exc:
        if exc.outcome is email_auth.EmailAuthOutcome.INVALID_CREDENTIALS:
            return EmailAcceptedResponse()
        if exc.outcome in _OUTAGE_OUTCOMES:
            _record_email_audit(
                store, normalized, email_identity.EVENT_PROVIDER_UNAVAILABLE, body, caller=user
            )
        raise _email_auth_failure(exc.outcome) from None
    _record_email_audit(
        store, normalized, email_identity.EVENT_VERIFICATION_RESENT, body, caller=user
    )
    return EmailAcceptedResponse()


@app.post(
    "/v1/auth/email/reset",
    response_model=EmailAcceptedResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
async def auth_email_reset(
    body: EmailAddressRequest,
    request: Request,
    user: OptionalCurrentUser,
    store: StoreDep,
    client: Annotated[
        email_auth.SupabaseEmailAuthClient, Depends(email_auth.get_email_auth_client)
    ],
) -> EmailAcceptedResponse:
    """Begin password recovery. Anti-enumerating for the same reason as
    resend: the answer is identical whether or not the address is known.

    The link the provider mails lands on the web callback, which recognises a
    recovery and hands the person a screen where they choose and confirm a new
    password (`apps/web/src/app/auth/password`). That destination is the whole
    point of this endpoint: an emailed recovery link with nowhere to set a
    password is a dead end, not a recovery.

    The bearer is optional and observationally inert — see `auth_email_resend`.
    """
    normalized = _require_email(body.email)
    _email_auth_rate_gate(request, "reset", normalized)
    try:
        await client.request_password_reset(email=normalized)
    except email_auth.EmailAuthError as exc:
        if exc.outcome is email_auth.EmailAuthOutcome.INVALID_CREDENTIALS:
            return EmailAcceptedResponse()
        if exc.outcome in _OUTAGE_OUTCOMES:
            _record_email_audit(
                store, normalized, email_identity.EVENT_PROVIDER_UNAVAILABLE, body, caller=user
            )
        raise _email_auth_failure(exc.outcome) from None
    _record_email_audit(
        store, normalized, email_identity.EVENT_PASSWORD_RESET_REQUESTED, body, caller=user
    )
    return EmailAcceptedResponse()


def _record_email_audit(
    store: Store,
    normalized_email: str,
    event: str,
    body: "EmailAddressRequest | EmailLoginRequest",
    *,
    caller: Optional[User] = None,
) -> None:
    """Audit an address-scoped event against the account(s) that already own
    the address. Writes nothing when the address is unknown — which is also why
    this cannot become an enumeration oracle: the caller's response is
    identical either way, and the write is invisible to them.

    Takes either request shape because it reads only the two audit fields both
    carry (surface and build) and never the credentials one of them also has.

    ATTESTATION. These endpoints are reachable with no bearer at all, by design
    — a person who has forgotten their password cannot be asked to prove who
    they are first. That makes `source_surface` and `app_version` claims about
    an account the caller has not shown any right to describe, and the row they
    landed on is somebody else's: a bearer-less reset naming `android`/`666`
    rewrote a victim's `('ios','114')` registration outright.

    So a write is attributed ONLY when the caller presented a bearer for the
    very account being written. Everything else is recorded as unattributed —
    the event still happened and is still worth auditing, but Tono does not
    restate a stranger's claim as an observation. `store` enforces the rest:
    with `attested=False` the surface and build are dropped rather than
    written, and `source_surface` is immutable regardless.
    """
    caller_account = caller.account_id if caller is not None else None
    for account in store.find_accounts_by_email(normalized_email):
        store.record_registration_event(
            account_id=account.id,
            event_type=event,
            source_surface=body.source_surface,
            app_version=body.app_version,
            attested=account.id == caller_account,
        )


class EmailLogoutResponse(BaseModel):
    signed_out: bool


@app.post("/v1/auth/email/logout", response_model=EmailLogoutResponse)
def auth_email_logout(user: CurrentUser, store: StoreDep) -> EmailLogoutResponse:
    """Sign this DEVICE out, and mean it.

    Deliberately local and provider-independent: the bearer the caller just
    presented stops working before this returns, so logging out of a shared
    device never depends on a reachable provider or a good network.

    `sign_out_device` is used rather than `rotate_token` because rotating alone
    is not a sign-out: the device also holds a durable credential that lets it
    re-register itself into the same row, so the next `/v1/register` would hand
    it a working bearer for an account it was just signed out of. See the store
    method for the full argument.

    The canonical account, its history, its entitlement and its registration
    audit are untouched — signing back in returns the person to exactly the
    same account. The sign-out event is recorded BEFORE the unlink, while the
    account is still known.
    """
    if user.account_id:
        store.record_registration_event(
            account_id=user.account_id,
            event_type=email_identity.EVENT_SIGN_OUT,
        )
    store.sign_out_device(user.device_id)
    return EmailLogoutResponse(signed_out=True)


class RegistrationEventsResponse(BaseModel):
    account_id: str
    lifecycle_state: str
    email_verified: bool
    events: list[dict]


@app.get("/v1/account/registration-events", response_model=RegistrationEventsResponse)
def account_registration_events(
    user: CurrentUser, store: StoreDep
) -> RegistrationEventsResponse:
    """The caller's OWN registration/verification history.

    Scoped by the bearer's account — there is no account id parameter, so one
    person cannot read another's history. Every row carries a timestamp, the
    source surface and the app build; none carries a password, a token or a
    verification link (see the `account_registration_events` table comment).
    """
    if not user.account_id:
        reloaded = store.ensure_account(user.device_id)
        if reloaded is not None:
            user = reloaded
    if not user.account_id:
        raise HTTPException(
            status.HTTP_500_INTERNAL_SERVER_ERROR, "no canonical account for this device"
        )
    account = store.get_account(user.account_id)
    return RegistrationEventsResponse(
        account_id=user.account_id,
        lifecycle_state=account.lifecycle_state if account else "anonymous",
        email_verified=bool(account and account.email_is_verified),
        events=store.list_registration_events(user.account_id),
    )


# ---------------------------------------------------------------------------
# Account deletion. Authenticated; revokes every session/device and private
# datum, and tombstones the account so append-only billing/provider audit
# facts stay valid (see store.delete_account).
# ---------------------------------------------------------------------------


class DeleteAccountResponse(BaseModel):
    deleted: bool
    revoked_devices: int


@app.delete("/v1/account", response_model=DeleteAccountResponse)
def delete_account(user: CurrentUser, store: StoreDep) -> DeleteAccountResponse:
    # ``CurrentUser`` is the revalidation gate: a caller must present a live
    # bearer for a device linked to the account being deleted. The device's
    # account_id — not any client-supplied id — is what we delete, so one
    # account can never delete another.
    if not user.account_id:
        # Contract §1: every device has a canonical account. A null here means
        # a legacy row; backfill so deletion has a principal to act on.
        reloaded = store.ensure_account(user.device_id)
        if reloaded is not None:
            user = reloaded
    if not user.account_id:
        raise HTTPException(status.HTTP_409_CONFLICT, "no account to delete")
    result = store.delete_account(user.account_id)
    return DeleteAccountResponse(
        deleted=bool(result.get("deleted")),
        revoked_devices=int(result.get("revoked_devices", 0)),
    )


# ---------------------------------------------------------------------------
# Shared server-authoritative rewrite entitlement gate
# ---------------------------------------------------------------------------
# The ONE chokepoint every rewrite endpoint calls before invoking a provider.
# There is NO free daily tier: a registered device is an entitlement PRINCIPAL,
# not a grant. Only the server-side ``User.is_pro`` projection passes — an
# active paid or trialing subscription, an active provider entitlement grant,
# past_due auto-renew grace, or a valid durable founder coupon/grant. Everyone
# else (fresh-registered, never-subscribed, canceled, expired) fails closed
# here with a DISTINCT, honest HTTP 402 that is never overloaded onto the
# IP-rate-limit 429 or the 401 auth failure, so clients can surface a truthful
# "subscription required" message.

# Shaped by ``http_exc_handler`` into
# ``{"error": {"code": 402, "reason": "entitlement_required", "message": ...}}``.
# ``reason`` is the stable machine key clients switch on (alongside the 402
# status); we deliberately avoid a ``code`` key here so it can't collide with
# the handler's HTTP-status ``code``.
_ENTITLEMENT_REQUIRED_DETAIL: dict[str, str] = {
    "reason": "entitlement_required",
    "message": "An active Tono trial or subscription is required to rewrite.",
}


def _require_rewrite_entitlement(user: User) -> None:
    """Fail closed unless ``user`` holds a server-authoritative rewrite
    entitlement. Called before ANY provider invocation on every rewrite route
    (grep-enforced by ``test_every_rewrite_route_calls_entitlement_gate``)."""
    if user.is_pro:
        return
    raise HTTPException(
        status_code=status.HTTP_402_PAYMENT_REQUIRED,
        detail=dict(_ENTITLEMENT_REQUIRED_DETAIL),
    )


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

    # Server-authoritative entitlement gate — fail closed BEFORE the per-IP
    # window (and before any provider call) so a non-entitled caller always
    # gets the honest 402 and never the misleading 429.
    _require_rewrite_entitlement(user)

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
    # Coach is a fixed four-choice contract. Personal ranking may influence
    # analytics, but never payload membership or order.
    axes = list(CANONICAL_COACH_AXES) if body.mode == "coach" else []
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

    # Cache lookup — hits don't consume the daily allowance. The key is derived
    # from the canonical ``internal`` request (every prompt-shaping input), NOT
    # from a hand-picked subset: the cache table is global across accounts.
    cache_key = (
        _analysis_cache_key(internal, locale=body.locale, provider=provider)
        if provider != "mock"
        else None
    )
    if cache_key:
        cached = store.get_cached_response(cache_key)
        if cached:
            try:
                cached = enforce_coach_contract(cached, internal)
            except CoachContractError as e:
                logger.warning("Ignoring invalid cached Coach response: %s", e)
                cached = None
        if cached:
            today = _today_utc()
            # Pooled on the account once signed in (identified) — see
            # record_rewrite; anonymous auto-accounts still count per-device.
            identified = user.account is not None and user.account.is_identified
            quota_source = user.account if identified else user
            snap_used = quota_source.daily_count if quota_source.daily_day == today else 0
            # Past the entitlement gate every caller is unlimited (-1); there is
            # no free daily tier to disclose.
            snap_limit = -1
            store.log_usage(
                user.device_id, "/api/analyze", 200, provider="cache",
                drafts_chars=len(body.text),
            )
            return ApiAnalyzeResponse(
                **cached, used_today=snap_used, daily_limit=snap_limit, plan=user.plan_resolved
            )

    # Entitlement was already enforced above (fail-closed 402). This is a
    # NON-authorizing telemetry counter only: no free-tier denial, no 429
    # overload. Every caller here is unlimited (daily_limit = -1).
    used = store.record_rewrite(user.device_id)
    limit = -1

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


# ---------------------------------------------------------------------------
# BUILD 117 — Read the Ask
# ---------------------------------------------------------------------------
#
# A reading of a message the person RECEIVED. It stands beside rewrite and
# reuses every protection the rewrite path already has — the same bearer, the
# same server-authoritative entitlement gate, the same per-IP window, the same
# draft ceiling, the same provider client and timeouts. What it does NOT reuse
# is the rewrite response: the Read the Ask contract returns the Ask, a By when
# the sender actually wrote, and one Unclear detail, and it forbids the risk
# score, perception and subtext that ``ToneAnalysis`` requires. Two products
# sharing one response model would mean fabricating one of them, so the shape is
# its own — see ``read_ask.py`` for the whole argument.
#
# The mode is stated, never inferred, and this route serves exactly one of them.


@app.post("/api/read-ask", response_model=ReadAskResponse)
async def api_read_ask(
    body: ReadAskRequest,
    request: Request,
    user: CurrentUser,
    store: StoreDep,
) -> ReadAskResponse:
    """Read what a received message is asking. Authenticated, entitled,
    rate-limited; the server holds the LLM API key."""
    # The explicit-mode boundary, stated rather than implied. ``rewrite`` is a
    # real mode in this vocabulary and simply not this route's, so it is refused
    # with a reason instead of falling through a schema.
    if body.mode != READ_ASK_MODE:
        raise HTTPException(
            400,
            f"mode must be '{READ_ASK_MODE}' on this route; got '{body.mode}'",
        )

    if not body.text or not body.text.strip():
        raise HTTPException(400, "text is required")
    if len(body.text) > _DRAFT_MAX_CHARS:
        raise HTTPException(400, f"text too long (max {_DRAFT_MAX_CHARS} chars)")

    # Same order as /api/analyze: entitlement first, so a caller without one is
    # told the honest 402 and never the misleading 429.
    _require_rewrite_entitlement(user)

    if not _check_ip_rate(_get_client_ip(request)):
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="too many requests from this IP — try again in a minute",
            headers={"Retry-After": "60"},
        )

    provider = os.environ.get("TONO_PROVIDER", "mock").lower()

    try:
        result = await invoke_read_ask(body.text, provider)
    except ReadAskContractError as e:
        logger.warning("Invalid Read the Ask response from %s: %s", provider, e)
        store.log_usage(
            user.device_id, "/api/read-ask", 502, provider=provider, drafts_chars=0,
        )
        raise HTTPException(502, "Read the Ask response incomplete. Please retry.") from e
    except HTTPException:
        store.log_usage(
            user.device_id, "/api/read-ask", 502, provider=provider, drafts_chars=0,
        )
        raise
    except Exception as e:
        logger.exception("/api/read-ask failed")
        store.log_usage(
            user.device_id, "/api/read-ask", 500, provider=provider, drafts_chars=0,
        )
        raise HTTPException(500, "read the ask failed") from e

    # Recorded when a provider was actually reached; silent when one was not.
    #
    # `ok` and `no_ask` both cost a generation — `no_ask` is what a real model
    # returns for "thanks for dinner last night", which is an ordinary message,
    # so leaving it out made provider spend on a whole common class of message
    # invisible to telemetry.
    #
    # `declined` stays silent, and that is a different kind of decision: the
    # crisis preflight returns BEFORE any provider call, so there is nothing to
    # bill — and counting it would be measuring how often a person shared
    # something Tono has no business reading. Silence is not an event.
    #
    # `drafts_chars=0` throughout: a character count is still derived from the
    # message.
    if result["status"] in ("ok", "no_ask"):
        store.log_usage(
            user.device_id, "/api/read-ask", 200, provider=provider, drafts_chars=0,
        )

    # Deliberately NOT cached. The rewrite path's response cache is global across
    # accounts and keyed on request identity; a message somebody received is
    # their private context and has no business in a shared table.
    return ReadAskResponse(**result, plan=user.plan_resolved)


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
# P0 BUILD-95 — Selected-variant endpoint
# ---------------------------------------------------------------------------
#
# One selected chip => one HTTP request => exactly one provider call =>
# exactly one matching variant.
#
# Wire shape:
#   POST /api/analyze/variant  (authenticated, same as /api/analyze)
#   request  = {text, axis, risk_hint?, custom_prompt?, locale?}
#   response = VariantResponse (strict ok|blocked envelope)
#
# Hard rules (cannot be softened without explicit controller approval):
#   R1. Exactly one provider call per request. No prefetch, no fan-out,
#       no hidden "Safer" generation.
#   R2. Server picks the model (axis+risk_hint -> Sonnet/Haiku). Client
#       never chooses model.
#   R3. Deterministic safety preflight issues zero provider calls. Block
#       reasons are short, closed-enum strings.
#   R4. Malformed/unsafe model output fails closed: the strict envelope
#       returns ``status="blocked", reason="provider_failed"|"validation_failed"``
#       -- no fallback model, no streaming before parse. The only permitted
#       retry is the single bounded funnier near-identical retry (R5).
#   R5. An explicit Funnier tap never returns normalized/near-identical source
#       text as success. The response-boundary guard issues at most one bounded
#       retry, then returns the neutral ``status="blocked",
#       reason="no_distinct_rewrite"`` state — never the draft as a rewrite.
#   R6. Phase timings use the same privacy-safe shape as /api/analyze
#       (request_id / phase / dt_ms). No payload, no device id, no token,
#       no UA, no provider name in the phase line.
# ---------------------------------------------------------------------------


@app.post("/api/analyze/variant", response_model=VariantResponse)
async def api_analyze_variant(
    body: VariantRequest,
    request: Request,
    user: CurrentUser,
    store: StoreDep,
) -> VariantResponse:
    """Selected-variant endpoint. One chip, one variant, one provider call.

    Phase ordering:
      request_accepted -> preflight_end -> provider_start -> provider_end -> response_sent

    Note: ``response_sent`` fires on both ``ok`` and ``blocked`` paths so the
    timing signal is consistent regardless of outcome.
    """
    request_id = _new_request_id()
    t_request = time.time()
    _log_phase(request_id, _PHASE_REQUEST_ACCEPTED, t_request)

    # The selected-variant contract classifies empty drafts in deterministic
    # preflight, not as a transport-level malformed request. This keeps the
    # strict ok|blocked envelope intact and guarantees zero provider calls.
    if len(body.text) > _DRAFT_MAX_CHARS:
        raise HTTPException(400, f"text too long (max {_DRAFT_MAX_CHARS} chars)")

    # Server-authoritative entitlement gate — the SAME shared chokepoint as
    # /api/analyze. Fail closed with an honest 402 BEFORE the per-IP window,
    # the deterministic preflight, and any provider call. This is the endpoint
    # every primary iOS surface (keyboard/iMessage/Shortcut) uses; registration
    # alone grants nothing, so a fresh/canceled/expired device rewrites nothing.
    _require_rewrite_entitlement(user)

    # Per-IP sliding-window cap (mirrors /api/analyze).
    client_ip = _get_client_ip(request)
    if not _check_ip_rate(client_ip):
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="too many requests from this IP — try again in a minute",
            headers={"Retry-After": "60"},
        )

    # R1 + R5: provider is server-picked. The client NEVER picks model
    # and never picks provider. Server pulls ``TONO_PROVIDER``; the
    # selected-variant endpoint does NOT honor any client-supplied
    # provider field (none exists on VariantRequest, by design).
    provider = os.environ.get("TONO_PROVIDER", "mock").lower()

    # Deterministic safety preflight (zero provider calls).
    block_reason = preflight_variant(body)
    _log_phase(request_id, _PHASE_PREFLIGHT_END, t_request)
    if block_reason is not None:
        store.log_usage(
            user.device_id, "/api/analyze/variant", 200,
            provider=provider, drafts_chars=len(body.text or ""),
        )
        _log_phase(request_id, _PHASE_RESPONSE_SENT, t_request)
        return VariantResponse(status="blocked", axis=body.axis, reason=block_reason)

    # Server-side model routing (zero provider calls). The model name is
    # passed into the provider function inside ``invoke_single_variant``.
    _log_phase(request_id, _PHASE_PROVIDER_START, t_request)
    response = await invoke_single_variant(body, provider)
    _log_phase(request_id, _PHASE_PROVIDER_END, t_request)
    _log_phase(request_id, _PHASE_RESPONSE_SENT, t_request)

    # The strict envelope already classified the outcome. We log usage
    # so the cost + axis + blocked/ok shape can be aggregated without PII.
    store.log_usage(
        user.device_id, "/api/analyze/variant", 200,
        provider=provider, drafts_chars=len(body.text or ""),
    )
    # Build 114 — a generation that happened is a generation that counts.
    #
    # This endpoint served a real provider call but never advanced the
    # `used_today` disclosure, so the keyboard — the primary surface — produced
    # rewrites the counter never saw. "Try another" makes that untenable rather
    # than merely untidy: a second generation the person deliberately asked for
    # is exactly the one they would expect to see counted, and a counter that
    # silently ignores it is not a truthful disclosure of what was spent on
    # their behalf.
    #
    # `record_rewrite` is NON-AUTHORIZING (see its docstring) and there is no
    # free daily tier, so counting here cannot gate anyone out of anything —
    # the entitlement decision was already made, above, before any provider
    # call. It only makes the number honest. The blocked path above returns
    # before this point and is deliberately not counted: no provider call was
    # made, so nothing was generated.
    store.record_rewrite(user.device_id)
    return response


# ---------------------------------------------------------------------------
# P0 BUILD-95 — Server-side model routing diagnostics
# ---------------------------------------------------------------------------
# Read-only endpoint that surfaces the current routing decisions for the
# allowlisted axes, used by hostile-matrix tests to lock the routing
# contract without making a real provider call. NOT a model-selection
# endpoint for the client; clients never see this route.
@app.get("/internal/model-routing")
def model_routing_diagnostics() -> dict[str, Any]:
    """Return the resolved (tier, model) for each allowlisted axis under
    each risk_hint value. Read-only; no provider calls; no PII.

    Used by tests in ``test_coach_contract.py`` to assert the routing
    contract: Safer/Custom/high-risk -> Sonnet; low-risk built-in non-Safer
    -> Haiku.
    """
    out: dict[str, dict[str, dict[str, str]]] = {}
    for axis in sorted(VARIANT_ALLOWLIST):
        out[axis] = {}
        for hint in ("low", "medium", "high", None):
            tier, model = select_model_for_variant(axis, hint)
            out[axis][str(hint)] = {"tier": tier, "model": model}
    return {"routing": out}


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
            "SELECT COUNT(*) as cnt FROM accounts WHERE coupon_pro_expires_at IS NOT NULL AND coupon_pro_expires_at > ?",
            (now_iso,),
        )
        coupon_pro = cur.fetchone()["cnt"]

        cur.execute("SELECT COUNT(*) as cnt FROM account_coupon_redemptions")
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
# Admin registration analytics (Build 114)
# ---------------------------------------------------------------------------


class AdminRegistrationsResponse(BaseModel):
    """Aggregate registration reporting. Every field is a count or a
    count-by-category; there is deliberately no field that could hold an
    address, an account id, or an event detail."""

    days: int
    registrations_total: int
    by_lifecycle_state: dict[str, int]
    by_source_surface: dict[str, int]
    by_app_build: dict[str, int]
    created_in_window: int
    verified_in_window: int
    signed_in_in_window: int
    events_in_window: dict[str, int]


@app.get("/admin/registrations", response_model=AdminRegistrationsResponse)
def admin_registrations(
    request: Request, store: StoreDep, days: int = 30
) -> AdminRegistrationsResponse:
    """How registration is going, for whoever runs the product.

    The Build 114 brief asks Tono to TRACK registrations, not merely to record
    them: `/v1/account/registration-events` answers "what happened to my
    account" for one signed-in person and is scoped by their own bearer, which
    is the right shape for support and the wrong shape for knowing whether
    signup works at all.

    Counts only. The response model above has no field an address could travel
    in, and `Store.registration_metrics` selects nothing but counts and the
    grouping columns the store itself sanitized on write — so this endpoint
    could not identify a person even if an operator wanted it to. That is why
    it is safe to expose an aggregate over a table whose per-row contents are
    otherwise deliberately unreadable from outside.

    Admin-secret protected like every other `/admin` route; without a
    configured `TONO_ADMIN_SECRET` it answers 403 rather than opening.
    """
    _check_admin(request)
    return AdminRegistrationsResponse(**store.registration_metrics(days=days))


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
    """Redeem for the identified canonical account proven by this bearer."""
    if not user.account_id or not user.account or not user.account.is_identified:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="sign in to a verified account before redeeming a code",
        )
    try:
        exp = store.redeem_coupon(user.account_id, body.code.strip().upper())
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
app.include_router(app_store.router)
app.include_router(google_play.router)


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
    # Only reachable via ``python -m backend.server`` from ``apps/``; a bare
    # ``python server.py`` fails earlier on this module's relative imports.
    # The import string must match the Dockerfile CMD exactly — the previous
    # ``Backend.server:app`` resolved only on a case-insensitive filesystem.
    import uvicorn
    uvicorn.run("backend.server:app", host="127.0.0.1", port=8765, reload=True)
