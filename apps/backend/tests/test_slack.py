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
    payload = {"text": text, "user_id": user_id, "team_id": "T999", "response_url": "https://hooks.slack.com/commands/T999/123", **extra}
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
    from backend.slack import _parse_command_text
    draft, ctx = _parse_command_text("Hello world")
    assert draft == "Hello world"
    assert ctx is None


def test_parse_slash_separator():
    from backend.slack import _parse_command_text
    draft, ctx = _parse_command_text("Prior message // My draft here")
    assert draft == "My draft here"
    assert ctx == "Prior message"


def test_parse_reply_prefix_with_separator():
    from backend.slack import _parse_command_text
    draft, ctx = _parse_command_text("reply: thanks for the update // Got it, will follow up.")
    assert draft == "Got it, will follow up."
    assert ctx == "thanks for the update"


def test_parse_reply_prefix_no_separator():
    from backend.slack import _parse_command_text
    draft, ctx = _parse_command_text("reply: Got it, will follow up.")
    assert draft == "Got it, will follow up."
    assert ctx is None


def test_parse_empty_context_treated_as_none():
    from backend.slack import _parse_command_text
    draft, ctx = _parse_command_text("  // My draft")
    assert draft == "My draft"
    assert ctx is None


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


def test_command_rate_limit(client, monkeypatch):
    """Exhaust the per-user rate limit and confirm 429-style ephemeral response."""
    monkeypatch.setenv("SLACK_RATE_LIMIT_PER_MIN", "2")

    # Re-import so the module picks up the patched env var limit.
    import importlib
    import sys
    for mod in list(sys.modules):
        if mod == "Backend.slack" or mod.startswith("Backend.slack"):
            del sys.modules[mod]

    from backend.slack import _check_slack_user_rate, _slack_user_windows
    _slack_user_windows.clear()

    # Exhaust limit manually
    assert _check_slack_user_rate("U_RL") is True
    assert _check_slack_user_rate("U_RL") is True
    assert _check_slack_user_rate("U_RL") is False


def test_command_rate_limit_endpoint(client, monkeypatch):
    """Rate-limit block is returned as an ephemeral message."""
    import backend.slack as slack_mod
    from collections import deque

    slack_mod._SLACK_RATE_LIMIT = 1
    slack_mod._slack_user_windows.clear()
    slack_mod._slack_user_windows["U_RL2"] = deque([time.time()])  # already at limit

    data = _post_command(client, text="hello", user_id="U_RL2")
    assert data["response_type"] == "ephemeral"
    assert "Too many requests" in data["text"]

    # Clean up
    slack_mod._SLACK_RATE_LIMIT = 10
    slack_mod._slack_user_windows.clear()


def test_command_rejects_invalid_signature(client, monkeypatch):
    monkeypatch.setenv("SLACK_SIGNING_SECRET", "test_secret_abc")

    import backend.slack as slack_mod
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

    import backend.slack as slack_mod
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
# Rich Block Kit output (risk badges + rewrite buttons)
# ---------------------------------------------------------------------------


def test_blocks_include_risk_badge_and_perception(client):
    data = _post_command(client, text="Need this ASAP.")
    assert "blocks" in data
    blocks = data["blocks"]
    header_text = blocks[0]["text"]["text"]
    assert "RISK" in header_text
    # Risk badge emoji should appear
    assert any(emoji in header_text for emoji in ("🟢", "🟡", "🔴"))


def test_blocks_include_risk_reason_and_flags(client):
    data = _post_command(client, text="as per my last message, can you get this done?")
    blocks = data["blocks"]
    # Look for context block with details
    context_blocks = [b for b in blocks if b["type"] == "context"]
    assert len(context_blocks) >= 1
    details = context_blocks[0]["elements"][0]["text"]
    assert "Risk reason:" in details or "Flags:" in details


def test_blocks_include_rewrite_buttons(client):
    data = _post_command(client, text="Can you get this done by end of day?")
    blocks = data["blocks"]
    action_blocks = [b for b in blocks if b["type"] == "actions"]
    assert len(action_blocks) >= 1
    button = action_blocks[0]["elements"][0]
    assert button["type"] == "button"
    assert "Post this rewrite" in button["text"]["text"]
    # Value should contain axis info
    assert button["action_id"].startswith("tono_rewrite_")
    assert "value" in button


def test_blocks_axis_risk_delta_shown(client):
    data = _post_command(client, text="as per my last message")
    blocks = data["blocks"]
    # Find suggestion blocks
    suggestion_blocks = [b for b in blocks if b["type"] == "section" and "*" in b["text"]["text"]]
    # At least one should show risk delta arrow if there are suggestions
    texts = [b["text"]["text"] for b in suggestion_blocks]
    assert any("→" in t for t in texts) or any(emoji in t for t in texts for emoji in ("🟢", "🟡", "🔴"))


# ---------------------------------------------------------------------------
# Interactivity endpoint (/slack/interaction)
# ---------------------------------------------------------------------------


def test_interaction_rejects_invalid_signature(client, monkeypatch):
    monkeypatch.setenv("SLACK_SIGNING_SECRET", "test_secret_abc")
    import backend.slack as slack_mod
    slack_mod._signing_secret = lambda: "test_secret_abc"

    payload = urlencode({"payload": json.dumps({"type": "block_actions"})}).encode()
    r = client.post(
        "/slack/interaction",
        content=payload,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "X-Slack-Request-Timestamp": str(int(time.time())),
            "X-Slack-Signature": "v0=badsignature",
        },
    )
    assert r.status_code == 401


def test_interaction_accepts_valid_signature_noop_for_unknown_action(client, monkeypatch):
    secret = "test_valid_secret"
    monkeypatch.setenv("SLACK_SIGNING_SECRET", secret)
    import backend.slack as slack_mod
    slack_mod._signing_secret = lambda: secret

    payload_dict = {
        "type": "block_actions",
        "actions": [{"action_id": "unknown_action", "value": "{}"}],
    }
    body = urlencode({"payload": json.dumps(payload_dict)}).encode()
    ts, sig = _make_signature(secret, body)
    r = client.post(
        "/slack/interaction",
        content=body,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "X-Slack-Request-Timestamp": ts,
            "X-Slack-Signature": sig,
        },
    )
    assert r.status_code == 200


def test_interaction_posts_rewrite_from_button(client, monkeypatch):
    secret = "test_valid_secret"
    monkeypatch.setenv("SLACK_SIGNING_SECRET", secret)
    import backend.slack as slack_mod
    slack_mod._signing_secret = lambda: secret

    payload_dict = {
        "type": "block_actions",
        "actions": [{
            "action_id": "tono_rewrite_safer",
            "value": json.dumps({
                "response_url": "https://hooks.slack.com/commands/T123/456",
                "axis": "safer",
                "text": "Following up on my last note, can you get this done?",
            }),
        }],
    }
    body = urlencode({"payload": json.dumps(payload_dict)}).encode()
    ts, sig = _make_signature(secret, body)
    r = client.post(
        "/slack/interaction",
        content=body,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "X-Slack-Request-Timestamp": ts,
            "X-Slack-Signature": sig,
        },
    )
    assert r.status_code == 200
