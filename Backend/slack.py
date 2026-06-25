"""Slack OAuth + slash-command integration for Tono.

OAuth scopes required: commands, chat:write
App manifest:
  slash_commands: /tono  request_url: https://<your-host>/slack/command
  redirect_urls:        https://<your-host>/slack/oauth

Env vars (see .env.example):
  SLACK_CLIENT_ID, SLACK_CLIENT_SECRET, SLACK_SIGNING_SECRET
"""

from __future__ import annotations

import collections
import hashlib
import hmac
import logging
import os
import threading
import time
from typing import Annotated, Optional
from urllib.parse import parse_qs

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.responses import HTMLResponse, RedirectResponse

from .analyze import AnalyzeRequest, mock_analyze, openai_analyze, anthropic_analyze
from .store import Store, get_store

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/slack", tags=["slack"])

# ---------------------------------------------------------------------------
# Per-user rate limiting (sliding window, 10 analyses/minute per Slack user)
# ---------------------------------------------------------------------------

_SLACK_RATE_LIMIT = int(os.environ.get("SLACK_RATE_LIMIT_PER_MIN", "10"))
_slack_user_windows: dict[str, collections.deque] = {}
_slack_lock = threading.Lock()


def _check_slack_user_rate(user_id: str) -> bool:
    """Returns False if the Slack user has exceeded the per-minute limit."""
    now = time.time()
    with _slack_lock:
        dq = _slack_user_windows.setdefault(user_id, collections.deque())
        while dq and now - dq[0] > 60:
            dq.popleft()
        if len(dq) >= _SLACK_RATE_LIMIT:
            return False
        dq.append(now)
    return True


# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------


def _client_id() -> str:
    return os.environ.get("SLACK_CLIENT_ID", "")


def _client_secret() -> str:
    return os.environ.get("SLACK_CLIENT_SECRET", "")


def _signing_secret() -> str:
    return os.environ.get("SLACK_SIGNING_SECRET", "")


def _store_dep() -> Store:
    return get_store()


# ---------------------------------------------------------------------------
# Signature verification
# ---------------------------------------------------------------------------


def _verify_signature(body: bytes, timestamp: str, signature: str) -> bool:
    secret = _signing_secret()
    if not secret:
        return False
    try:
        if abs(time.time() - int(timestamp)) > 300:
            return False
    except (TypeError, ValueError):
        return False
    base = f"v0:{timestamp}:{body.decode('utf-8', errors='replace')}"
    expected = "v0=" + hmac.new(secret.encode(), base.encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature)


# ---------------------------------------------------------------------------
# OAuth flow
# ---------------------------------------------------------------------------


@router.get("/install")
def slack_install() -> RedirectResponse:
    client_id = _client_id()
    if not client_id:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Slack not configured on this server")
    scopes = "commands,chat:write"
    url = (
        "https://slack.com/oauth/v2/authorize"
        f"?client_id={client_id}"
        f"&scope={scopes}"
    )
    return RedirectResponse(url)


@router.get("/oauth")
async def slack_oauth(
    code: Optional[str] = None,
    error: Optional[str] = None,
    store: Annotated[Store, Depends(_store_dep)] = None,
) -> HTMLResponse:
    if error or not code:
        return HTMLResponse(
            f"<p>Slack OAuth error: {error or 'missing code'}</p>", status_code=400
        )
    async with httpx.AsyncClient(timeout=15) as c:
        resp = await c.post(
            "https://slack.com/api/oauth.v2.access",
            data={
                "client_id": _client_id(),
                "client_secret": _client_secret(),
                "code": code,
            },
        )
    data = resp.json()
    if not data.get("ok"):
        logger.warning("Slack OAuth failed: %s", data.get("error"))
        return HTMLResponse(
            f"<p>Slack OAuth failed: {data.get('error')}</p>", status_code=400
        )

    team = data.get("team") or {}
    store.upsert_slack_workspace(
        team_id=team.get("id", ""),
        access_token=data.get("access_token", ""),
        team_name=team.get("name", ""),
        bot_user_id=data.get("bot_user_id", ""),
    )
    logger.info("Slack workspace installed: %s", team.get("name"))
    return HTMLResponse(
        """
        <html><body style="font-family:system-ui;max-width:480px;margin:60px auto;padding:0 16px">
        <h2>✅ Tono added to Slack</h2>
        <p>Try <code>/tono Your message here</code> in any channel.</p>
        <p>Tono will flag the tone risk and suggest four rewrites, visible only to you.</p>
        </body></html>
        """
    )


# ---------------------------------------------------------------------------
# Slash command
# ---------------------------------------------------------------------------


_RISK_EMOJI = {"low": "🟢", "medium": "🟡", "high": "🔴"}
_AXIS_EMOJI = {"warmer": "🤗", "clearer": "💡", "funnier": "😄", "safer": "🛡️"}


def _parse_command_text(text: str) -> tuple[str, str | None]:
    """Split `/tono` text into (draft, thread_context).

    Supports two formats:
      /tono <draft>
      /tono reply: <prior message> // <draft>

    The `reply:` prefix (case-insensitive) marks the thread context section.
    Everything before `//` is the prior message; everything after is the draft.
    """
    stripped = text.strip()
    lower = stripped.lower()
    if lower.startswith("reply:"):
        rest = stripped[len("reply:"):].strip()
        if "//" in rest:
            ctx_part, draft_part = rest.split("//", 1)
            return draft_part.strip(), ctx_part.strip() or None
        # `reply:` present but no `//` delimiter — treat whole thing as draft
        return rest, None
    if "//" in stripped:
        ctx_part, draft_part = stripped.split("//", 1)
        return draft_part.strip(), ctx_part.strip() or None
    return stripped, None


@router.post("/command")
async def slack_command(
    request: Request,
    store: Annotated[Store, Depends(_store_dep)],
) -> dict:
    body_bytes = await request.body()
    timestamp = request.headers.get("X-Slack-Request-Timestamp", "")
    signature = request.headers.get("X-Slack-Signature", "")

    if _signing_secret() and not _verify_signature(body_bytes, timestamp, signature):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid Slack signature")

    params = {k: v[0] for k, v in parse_qs(body_bytes.decode("utf-8", errors="replace")).items()}
    text = params.get("text", "").strip()
    user_id = params.get("user_id", "unknown")

    if not text:
        return {
            "response_type": "ephemeral",
            "text": (
                "Usage: `/tono <your message>` — analyzes tone and suggests rewrites.\n"
                "To include thread context: `/tono reply: <prior message> // <your draft>`"
            ),
        }

    if not _check_slack_user_rate(user_id):
        return {
            "response_type": "ephemeral",
            "text": "⏳ Too many requests — please wait a moment before trying again.",
        }

    draft, thread_context = _parse_command_text(text)
    if not draft:
        return {"response_type": "ephemeral", "text": "No draft found. Place your message after `//`."}

    req = AnalyzeRequest(draft=draft, thread_context=thread_context)
    provider = os.environ.get("TONO_PROVIDER", "mock").lower()

    try:
        if provider == "openai":
            result = await openai_analyze(req)
        elif provider == "anthropic":
            result = await anthropic_analyze(req)
        else:
            result = mock_analyze(req)
    except Exception as exc:
        logger.exception("Slack /tono analyze failed")
        return {"response_type": "ephemeral", "text": f"Analysis failed: {exc}"}

    risk = result.get("risk_level", "medium")
    risk_icon = _RISK_EMOJI.get(risk, "🟡")

    header_text = f"{risk_icon} *{risk.upper()} RISK* — {result.get('perception', '')}"
    if thread_context:
        header_text += f"\n_Context: \"{thread_context[:80]}{'…' if len(thread_context) > 80 else ''}\"_"

    blocks = [
        {
            "type": "section",
            "text": {"type": "mrkdwn", "text": header_text},
        },
        {"type": "divider"},
    ]
    for s in result.get("suggestions", []):
        axis = s.get("axis", "")
        icon = _AXIS_EMOJI.get(axis, "✏️")
        rationale = f"\n_{s['rationale']}_" if s.get("rationale") else ""

        risk_after = s.get("risk_after")
        delta_text = ""
        if risk_after and risk_after != risk:
            after_icon = _RISK_EMOJI.get(risk_after, "🟡")
            delta_text = f"  {risk_icon}→{after_icon}"

        blocks.append({
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"{icon} *{axis.title()}:*{delta_text} {s.get('text', '')}{rationale}",
            },
        })

    return {"response_type": "ephemeral", "blocks": blocks}
