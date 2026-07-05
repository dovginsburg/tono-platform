"""Tests for the Slack slash-command integration.

Signing-secret verification is skipped in all happy-path tests because
SLACK_SIGNING_SECRET is not set in the test env. A dedicated test
exercises the rejection path with a bogus signature.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import time
from urllib.parse import urlencode

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _post_command(client, text: str = "", user_id: str = "U123", **extra) -> dict:
    """POST a Slack slash-command payload and return the JSON body."""
    payload = {"text": text, "user_id": user_id, "team_id": "T999", **extra}
    body = urlencode(payload).encode()
    r = client.post(
        "/slack/command",
        content=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    assert r.status_code == 200, r.text
    return r.json()


def _make_signature(secret: str, body: bytes, ts: int | None = None) -> tuple[str, str]:
    ts = ts or int(time.time())
    base = f"v0:{ts}:{body.decode('utf-8', errors='replace')}"
    sig = "v0=" + hmac.new(secret.encode(), base.encode(), hashlib.sha256).hexdigest()
    return str(ts), sig


# ---------------------------------------------------------------------------
# _parse_command_text unit tests (import directly)
# ---------------------------------------------------------------------------


def test_parse_plain_draft():
    from Backend.slack import _parse_command_text
    draft, ctx, locale = _parse_command_text("Hello world")
    assert draft == "Hello world"
    assert ctx is None
    assert locale == "en"


def test_parse_slash_separator():
    from Backend.slack import _parse_command_text
    draft, ctx, locale = _parse_command_text("Prior message // My draft here")
    assert draft == "My draft here"
    assert ctx == "Prior message"
    assert locale == "en"


def test_parse_reply_prefix_with_separator():
    from Backend.slack import _parse_command_text
    draft, ctx, locale = _parse_command_text("reply: thanks for the update // Got it, will follow up.")
    assert draft == "Got it, will follow up."
    assert ctx == "thanks for the update"
    assert locale == "en"


def test_parse_reply_prefix_no_separator():
    from Backend.slack import _parse_command_text
    draft, ctx, locale = _parse_command_text("reply: Got it, will follow up.")
    assert draft == "Got it, will follow up."
    assert ctx is None
    assert locale == "en"


def test_parse_empty_context_treated_as_none():
    from Backend.slack import _parse_command_text
    draft, ctx, locale = _parse_command_text("  // My draft")
    assert draft == "My draft"
    assert ctx is None
    assert locale == "en"


def test_parse_lang_prefix():
    from Backend.slack import _parse_command_text
    draft, ctx, locale = _parse_command_text("lang:es Necesito esto para mañana.")
    assert draft == "Necesito esto para mañana."
    assert ctx is None
    assert locale == "es"


def test_parse_lang_prefix_with_reply():
    from Backend.slack import _parse_command_text
    draft, ctx, locale = _parse_command_text("lang:fr reply: Merci // On y va.")
    assert draft == "On y va."
    assert ctx == "Merci"
    assert locale == "fr"


# ---------------------------------------------------------------------------
# /slack/command endpoint
# ---------------------------------------------------------------------------


def test_command_empty_text_returns_usage(client):
    data = _post_command(client, text="")
    assert data["response_type"] == "ephemeral"
    assert "/tono" in data["text"]


def test_command_returns_blocks(client):
    data = _post_command(client, text="Can you get this done by end of day?")
    assert data["response_type"] == "ephemeral"
    assert "blocks" in data
    blocks = data["blocks"]
    assert len(blocks) >= 2  # header + divider at minimum
    # First block carries the risk level
    first_text = blocks[0]["text"]["text"]
    assert "RISK" in first_text


def test_command_suggestion_blocks(client):
    data = _post_command(client, text="Need this ASAP.")
    blocks = data["blocks"]
    # After header + divider, each suggestion is its own block
    suggestion_blocks = [b for b in blocks if b["type"] == "section" and "text" in b][1:]
    # Mock analyzer returns up to 4 axes
    assert len(suggestion_blocks) >= 1


def test_command_thread_context_slash_separator(client):
    data = _post_command(client, text="Can you deliver this? // Sure, happy to help.")
    assert data["response_type"] == "ephemeral"
    blocks = data["blocks"]
    header_text = blocks[0]["text"]["text"]
    # Context snippet should appear in the header
    assert "Can you deliver this?" in header_text


def test_command_thread_context_reply_prefix(client):
    data = _post_command(client, text="reply: Let me know when it's ready // On it!")
    blocks = data["blocks"]
    header_text = blocks[0]["text"]["text"]
    assert "Let me know when it's ready" in header_text


def test_command_no_draft_after_separator(client):
    data = _post_command(client, text="context only //")
    assert data["response_type"] == "ephemeral"
    # No draft text after separator — should get error message
    assert "blocks" not in data
    assert "No draft found" in data["text"]


async def test_command_rate_limit(monkeypatch):
    """Exhaust the per-user rate limit and confirm 429-style ephemeral response.

    Deliberately doesn't use the `client` fixture: this test awaits
    `_check_slack_user_rate` directly on pytest-asyncio's own event loop,
    and `client`'s TestClient runs its app lifespan (including the Redis
    client's startup/shutdown) on a different loop — mixing the two would
    hit the same "attached to a different loop" asyncpg/redis-py error the
    `store` fixture's docstring explains.
    """
    import Backend.slack as slack_mod
    from Backend.slack import _check_slack_user_rate

    monkeypatch.setattr(slack_mod, "_SLACK_RATE_LIMIT", 2)

    # Exhaust limit manually. Redis-backed (see Backend/ratelimit.py), so
    # this reaches the same test Redis DB conftest.py flushes before every
    # test — no in-memory dict to reset by hand anymore.
    assert await _check_slack_user_rate("U_RL") is True
    assert await _check_slack_user_rate("U_RL") is True
    assert await _check_slack_user_rate("U_RL") is False


def test_command_rate_limit_endpoint(client, monkeypatch):
    """Rate-limit block is returned as an ephemeral message."""
    import Backend.slack as slack_mod

    monkeypatch.setattr(slack_mod, "_SLACK_RATE_LIMIT", 1)

    # First call consumes the (limit-of-1) allowance via the real endpoint;
    # the second must be rate-limited.
    _post_command(client, text="hello", user_id="U_RL2")
    data = _post_command(client, text="hello again", user_id="U_RL2")
    assert data["response_type"] == "ephemeral"
    assert "Too many requests" in data["text"]


def test_command_rejects_invalid_signature(client, monkeypatch):
    monkeypatch.setenv("SLACK_SIGNING_SECRET", "test_secret_abc")

    import Backend.slack as slack_mod
    slack_mod._signing_secret = lambda: "test_secret_abc"

    payload = urlencode({"text": "hello", "user_id": "U1", "team_id": "T1"}).encode()
    r = client.post(
        "/slack/command",
        content=payload,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "X-Slack-Request-Timestamp": str(int(time.time())),
            "X-Slack-Signature": "v0=badsignature",
        },
    )
    assert r.status_code == 401


def test_command_accepts_valid_signature(client, monkeypatch):
    secret = "test_valid_secret"
    monkeypatch.setenv("SLACK_SIGNING_SECRET", secret)

    import Backend.slack as slack_mod
    slack_mod._signing_secret = lambda: secret

    payload = urlencode({"text": "hi", "user_id": "U2", "team_id": "T1"}).encode()
    ts, sig = _make_signature(secret, payload)
    r = client.post(
        "/slack/command",
        content=payload,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "X-Slack-Request-Timestamp": ts,
            "X-Slack-Signature": sig,
        },
    )
    assert r.status_code == 200
    assert r.json()["response_type"] == "ephemeral"


# ---------------------------------------------------------------------------
# Message shortcut ("Coach this message" -> /slack/interactivity)
# ---------------------------------------------------------------------------


def _post_interactivity(client, payload: dict):
    body = urlencode({"payload": json.dumps(payload)}).encode()
    return client.post(
        "/slack/interactivity",
        content=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )


class _FakeAsyncClient:
    """Stand-in for httpx.AsyncClient that records the response_url POST
    instead of making a real network call."""

    captured: dict = {}

    def __init__(self, *args, **kwargs):
        pass

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        return False

    async def post(self, url, json=None, **kwargs):  # noqa: A002 - matches httpx signature
        _FakeAsyncClient.captured = {"url": url, "json": json}

        class _Resp:
            status_code = 200

        return _Resp()


def test_message_shortcut_posts_ephemeral_via_response_url(client, monkeypatch):
    import Backend.slack as slack_mod

    monkeypatch.setattr(slack_mod, "httpx", type("_M", (), {"AsyncClient": _FakeAsyncClient}))
    _FakeAsyncClient.captured = {}

    payload = {
        "type": "message_action",
        "callback_id": "tono_coach_message",
        "user": {"id": "U_SHORTCUT"},
        "response_url": "https://hooks.slack.test/abc",
        "message": {"text": "as per my last message"},
    }
    r = _post_interactivity(client, payload)
    assert r.status_code == 200

    assert _FakeAsyncClient.captured["url"] == "https://hooks.slack.test/abc"
    body = _FakeAsyncClient.captured["json"]
    assert body["response_type"] == "ephemeral"
    assert "blocks" in body
    assert "RISK" in body["blocks"][0]["text"]["text"]


def test_message_shortcut_ignores_unknown_callback_id(client, monkeypatch):
    import Backend.slack as slack_mod

    monkeypatch.setattr(slack_mod, "httpx", type("_M", (), {"AsyncClient": _FakeAsyncClient}))
    _FakeAsyncClient.captured = {}

    payload = {
        "type": "message_action",
        "callback_id": "some_other_shortcut",
        "user": {"id": "U_X"},
        "response_url": "https://hooks.slack.test/abc",
        "message": {"text": "hello"},
    }
    r = _post_interactivity(client, payload)
    assert r.status_code == 200
    assert _FakeAsyncClient.captured == {}


def test_message_shortcut_ignores_empty_message(client, monkeypatch):
    import Backend.slack as slack_mod

    monkeypatch.setattr(slack_mod, "httpx", type("_M", (), {"AsyncClient": _FakeAsyncClient}))
    _FakeAsyncClient.captured = {}

    payload = {
        "type": "message_action",
        "callback_id": "tono_coach_message",
        "user": {"id": "U_X"},
        "response_url": "https://hooks.slack.test/abc",
        "message": {"text": "   "},
    }
    r = _post_interactivity(client, payload)
    assert r.status_code == 200
    assert _FakeAsyncClient.captured == {}
