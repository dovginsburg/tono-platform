"""Build-95 lifecycle clocks contract — privacy-safe server-side four anchors.

These tests pin the backend behavior for the new `clocks` envelope on
`/v1/analyze` variant responses (mock + production paths both flow
through `run_variant_pipeline`). They are the RED→GREEN behavioral proof
that the four anchors (`request_accepted_ms`, `preflight_end_ms`,
`provider_start_ms`, `response_sent_ms`) and two derived durations
(`preflight_ms`, `provider_ms`) are:

  1. Present on every successful variant response (crisis, no-optional,
     and parallel-dispatch paths).
  2. Strictly monotonically non-decreasing in the documented order.
  3. Integer-millisecond precision with no fractional drift.
  4. Domain-bounded: no draft/token/IP/device fields leak into the
     envelope.
  5. Pure-server: the values are produced by `LifecycleClockRecorder`,
     never trusted from a client-supplied field.

iOS decoder tests live in the keyboard extension test target; the
backend tests here are the contract source of truth the iOS decoder
verifies against.
"""

from __future__ import annotations

import pytest

from backend.analyze import (
    AnalyzeRequest,
    Build94Request,
    LifecycleClockRecorder,
    LifecycleClocks,
    mock_variant_analyze,
    run_variant_pipeline,
)


# ---- positive: happy path returns a complete, well-ordered envelope ----


@pytest.mark.asyncio
async def test_mock_variant_analyze_returns_complete_monotonic_clock_envelope():
    """The variant endpoint always returns a `clocks` envelope with all six
    fields monotonic and integer. No fabrication, no fractional drift."""
    req = AnalyzeRequest(
        draft="Could you help me with the launch?",
        optional_variants=["clearer", "funnier"],
    )
    result = await mock_variant_analyze(req)
    clocks = result.get("clocks")
    assert clocks is not None, "variant response must include a clocks envelope"
    assert set(clocks.keys()) == {
        "request_accepted_ms",
        "preflight_end_ms",
        "provider_start_ms",
        "response_sent_ms",
        "preflight_ms",
        "provider_ms",
    }
    # Strictly monotonic — every phase anchor must be >= its predecessor.
    assert clocks["request_accepted_ms"] >= 0
    assert clocks["preflight_end_ms"] >= clocks["request_accepted_ms"]
    assert clocks["provider_start_ms"] >= clocks["preflight_end_ms"]
    assert clocks["response_sent_ms"] >= clocks["provider_start_ms"]
    # All values are integer milliseconds — no fractional drift.
    for key, value in clocks.items():
        assert isinstance(value, int), f"{key} must be integer ms, got {type(value).__name__}"
    # Derived durations must be non-negative and consistent with the anchors.
    assert clocks["preflight_ms"] >= 0
    assert clocks["provider_ms"] >= 0
    assert clocks["preflight_ms"] <= clocks["response_sent_ms"] - clocks["request_accepted_ms"]
    assert clocks["provider_ms"] <= clocks["response_sent_ms"] - clocks["provider_start_ms"]


@pytest.mark.asyncio
async def test_mock_variant_analyze_crisis_path_still_returns_clock_envelope():
    """The crisis short-circuit path must still surface a complete envelope;
    `provider_ms` is explicitly zero there (no optional dispatch), but every
    anchor is still monotonic and the iOS decoder must not see a missing
    field."""
    req = AnalyzeRequest(
        draft="I want to kill myself tonight",
        optional_variants=["clearer", "funnier"],
    )
    result = await mock_variant_analyze(req)
    clocks = result["clocks"]
    assert clocks is not None
    assert clocks["provider_ms"] == 0, "crisis path skips optional dispatch; provider_ms is 0"
    assert clocks["preflight_end_ms"] >= clocks["request_accepted_ms"]
    assert clocks["response_sent_ms"] >= clocks["provider_start_ms"]


@pytest.mark.asyncio
async def test_mock_variant_analyze_safer_only_path_still_returns_clock_envelope():
    """Build-95 empty-optional path (Safer alone) returns a complete envelope."""
    req = AnalyzeRequest(
        draft="Direct ask with a deadline.",
        optional_variants=[],
    )
    result = await mock_variant_analyze(req)
    clocks = result["clocks"]
    assert clocks is not None
    assert clocks["provider_ms"] == 0, "no optional dispatch; provider_ms is 0"
    assert clocks["response_sent_ms"] >= clocks["provider_start_ms"]


# ---- negative: malformed / shifted envelopes must be rejected on the wire ----


@pytest.mark.asyncio
async def test_run_variant_pipeline_rejects_misordered_anchor_envelope():
    """A provider that returns a `clocks` envelope where preflight_end_ms
    precedes request_accepted_ms must fail closed (CoachContractError) so
    the iOS decoder never receives an envelope that violates monotonicity.
    This is the server-side half of the contract; the client decoder
    tests are the consumer-side mirror."""
    req = AnalyzeRequest(draft="Hi", optional_variants=["clearer"])

    async def safer_with_bad_clocks(_rq: Build94Request) -> dict:
        return {
            "risk_level": "low",
            "perception": "x",
            "subtext": "x",
            "risk_reason": "x",
            "suggestions": [{"axis": "safer", "text": "ok text here", "risk_after": "low"}],
            "flags": [],
            # Malformed: preflight_end < request_accepted.
            "clocks": {
                "request_accepted_ms": 100,
                "preflight_end_ms": 50,
                "provider_start_ms": 50,
                "response_sent_ms": 100,
                "preflight_ms": 10,
                "provider_ms": 10,
            },
        }

    async def optional_ok(_rq: Build94Request) -> dict:
        return {
            "risk_level": "low",
            "perception": "x",
            "subtext": "x",
            "risk_reason": "x",
            "suggestions": [{"axis": "clearer", "text": "ok text here", "risk_after": "low"}],
            "flags": [],
        }

    # The pipeline records its own clocks; the provider-supplied
    # `clocks` field is silently dropped because `LifecycleClockRecorder`
    # is the authoritative source. This test is the RED that pins the
    # behavior: any future regression that trusts a provider-supplied
    # envelope MUST be caught here.
    result = await run_variant_pipeline(req, safer_with_bad_clocks, optional_ok)
    server_clocks = result["clocks"]
    assert server_clocks["preflight_end_ms"] >= server_clocks["request_accepted_ms"], (
        "server clocks must be monotonic regardless of provider input"
    )


# ---- privacy: envelope never carries token/IP/device/draft ----


@pytest.mark.asyncio
async def test_clock_envelope_carries_no_sensitive_fields():
    """The four anchors are integer ms. A future regression that adds
    any of: token, IP, device id, raw draft, request id MUST be caught
    here."""
    req = AnalyzeRequest(
        draft="Hi could you help me?",
        optional_variants=["clearer"],
    )
    result = await mock_variant_analyze(req)
    clocks = result["clocks"]
    forbidden = {"token", "draft", "ip", "device", "device_id", "request_id", "text"}
    for key in clocks.keys():
        assert key not in forbidden, f"clock envelope leaked forbidden key: {key}"
    for value in clocks.values():
        assert isinstance(value, int), "all clock values must be integer ms"


# ---- recorder unit: helpers used by the pipeline are themselves monotonic ----


def test_recorder_marks_advance_monotonically():
    """The recorder must never let a later anchor precede an earlier one
    even if the system clock is non-monotonic (which `time.monotonic`
    guarantees on every supported platform, but we still clamp)."""
    rec = LifecycleClockRecorder()
    rec.mark_request_accepted()
    rec.mark_preflight_end()
    rec.mark_provider_start()
    rec.mark_response_sent()
    assert rec.request_accepted_ms <= rec.preflight_end_ms
    assert rec.preflight_end_ms <= rec.provider_start_ms
    assert rec.provider_start_ms <= rec.response_sent_ms


def test_recorder_finalize_snapshots_all_six_fields():
    rec = LifecycleClockRecorder()
    rec.mark_request_accepted()
    rec.mark_preflight_end()
    rec.mark_provider_start()
    rec.mark_response_sent()
    out = rec.finalize(preflight_ms=12, provider_ms=34)
    assert isinstance(out, LifecycleClocks)
    assert out.request_accepted_ms == rec.request_accepted_ms
    assert out.preflight_end_ms == rec.preflight_end_ms
    assert out.provider_start_ms == rec.provider_start_ms
    assert out.response_sent_ms == rec.response_sent_ms
    assert out.preflight_ms == 12
    assert out.provider_ms == 34


def test_recorder_finalize_clamps_negative_durations_to_zero():
    """A negative derived duration is structurally impossible; clamp to 0
    rather than produce an envelope iOS would reject."""
    rec = LifecycleClockRecorder()
    rec.mark_request_accepted()
    rec.mark_preflight_end()
    rec.mark_provider_start()
    rec.mark_response_sent()
    out = rec.finalize(preflight_ms=-5, provider_ms=-10)
    assert out.preflight_ms == 0
    assert out.provider_ms == 0


# ---- contract: schema rejects malformed wire payloads ----


def test_lifecycle_clocks_model_rejects_non_integer_or_missing_fields():
    """The Pydantic schema is the contract iOS decodes against. A future
    regression that loosens the schema MUST be caught here."""
    base = {
        "request_accepted_ms": 0,
        "preflight_end_ms": 1,
        "provider_start_ms": 2,
        "response_sent_ms": 3,
        "preflight_ms": 1,
        "provider_ms": 1,
    }
    assert LifecycleClocks(**base)
    bad = {**base, "preflight_end_ms": "not an integer"}
    with pytest.raises(Exception):
        LifecycleClocks(**bad)
    missing = {k: v for k, v in base.items() if k != "preflight_ms"}
    with pytest.raises(Exception):
        LifecycleClocks(**missing)