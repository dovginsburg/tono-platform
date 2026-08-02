"""Cross-account isolation for the global /api/analyze response cache.

``response_cache`` is keyed ONLY by ``_analysis_cache_key`` and is shared by
every account (``store.get_cached_response`` has no account/device predicate).
So the key MUST cover every input that shapes the provider's output, or one
caller's cached answer is served verbatim to a different account.

The concrete leak these tests pin closed: ``thread_context`` (the message the
caller is replying to — i.e. the OTHER party's words), ``recipient_hint``, and
``context_hints`` (facts inferred from the caller's private history) are all
injected into the provider prompt by ``build_user_prompt`` /
``build_system_prompt``, but none of them were part of the cache key. Two
different accounts sending the same draft text collided, and the second one
received a rewrite shaped by the first one's private thread and personal
patterns.

Red/green: against the pre-fix key (text, axes, voice, locale) the
``different_thread_context`` cases below fail — account B receives account A's
marker. They pass only when the key covers the whole provider input.

Runs against a stubbed non-mock provider, because the cache is deliberately
bypassed for ``provider == "mock"``.
"""

from __future__ import annotations

import datetime as _dt

import pytest


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _register_entitled(client) -> dict:
    """Register a fresh device and give it a durable (coupon) entitlement so it
    clears the shared rewrite gate. Each call is a DIFFERENT account."""
    r = client.post("/v1/register", json={"platform": "ios", "app_version": "0.2.0"})
    assert r.status_code == 200, r.text
    body = r.json()

    from backend.store import get_store

    expires = (_dt.datetime.now(_dt.timezone.utc) + _dt.timedelta(days=30)).isoformat(
        timespec="seconds"
    )
    get_store()._conn.execute(
        "UPDATE users SET coupon_pro_expires_at = ? WHERE device_id = ?",
        (expires, body["device_id"]),
    )
    return body


@pytest.fixture
def echo_provider(monkeypatch):
    """Stub the anthropic provider with a deterministic echo.

    The returned rewrite embeds the private prompt inputs, so a cache
    cross-serve is directly observable in the response body. Also counts calls
    so we can prove the cache still works when it is supposed to.
    """
    import backend.server as server

    calls: list[dict] = []

    async def _fake(req):
        calls.append(
            {
                "draft": req.draft,
                "thread_context": req.thread_context,
                "recipient_hint": req.recipient_hint,
                "context_hints": req.context_hints,
            }
        )
        marker = "|".join(
            [
                req.thread_context or "-",
                req.recipient_hint or "-",
                ",".join(req.context_hints or []) or "-",
                req.preferred_voice or "-",
            ]
        )
        return {
            "risk_level": "low",
            "perception": f"echo::{marker}",
            "subtext": "neutral",
            "risk_reason": "stub",
            "flags": [],
            "suggestions": [
                {"axis": axis, "text": f"{axis}::{marker}", "rationale": "stub"}
                for axis in req.axes
            ],
        }

    monkeypatch.setattr(server, "anthropic_analyze", _fake)
    return calls


def _analyze(client, token: str, **payload):
    body = {"text": "hey", "provider": "anthropic"}
    body.update(payload)
    r = client.post("/api/analyze", headers=_auth(token), json=body)
    assert r.status_code == 200, r.text
    return r.json()


# --------------------------------------------------------------------------
# The leak, end to end
# --------------------------------------------------------------------------


def test_thread_context_never_crosses_accounts(client, echo_provider):
    """Account A's private thread must never reach account B.

    Both accounts send the identical draft text; only the thread context (the
    other party's message) differs. Under the pre-fix key these collided.
    """
    a = _register_entitled(client)
    b = _register_entitled(client)
    assert a["account_id"] != b["account_id"]

    got_a = _analyze(client, a["api_token"], thread_context="LAYOFF-NEWS-FROM-BOB")
    got_b = _analyze(client, b["api_token"], thread_context="UNRELATED-DINNER-PLAN")

    assert "LAYOFF-NEWS-FROM-BOB" in got_a["perception"]
    # The leak: B receiving A's marker.
    assert "LAYOFF-NEWS-FROM-BOB" not in got_b["perception"], (
        "account B was served a response shaped by account A's private thread context"
    )
    assert "UNRELATED-DINNER-PLAN" in got_b["perception"]
    for suggestion in got_b["suggestions"]:
        assert "LAYOFF-NEWS-FROM-BOB" not in suggestion["text"]


def test_recipient_hint_never_crosses_accounts(client, echo_provider):
    a = _register_entitled(client)
    b = _register_entitled(client)

    got_a = _analyze(client, a["api_token"], recipient_hint="my-therapist")
    got_b = _analyze(client, b["api_token"], recipient_hint="my-landlord")

    assert "my-therapist" in got_a["perception"]
    assert "my-therapist" not in got_b["perception"]
    assert "my-landlord" in got_b["perception"]


def test_context_hints_never_cross_accounts(client, echo_provider):
    """context_hints are inferred from the caller's private history and are
    injected into the SYSTEM prompt — the most sensitive of the three."""
    a = _register_entitled(client)
    b = _register_entitled(client)

    got_a = _analyze(client, a["api_token"], context_hints=["A-IS-IN-REHAB"])
    got_b = _analyze(client, b["api_token"], context_hints=["B-LIKES-EMOJI"])

    assert "A-IS-IN-REHAB" in got_a["perception"]
    assert "A-IS-IN-REHAB" not in got_b["perception"]
    assert "B-LIKES-EMOJI" in got_b["perception"]


def test_mode_read_does_not_collide_with_mode_coach(client, echo_provider):
    """`read` (interpret a received message) and `coach` (rewrite my draft) are
    different products over the same text and must not share a cache entry."""
    a = _register_entitled(client)

    coach = _analyze(client, a["api_token"], mode="coach")
    read = _analyze(client, a["api_token"], mode="read")

    # coach requests the four canonical axes; read requests none.
    assert len(coach["suggestions"]) == 4
    assert read["suggestions"] == []


def test_identical_input_still_hits_the_cache(client, echo_provider):
    """The fix must not disable caching: a byte-identical provider input still
    serves from cache (one provider call for two requests). Sharing is safe
    here precisely because the second caller supplied every input itself."""
    a = _register_entitled(client)
    b = _register_entitled(client)

    first = _analyze(client, a["api_token"], thread_context="SHARED", recipient_hint="boss")
    second = _analyze(client, b["api_token"], thread_context="SHARED", recipient_hint="boss")

    assert first["perception"] == second["perception"]
    assert len(echo_provider) == 1, (
        f"expected one provider call for identical input, got {len(echo_provider)}"
    )


# --------------------------------------------------------------------------
# The key contract itself
# --------------------------------------------------------------------------


def _key(**kwargs) -> str:
    from backend.analyze import AnalyzeRequest
    from backend.server import _analysis_cache_key

    locale = kwargs.pop("locale", "en")
    provider = kwargs.pop("provider", "anthropic")
    base = {"draft": "hey", "axes": ["warmer", "clearer", "funnier", "safer"]}
    base.update(kwargs)
    return _analysis_cache_key(AnalyzeRequest(**base), locale=locale, provider=provider)


@pytest.mark.parametrize(
    "field,left,right",
    [
        ("thread_context", "thread-A", "thread-B"),
        ("recipient_hint", "boss", "partner"),
        ("context_hints", ["hint-A"], ["hint-B"]),
        ("preferred_voice", "dry", "warm"),
        ("draft", "hey", "hey!"),
        ("mode", "coach", "read"),
        ("custom_instruction", "be terse", "be florid"),
    ],
)
def test_every_prompt_shaping_field_changes_the_key(field, left, right):
    assert _key(**{field: left}) != _key(**{field: right}), (
        f"{field} shapes the provider prompt but does not change the cache key — "
        "a global-cache cross-account leak"
    )


def test_axis_order_and_membership_change_the_key():
    assert _key(axes=["warmer", "clearer"]) != _key(axes=["clearer", "warmer"])
    assert _key(axes=["warmer"]) != _key(axes=["warmer", "clearer"])


def test_wire_level_locale_and_provider_change_the_key():
    assert _key(locale="en") != _key(locale="es")
    assert _key(provider="anthropic") != _key(provider="openai")


def test_identical_request_is_stable_and_hex():
    a, b = _key(thread_context="x"), _key(thread_context="x")
    assert a == b
    assert len(a) == 64 and all(c in "0123456789abcdef" for c in a)


def test_key_covers_every_field_of_the_canonical_request():
    """Structural guard: the key is built from ``AnalyzeRequest.model_dump()``,
    so a NEW prompt-shaping field is covered automatically. This test fails if
    someone reverts to hand-picking a subset."""
    from backend.analyze import AnalyzeRequest

    baseline = _key()
    for name, info in AnalyzeRequest.model_fields.items():
        if name in ("draft", "axes"):
            continue  # exercised above with real values
        annotation = str(info.annotation)
        if "str" in annotation and "list" not in annotation:
            mutated = _key(**{name: "MUTATED"})
        elif "list" in annotation:
            mutated = _key(**{name: ["MUTATED"]})
        else:  # pragma: no cover - defensive
            continue
        assert mutated != baseline, f"AnalyzeRequest.{name} is absent from the cache key"
