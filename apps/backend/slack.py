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
import json
import logging
import os
import threading
import time
from typing import Annotated, Optional
from urllib.parse import parse_qs

import httpx
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request, status
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
    """Returns False if the Slack user has exceeded the per-minute limit.

    The limit is read from the env on each call so tests (and ops) can
    override it without re-importing the module.
    """
    limit = int(os.environ.get("SLACK_RATE_LIMIT_PER_MIN", str(_SLACK_RATE_LIMIT)))
    now = time.time()
    with _slack_lock:
        dq = _slack_user_windows.setdefault(user_id, collections.deque())
        while dq and now - dq[0] > 60:
            dq.popleft()
        if len(dq) >= limit:
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


def _build_blocks(result: dict, draft: str, thread_context: str | None, response_url: str) -> list[dict]:
    risk = result.get("risk_level", "medium")
    risk_icon = _RISK_EMOJI.get(risk, "🟡")
    perception = result.get("perception", "")
    risk_reason = result.get("risk_reason", "")
    subtext = result.get("subtext", "")
    flags = result.get("flags", [])

    header_text = f"{risk_icon} *{risk.upper()} RISK* — {perception}"
    if thread_context:
        snippet = thread_context[:80] + ("…" if len(thread_context) > 80 else "")
        header_text += f"\n_Context: \"{snippet}\"_"

    blocks: list[dict] = [
        {"type": "section", "text": {"type": "mrkdwn", "text": header_text}},
    ]

    details: list[str] = []
    if risk_reason:
        details.append(f"Risk reason: {risk_reason}")
    if subtext:
        details.append(f"Subtext: {subtext}")
    if flags:
        details.append(f"Flags: {', '.join(flags)}")
    if details:
        blocks.append({
            "type": "context",
            "elements": [{"type": "mrkdwn", "text": " • ".join(details)}],
        })

    blocks.append({"type": "divider"})

    for s in result.get("suggestions", []):
        axis = s.get("axis", "")
        icon = _AXIS_EMOJI.get(axis, "✏️")
        text = s.get("text", "")
        rationale = s.get("rationale", "")
        risk_after = s.get("risk_after")

        risk_delta = ""
        if risk_after and risk_after != risk:
            after_icon = _RISK_EMOJI.get(risk_after, "🟡")
            risk_delta = f" {risk_icon}→{after_icon}"
        elif risk_after:
            after_icon = _RISK_EMOJI.get(risk_after, "🟡")
            risk_delta = f" {after_icon}"

        section_text = f"{icon} *{axis.title()}*{risk_delta}\n> {text}"
        if rationale:
            section_text += f"\n_{rationale}_"

        blocks.append({
            "type": "section",
            "text": {"type": "mrkdwn", "text": section_text},
        })

        if response_url:
            try:
                value = json.dumps({
                    "response_url": response_url,
                    "axis": axis,
                    "text": text,
                }, separators=(',', ':'))
            except (TypeError, ValueError):
                value = ""
            if value:
                blocks.append({
                    "type": "actions",
                    "elements": [
                        {
                            "type": "button",
                            "text": {"type": "plain_text", "text": "Post this rewrite", "emoji": True},
                            "action_id": f"tono_rewrite_{axis}",
                            "value": value,
                        }
                    ],
                })

    if not result.get("suggestions"):
        blocks.append({
            "type": "section",
            "text": {"type": "mrkdwn", "text": "_No rewrite suggestions for this message._"},
        })

    return blocks


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
    response_url = params.get("response_url", "")

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

    blocks = _build_blocks(result, draft, thread_context, response_url)

    return {"response_type": "ephemeral", "blocks": blocks}


# ---------------------------------------------------------------------------
# Interactivity — rewrite button clicks
# ---------------------------------------------------------------------------

async def _post_rewrite(response_url: str, text: str, axis: str) -> None:
    """Post the selected rewrite back to the channel/thread via response_url."""
    icon = _AXIS_EMOJI.get(axis, "✏️")
    payload = {
        "response_type": "in_channel",
        "text": f"{icon} *{axis.title()} rewrite:*\n> {text}",
    }
    async with httpx.AsyncClient(timeout=15) as client:
        try:
            r = await client.post(response_url, json=payload)
            r.raise_for_status()
            logger.info("Posted %s rewrite to response_url (status %s)", axis, r.status_code)
        except Exception:
            logger.exception("Failed to post rewrite to response_url")


@router.post("/interaction")
async def slack_interaction(
    request: Request,
    background_tasks: BackgroundTasks,
) -> dict:
    """Handle Block Kit action payloads (e.g. 'Post this rewrite' buttons)."""
    body_bytes = await request.body()
    timestamp = request.headers.get("X-Slack-Request-Timestamp", "")
    signature = request.headers.get("X-Slack-Signature", "")

    if _signing_secret() and not _verify_signature(body_bytes, timestamp, signature):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid Slack signature")

    form = await request.form()
    payload_raw = form.get("payload", "{}")
    payload_str = payload_raw if isinstance(payload_raw, str) else await payload_raw.read()
    try:
        payload = json.loads(payload_str)
    except json.JSONDecodeError:
        return {}

    if payload.get("type") != "block_actions":
        return {}

    actions = payload.get("actions", [])
    if not actions:
        return {}

    action = actions[0]
    action_id = action.get("action_id", "")

    if action_id.startswith("tono_rewrite_"):
        try:
            value = json.loads(action.get("value", "{}"))
        except json.JSONDecodeError:
            return {}
        response_url = value.get("response_url")
        rewrite_text = value.get("text", "")
        axis = value.get("axis", "")
        if response_url and rewrite_text:
            background_tasks.add_task(_post_rewrite, response_url, rewrite_text, axis)

    return {}
