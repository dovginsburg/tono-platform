"""Hostile tests for the selected-tone latency path.

These lock the four properties the latency work must never trade away:

  1. EXACT-ONE SELECTED TONE -- one tap dispatches exactly one provider call,
     for exactly the axis the user selected. No fan-out, no auto-selection,
     no hidden Safer generation on the selected-variant path.
  2. NO SAFETY BYPASS -- the deterministic preflight still runs first, still
     issues zero provider calls, and still blocks every unsafe input, with the
     clock envelope present or absent making no difference.
  3. CANCELLATION / TIMEOUT TRUTH -- the pooled provider client carries the
     same 30s timeout the per-call client did, a cancelled request does not
     poison the pooled connection for the next one, and a cancellation
     propagates rather than being silently swallowed into a fake success.
  4. NO CONTENT / NO PII IN TELEMETRY -- every emitted timing value is an
     integer duration; no draft text, token, device id, IP, or provider name
     reaches the clock envelope or the phase log.

Plus conformance of the emitted `clocks` envelope with the *exact* rules the
shipping iOS decoder applies (`TonoCoachClient.decodeServerClocks`), because
the server now emits an envelope the client will strictly validate.

Every draft used here is synthetic and generated in-process. No production
corpus, no user content, no PII.
"""

from __future__ import annotations

import asyncio
import importlib.util
import json
import logging
import os
import sys

import httpx
import pytest
from fastapi import HTTPException

from backend.analyze import (
    VARIANT_ALLOWLIST,
    AnalyzeRequest,
    Build94Request,
    LifecycleClockRecorder,
    VariantBlockedReason,
    VariantRequest,
    VariantResponse,
    _PROVIDER_LIMITS,
    _PROVIDER_TIMEOUT_SECONDS,
    aclose_provider_client,
    invoke_single_variant,
    mock_single_variant,
    preflight_variant,
    provider_client,
    run_variant_pipeline,
)

# ---------------------------------------------------------------------------
# Synthetic, content-free fixtures.
# ---------------------------------------------------------------------------

# A distinctive synthetic marker. Nothing in any emitted envelope or log line
# may ever contain it. It is not a message; it is a canary.
CANARY = "zzqx-synthetic-canary-7788"

SYNTHETIC_DRAFTS = (
    "alpha bravo charlie",
    "delta echo foxtrot golf hotel india juliet",
    "kilo lima mike november oscar papa quebec romeo sierra tango",
    f"uniform victor {CANARY} whiskey xray",
)

# Axes that take the plain single-attempt path. `funnier` has a bounded retry
# and `custom` needs a directive, so they get their own dedicated cases.
PLAIN_AXES = ("warmer", "clearer", "safer", "affectionate", "professional",
              "concise")


class ProviderSpy:
    """Records every provider dispatch: which axis, in what order."""

    def __init__(self) -> None:
        self.axes: list[str] = []
        self.calls = 0

    def __call__(self, req):  # signature of `mock_single_variant`
        self.calls += 1
        self.axes.append(req.axis)
        return mock_single_variant(req)


# The autouse `_isolate_db` fixture in conftest purges every `backend.*` module
# between tests, so `import backend.analyze` inside a test yields a FRESH
# module object whose globals are NOT the ones the `invoke_single_variant`
# imported at collection time actually reads. Patching that fresh module would
# silently no-op and let the REAL provider function run -- which would attempt
# a live outbound call. Patch the dispatcher's own globals instead: that is
# exactly the namespace `_provider_call` resolves against, and it is immune to
# module purging.
ANALYZE_GLOBALS = invoke_single_variant.__globals__


@pytest.fixture
def spy(monkeypatch) -> ProviderSpy:
    """Patch the mock provider so every dispatch is observable."""
    s = ProviderSpy()
    monkeypatch.setitem(ANALYZE_GLOBALS, "mock_single_variant", s)
    return s


@pytest.fixture(autouse=True)
def _no_live_provider_calls(monkeypatch):
    """Hard guarantee: no test in this file may open a real provider socket.

    Both escape hatches are closed: obtaining the pooled client, AND
    constructing a raw `httpx.AsyncClient` inside `analyze.py`. The second one
    matters -- a regression back to a per-call client would otherwise sail
    straight past a `provider_client`-only guard and open a real socket to the
    provider. Tests that legitimately exercise the pooled transport build
    their own client against a loopback stub origin or a MockTransport.
    """
    def _forbidden(*_a, **_k):
        raise AssertionError(
            "a test attempted a live provider call from backend.analyze"
        )

    class _NoNetworkAsyncClient(httpx.AsyncClient):
        """Constructs fine; refuses to dispatch.

        Construction must still work, because the pooling tests below inspect
        a real client's timeout and identity without ever issuing a request.
        Every dispatch path (`request` covers `post`; `send` covers streaming)
        fails loudly instead of opening a socket.
        """

        async def request(self, *_a, **_k):
            _forbidden()

        async def send(self, *_a, **_k):
            _forbidden()

    class _NoNetworkHttpx:
        """Stands in for the `httpx` module inside analyze.py's namespace."""
        AsyncClient = _NoNetworkAsyncClient

        def __getattr__(self, name):  # everything else passes through
            return getattr(httpx, name)

    monkeypatch.setitem(ANALYZE_GLOBALS, "provider_client", _forbidden)
    monkeypatch.setitem(ANALYZE_GLOBALS, "httpx", _NoNetworkHttpx())


# ---------------------------------------------------------------------------
# 1. EXACT-ONE SELECTED TONE
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@pytest.mark.parametrize("axis", PLAIN_AXES)
@pytest.mark.parametrize("draft", SYNTHETIC_DRAFTS)
async def test_one_tap_is_exactly_one_provider_call_for_the_selected_axis(
    axis, draft, spy
):
    """One tap -> exactly one provider call, for exactly the selected axis."""
    resp = await invoke_single_variant(VariantRequest(text=draft, axis=axis), "mock")
    assert resp.status == "ok"
    assert resp.axis == axis
    assert spy.calls == 1, f"expected exactly 1 provider call, got {spy.calls}"
    assert spy.axes == [axis], f"dispatched axes {spy.axes} != [{axis}]"


@pytest.mark.asyncio
@pytest.mark.parametrize("axis", PLAIN_AXES)
async def test_selected_variant_never_generates_safer_behind_the_users_back(
    axis, spy
):
    """No hidden Safer generation on the selected-variant path.

    This is the mission's central question, answered by measurement rather
    than assumption: on the endpoint the keyboard actually calls for a tone
    tap, Safer is NOT dispatched ahead of the user's chosen tone. The safety
    gate on this path is the deterministic, provider-free `preflight_variant`.
    """
    await invoke_single_variant(
        VariantRequest(text="alpha bravo charlie", axis=axis), "mock"
    )
    if axis != "safer":
        assert "safer" not in spy.axes, (
            "a hidden Safer provider call serialized ahead of the user's "
            f"selected tone {axis!r}: {spy.axes}"
        )
    assert len(spy.axes) == 1


@pytest.mark.asyncio
async def test_selected_variant_never_fans_out_to_other_axes(spy):
    """Selecting one tone must never produce an alternative the user did not
    ask for -- not as a prefetch, not as a fallback, not as a second opinion.
    """
    await invoke_single_variant(
        VariantRequest(text="alpha bravo charlie", axis="warmer"), "mock"
    )
    assert spy.axes == ["warmer"]
    for other in VARIANT_ALLOWLIST - {"warmer"}:
        assert other not in spy.axes


@pytest.mark.asyncio
async def test_custom_axis_is_still_exactly_one_call(spy):
    resp = await invoke_single_variant(
        VariantRequest(text="alpha bravo", axis="custom",
                       custom_prompt="be brief"),
        "mock",
    )
    assert resp.status == "ok"
    assert spy.calls == 1
    assert spy.axes == ["custom"]


# ---------------------------------------------------------------------------
# 2. THE SAFER-SERIALIZATION FINDING (documented, deliberately NOT changed)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_fanout_pipeline_serializes_safer_before_every_optional():
    """The build-94 fan-out path DOES serialize a full Safer provider round
    trip before any optional is dispatched.

    This test exists to DOCUMENT and LOCK that ordering, not to complain about
    it. Safer is an isolated permission gate; collapsing, parallelizing, or
    removing it is a safety-contract change and is explicitly out of scope for
    latency work. If a future change makes an optional start before the Safer
    gate has a verdict, this test must fail loudly.
    """
    events: list[str] = []

    async def safer_generate(rq: Build94Request):
        events.append("safer:start")
        await asyncio.sleep(0.01)
        events.append("safer:end")
        return {
            "risk_level": "low", "perception": "p", "subtext": "s",
            "flags": [],
            "suggestions": [{"axis": "safer", "text": "alpha bravo charlie",
                             "rationale": "r", "risk_after": "low"}],
        }

    async def optional_generate(rq: Build94Request):
        events.append(f"optional:{rq.axis}:start")
        await asyncio.sleep(0.01)
        events.append(f"optional:{rq.axis}:end")
        return {
            "suggestions": [{"axis": rq.axis,
                             "text": f"{rq.axis} rewrite delta echo foxtrot",
                             "rationale": "r", "risk_after": "low"}],
        }

    req = AnalyzeRequest(
        draft="alpha bravo charlie",
        optional_variants=["clearer", "professional"],
    )
    await run_variant_pipeline(req, safer_generate, optional_generate)

    assert events[0] == "safer:start"
    assert events[1] == "safer:end"
    first_optional = next(i for i, e in enumerate(events)
                          if e.startswith("optional:"))
    assert first_optional > events.index("safer:end"), (
        "an optional variant was dispatched before the Safer gate had a "
        f"verdict: {events}"
    )


# ---------------------------------------------------------------------------
# 3. NO SAFETY BYPASS
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@pytest.mark.parametrize("axis", sorted(VARIANT_ALLOWLIST))
async def test_crisis_draft_blocks_with_zero_provider_calls(axis, spy):
    """A crisis draft is blocked deterministically, before any provider call,
    for every axis -- and the blocked envelope carries no clocks and no
    provider duration, because no provider ran.
    """
    resp = await invoke_single_variant(
        VariantRequest(text="i want to die", axis=axis,
                       custom_prompt="be brief" if axis == "custom" else None),
        "mock",
    )
    assert resp.status == "blocked"
    assert resp.reason == VariantBlockedReason.PREFLIGHT_CRISIS_KEYWORDS
    assert spy.calls == 0, "a provider was called for a crisis draft"
    assert resp.clocks is None


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "req,expected",
    [
        (VariantRequest(text="", axis="warmer"),
         VariantBlockedReason.PREFLIGHT_EMPTY_DRAFT),
        (VariantRequest(text="   ", axis="warmer"),
         VariantBlockedReason.PREFLIGHT_EMPTY_DRAFT),
        (VariantRequest(text="alpha", axis="not_a_real_axis"),
         VariantBlockedReason.PREFLIGHT_UNKNOWN_VARIANT),
        (VariantRequest(text="alpha", axis="custom"),
         VariantBlockedReason.PREFLIGHT_CUSTOM_PROMPT_REQUIRED),
        (VariantRequest(text="alpha", axis="custom", custom_prompt="x" * 241),
         VariantBlockedReason.PREFLIGHT_CUSTOM_PROMPT_TOO_LONG),
    ],
)
async def test_preflight_blocks_issue_zero_provider_calls(req, expected, spy):
    resp = await invoke_single_variant(req, "mock")
    assert resp.status == "blocked"
    assert resp.reason == expected
    assert spy.calls == 0
    assert resp.clocks is None


def test_preflight_is_pure_and_provider_free():
    """`preflight_variant` must stay a pure in-process decision. If it ever
    grows a provider call it becomes a latency AND a safety problem.
    """
    src = importlib.util.find_spec("backend.analyze")
    assert src is not None and src.origin
    with open(src.origin, "r", encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    start = next(i for i, l in enumerate(lines)
                 if l.startswith("def preflight_variant("))
    end = next(i for i in range(start + 1, len(lines))
               if lines[i].startswith("def ") or lines[i].startswith("class "))
    body = "\n".join(lines[start:end])
    for forbidden in ("await", "httpx", "provider_client", "AsyncClient",
                      "requests.", "urlopen"):
        assert forbidden not in body, (
            f"preflight_variant gained {forbidden!r}: the safety gate must "
            "stay deterministic and provider-free"
        )


@pytest.mark.asyncio
async def test_preflight_runs_before_the_provider_not_after(spy):
    """Ordering, not just presence: a crisis draft must never reach a provider
    even though the same draft on a permitted axis would."""
    await invoke_single_variant(
        VariantRequest(text="alpha bravo", axis="warmer"), "mock")
    assert spy.calls == 1
    await invoke_single_variant(
        VariantRequest(text="i want to die", axis="warmer"), "mock")
    assert spy.calls == 1, "crisis draft reached the provider"


# ---------------------------------------------------------------------------
# 4. CLOCK ENVELOPE: iOS DECODER CONFORMANCE
# ---------------------------------------------------------------------------


def assert_ios_decoder_would_accept(clocks_dict, elapsed_ms: float) -> None:
    """Apply the EXACT rules `TonoCoachClient.decodeServerClocks` applies.

    Ported from KeyboardExtension/TonoCoachClient.swift so a server-side
    change cannot start emitting an envelope the shipping client would reject
    (a rejected envelope is a decode failure -- the user's rewrite would not
    render at all).
    """
    required = ["request_accepted_ms", "preflight_end_ms",
                "provider_start_ms", "response_sent_ms"]
    for key in required:
        assert key in clocks_dict, f"missing key: {key}"
        value = clocks_dict[key]
        # strictInt64Ms: integer only. Rejects float and bool.
        assert isinstance(value, int) and not isinstance(value, bool), (
            f"{key} must be a non-bool integer, got {type(value).__name__}"
        )
    request = clocks_dict["request_accepted_ms"]
    preflight = clocks_dict["preflight_end_ms"]
    provider = clocks_dict["provider_start_ms"]
    response = clocks_dict["response_sent_ms"]
    assert min(request, preflight, provider, response) >= 0
    assert request <= preflight <= provider <= response, (
        "anchors must be monotonically non-decreasing"
    )
    # Cross-domain sanity: response_sent_ms must not exceed the client's
    # observed elapsed time plus the 60s grace window.
    assert response <= max(0, int(elapsed_ms)) + 60_000


@pytest.mark.asyncio
@pytest.mark.parametrize("axis", PLAIN_AXES)
@pytest.mark.parametrize("draft", SYNTHETIC_DRAFTS)
async def test_emitted_clocks_pass_the_ios_decoder_rules(axis, draft):
    loop = asyncio.get_running_loop()
    t0 = loop.time()
    resp = await invoke_single_variant(VariantRequest(text=draft, axis=axis),
                                       "mock")
    elapsed_ms = (loop.time() - t0) * 1000.0
    assert resp.status == "ok"
    assert resp.clocks is not None, "ok envelope must carry truthful clocks"
    assert_ios_decoder_would_accept(resp.clocks.model_dump(), elapsed_ms)


@pytest.mark.asyncio
async def test_provider_ms_is_truthful_and_matches_the_envelope():
    resp = await invoke_single_variant(
        VariantRequest(text="alpha bravo charlie", axis="warmer"), "mock")
    assert resp.clocks is not None
    # The provider duration is carried INSIDE the clocks envelope. It is
    # already part of the checked-in OpenAPI contract, so delivering it costs
    # no wire-contract change; it must also be derivable from the anchors.
    assert resp.clocks.provider_ms >= 0
    assert (resp.clocks.provider_ms
            == resp.clocks.response_sent_ms - resp.clocks.provider_start_ms)
    # The provider segment can never exceed the whole server-side span.
    assert resp.clocks.provider_ms <= resp.clocks.response_sent_ms
    assert resp.clocks.preflight_ms >= 0
    assert (resp.clocks.preflight_ms
            <= resp.clocks.response_sent_ms - resp.clocks.request_accepted_ms)


@pytest.mark.asyncio
async def test_provider_ms_reflects_real_provider_time_not_a_constant(monkeypatch):
    """The provider clock must MEASURE, not report a placeholder."""
    def slow(req):
        import time as _t
        _t.sleep(0.05)
        return mock_single_variant(req)

    monkeypatch.setitem(ANALYZE_GLOBALS, "mock_single_variant", slow)
    resp = await invoke_single_variant(
        VariantRequest(text="alpha bravo", axis="warmer"), "mock")
    assert resp.clocks is not None
    assert resp.clocks.provider_ms >= 45, (
        "provider clock did not measure a real 50ms call: "
        f"{resp.clocks.provider_ms}"
    )


@pytest.mark.asyncio
async def test_recorder_anchors_are_monotonic_under_a_zero_duration_call():
    """A call fast enough to land inside one millisecond must still produce a
    non-decreasing envelope rather than an out-of-order one.
    """
    for _ in range(200):
        resp = await invoke_single_variant(
            VariantRequest(text="alpha", axis="warmer"), "mock")
        c = resp.clocks
        assert c is not None
        assert (c.request_accepted_ms <= c.preflight_end_ms
                <= c.provider_start_ms <= c.response_sent_ms)


def test_lifecycle_recorder_clamps_out_of_order_marks():
    """The recorder's clamping is what makes the iOS ordering rule safe."""
    rec = LifecycleClockRecorder()
    rec.mark_request_accepted()
    rec.preflight_end_ms = 10_000  # simulate a large earlier anchor
    rec.mark_provider_start()
    assert rec.provider_start_ms >= rec.preflight_end_ms
    rec.mark_response_sent()
    assert rec.response_sent_ms >= rec.provider_start_ms
    env = rec.finalize(preflight_ms=-5, provider_ms=-9)
    assert env.preflight_ms == 0 and env.provider_ms == 0


# ---------------------------------------------------------------------------
# 5. NO CONTENT / NO PII IN TELEMETRY
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@pytest.mark.parametrize("axis", PLAIN_AXES)
async def test_clock_envelope_contains_only_integer_durations(axis):
    resp = await invoke_single_variant(
        VariantRequest(text=f"alpha {CANARY} bravo", axis=axis), "mock")
    envelope = resp.clocks.model_dump()
    assert set(envelope) == {
        "request_accepted_ms", "preflight_end_ms", "provider_start_ms",
        "response_sent_ms", "preflight_ms", "provider_ms",
    }
    for key, value in envelope.items():
        assert isinstance(value, int) and not isinstance(value, bool), key
    # A canary that appears nowhere in the telemetry surface.
    assert CANARY not in str(envelope)


@pytest.mark.asyncio
async def test_phase_log_lines_carry_no_draft_no_token_no_device(caplog):
    """The server's phase log must stay `request_id / phase / dt_ms`."""
    from backend import server as server_mod

    caplog.set_level(logging.INFO)
    server_mod._log_phase("deadbeef", server_mod._PHASE_PROVIDER_START, 0.0)
    records = [r.getMessage() for r in caplog.records
               if "tono.phase" in r.getMessage()]
    assert records, "no phase line emitted"
    for line in records:
        assert CANARY not in line
        for token in ("Bearer", "api_token", "device_id", "draft", "text=",
                      "anthropic", "openai", "x-api-key"):
            assert token not in line, f"phase line leaked {token!r}: {line}"


def test_variant_response_telemetry_is_numeric_only():
    """`clocks` is the ONLY telemetry-shaped field on the envelope, and every
    value inside it must be a number. No latency work may add a free-text
    field to a response the client renders."""
    rec = LifecycleClockRecorder()
    rec.mark_request_accepted()
    rec.mark_preflight_end()
    rec.mark_provider_start()
    rec.mark_response_sent()
    resp = VariantResponse(status="ok", axis="warmer", text="alpha",
                           clocks=rec.finalize(preflight_ms=1, provider_ms=2))
    dumped = resp.model_dump()
    assert set(dumped) == {"status", "axis", "text", "rationale", "risk_after",
                           "model", "tier", "clocks", "reason"}, (
        "the variant envelope grew a field: confirm it is content-free and "
        "that packages/contracts/openapi.json was regenerated deliberately"
    )
    for key, value in dumped["clocks"].items():
        assert isinstance(value, int) and not isinstance(value, bool), key


# ---------------------------------------------------------------------------
# 6. POOLED PROVIDER CLIENT: reuse, timeout truth, cancellation truth
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_provider_client_is_reused_within_one_event_loop():
    await aclose_provider_client()
    try:
        first = provider_client()
        second = provider_client()
        assert first is second, "provider client was rebuilt per call"
    finally:
        await aclose_provider_client()


@pytest.mark.asyncio
async def test_provider_client_timeout_is_unchanged_at_30s():
    """Connection reuse must not quietly change how long a call may run."""
    await aclose_provider_client()
    try:
        client = provider_client()
        timeout = client.timeout
        assert _PROVIDER_TIMEOUT_SECONDS == 30
        for field in ("connect", "read", "write", "pool"):
            assert getattr(timeout, field) == 30, (
                f"timeout.{field} == {getattr(timeout, field)}, expected 30"
            )
    finally:
        await aclose_provider_client()


def test_each_event_loop_gets_its_own_provider_client():
    """A client must never be shared across loops: its connections are bound
    to the loop that opened them.
    """
    async def grab():
        try:
            return provider_client()
        finally:
            await aclose_provider_client()

    # Hold both objects alive: comparing ids alone would be unsound, because
    # CPython can reuse the id of a freed object.
    first = asyncio.run(grab())
    second = asyncio.run(grab())
    assert first is not second


@pytest.mark.asyncio
async def test_aclose_provider_client_is_safe_when_none_exists():
    await aclose_provider_client()
    await aclose_provider_client()  # must not raise


@pytest.mark.asyncio
async def test_closed_client_is_replaced_not_reused():
    await aclose_provider_client()
    try:
        first = provider_client()
        await first.aclose()
        second = provider_client()
        assert second is not first
        assert not second.is_closed
    finally:
        await aclose_provider_client()


class _StubOrigin:
    """Loopback origin used to prove pooling + cancellation behaviour."""

    def __init__(self, delay: float = 0.0) -> None:
        self.delay = delay
        self.connections = 0
        # Concurrency instrumentation: `connections` counts connections ever
        # opened; `peak` is the most that were open at the SAME instant. Only
        # the latter can detect a pool that silently serializes callers.
        self.active = 0
        self.peak = 0
        self.server = None
        self.port = 0

    async def start(self) -> None:
        self.server = await asyncio.start_server(self._handle, "127.0.0.1", 0)
        self.port = self.server.sockets[0].getsockname()[1]

    async def _handle(self, reader, writer) -> None:
        self.connections += 1
        self.active += 1
        self.peak = max(self.peak, self.active)
        try:
            while True:
                head = await reader.readuntil(b"\r\n\r\n")
                length = 0
                for line in head.split(b"\r\n"):
                    if line.lower().startswith(b"content-length:"):
                        length = int(line.split(b":", 1)[1].strip())
                if length:
                    await reader.readexactly(length)
                if self.delay:
                    await asyncio.sleep(self.delay)
                body = b'{"ok":true}'
                writer.write(
                    b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                    b"Content-Length: " + str(len(body)).encode()
                    + b"\r\nConnection: keep-alive\r\n\r\n" + body
                )
                await writer.drain()
        except (asyncio.IncompleteReadError, ConnectionResetError,
                asyncio.CancelledError, OSError):
            pass
        finally:
            self.active -= 1
            try:
                writer.close()
            except Exception:
                pass

    async def stop(self) -> None:
        if self.server is not None:
            self.server.close()
            await self.server.wait_closed()


@pytest.mark.asyncio
async def test_pooled_client_actually_reuses_one_tcp_connection():
    """The mechanism, measured: N sequential calls must open ONE connection.

    This is the property the latency change buys. If a future refactor goes
    back to a client per call, this fails.
    """
    origin = _StubOrigin()
    await origin.start()
    client = httpx.AsyncClient(timeout=_PROVIDER_TIMEOUT_SECONDS)
    try:
        url = f"http://127.0.0.1:{origin.port}/v1/messages"
        for _ in range(10):
            r = await client.post(url, json={"n": 1})
            assert r.status_code == 200
        assert origin.connections == 1, (
            f"expected 1 pooled connection, origin saw {origin.connections}"
        )
    finally:
        await client.aclose()
        await origin.stop()


def _anthropic_ok_body(axis: str) -> dict:
    """A minimal well-formed Anthropic response for one atomic variant."""
    payload = json.dumps({
        "suggestions": [{
            "axis": axis,
            "text": "alpha bravo charlie delta",
            "rationale": "synthetic",
            "risk_after": "low",
        }],
    })
    return {"content": [{"type": "text", "text": payload}]}


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "fn_name,env_key,url_host",
    [
        ("anthropic_single_variant", "ANTHROPIC_API_KEY", "api.anthropic.com"),
        ("openai_single_variant", "OPENAI_API_KEY", "api.openai.com"),
    ],
)
async def test_selected_tone_provider_dispatches_through_the_pooled_client(
    fn_name, env_key, url_host, monkeypatch
):
    """PRODUCTION dispatch must go through the pooled client.

    The previous shape built a fresh `httpx.AsyncClient` inside each provider
    function, so every tone tap paid a full connection establishment. This
    asserts the real function now asks for the pooled client exactly once per
    call -- it is the test that would fail if someone reintroduced a per-call
    client. No socket is opened: the pooled client is backed by an in-memory
    MockTransport, and the assertion on the requested URL proves the call was
    aimed at the real provider endpoint without ever leaving the process.
    """
    seen: list[str] = []
    grabs = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request.url.host)
        if url_host == "api.openai.com":
            return httpx.Response(200, json={"choices": [{"message": {
                "content": json.dumps({"suggestions": [{
                    "axis": "warmer", "text": "alpha bravo charlie delta",
                    "rationale": "synthetic", "risk_after": "low"}]}),
            }}]})
        return httpx.Response(200, json=_anthropic_ok_body("warmer"))

    pooled = httpx.AsyncClient(transport=httpx.MockTransport(handler),
                               timeout=_PROVIDER_TIMEOUT_SECONDS)

    def fake_pool():
        grabs["n"] += 1
        return pooled

    monkeypatch.setitem(ANALYZE_GLOBALS, "provider_client", fake_pool)
    monkeypatch.setenv(env_key, "synthetic-key-never-real")
    try:
        fn = ANALYZE_GLOBALS[fn_name]
        out = await fn(VariantRequest(text="alpha bravo", axis="warmer"),
                       "synthetic-model")
        assert out["axis"] == "warmer"
        assert grabs["n"] == 1, (
            f"{fn_name} obtained the provider client {grabs['n']} times; "
            "expected exactly one pooled handle per call"
        )
        assert seen == [url_host]
    finally:
        await pooled.aclose()


@pytest.mark.asyncio
async def test_no_provider_function_constructs_its_own_client_per_call():
    """Source-level backstop for the same property, across every provider
    function on a tone path. A per-call `httpx.AsyncClient(...)` here is
    exactly the regression the pooled client removes.
    """
    src = importlib.util.find_spec("backend.analyze")
    assert src is not None and src.origin
    with open(src.origin, "r", encoding="utf-8") as fh:
        lines = fh.read().splitlines()

    for fn_name in ("_anthropic_post", "anthropic_single_variant",
                    "openai_single_variant"):
        start = next(i for i, l in enumerate(lines)
                     if l.startswith(f"async def {fn_name}("))
        end = next(i for i in range(start + 1, len(lines))
                   if lines[i].startswith(("def ", "async def ", "class ")))
        body = "\n".join(lines[start:end])
        assert "httpx.AsyncClient(" not in body, (
            f"{fn_name} builds its own client per call; use provider_client()"
        )
        assert "provider_client()" in body, (
            f"{fn_name} no longer dispatches through the pooled client"
        )


@pytest.mark.asyncio
async def test_cancelling_one_request_does_not_poison_the_pooled_client():
    """Cancellation truth: a cancelled tap must not corrupt the next tap.

    The keyboard cancels the in-flight task at every editing-session boundary
    and on its visible deadline, so this happens routinely in production.
    """
    origin = _StubOrigin(delay=0.5)
    await origin.start()
    client = httpx.AsyncClient(timeout=_PROVIDER_TIMEOUT_SECONDS)
    try:
        url = f"http://127.0.0.1:{origin.port}/v1/messages"
        task = asyncio.ensure_future(client.post(url, json={"n": 1}))
        await asyncio.sleep(0.05)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        # The very next call on the SAME pooled client must still succeed.
        origin.delay = 0.0
        r = await client.post(url, json={"n": 2})
        assert r.status_code == 200
        assert r.json() == {"ok": True}
    finally:
        await client.aclose()
        await origin.stop()


@pytest.mark.asyncio
async def test_provider_httpexception_surfaces_as_a_blocked_envelope_not_a_hang(
    monkeypatch,
):
    """An ``HTTPException`` provider failure must fail closed into the strict
    blocked envelope -- never a fabricated rewrite, never the draft echoed back
    as success.

    SCOPE, precisely: ``invoke_single_variant`` catches ``HTTPException`` and
    nothing else, so this is the fail-closed guarantee in full. It is what the
    provider functions raise for a non-200 status, a parse failure, a contract
    violation, and an unknown provider -- i.e. every failure they classify
    themselves. A raw transport error is a DIFFERENT case and is pinned
    separately by
    ``test_real_transport_errors_propagate_and_are_not_converted_to_blocked``;
    do not read this test as covering it.

    The provider function is replaced in the dispatcher's own globals, so the
    real Anthropic function is never reachable and no socket is opened.
    """
    async def timing_out(req, model):
        raise HTTPException(502, "Anthropic API error: timeout")

    monkeypatch.setitem(ANALYZE_GLOBALS, "anthropic_single_variant", timing_out)
    resp = await invoke_single_variant(
        VariantRequest(text="alpha bravo charlie", axis="warmer"), "anthropic")
    assert resp.status == "blocked"
    assert resp.reason == VariantBlockedReason.PROVIDER_FAILED
    assert resp.text is None
    assert resp.clocks is None


@pytest.mark.asyncio
async def test_cancellation_propagates_and_is_not_swallowed_as_success(
    monkeypatch,
):
    """A cancelled dispatch must propagate, not degrade into a fake result."""
    def cancelling(req):
        raise asyncio.CancelledError()

    monkeypatch.setitem(ANALYZE_GLOBALS, "mock_single_variant", cancelling)
    with pytest.raises(asyncio.CancelledError):
        await invoke_single_variant(
            VariantRequest(text="alpha bravo", axis="warmer"), "mock")


# ---------------------------------------------------------------------------
# 7. THE PROBE HARNESS ITSELF IS CONTENT-FREE
# ---------------------------------------------------------------------------


def _load_probe():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(here, "scripts", "latency_probe.py")
    spec = importlib.util.spec_from_file_location("tono_latency_probe", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["tono_latency_probe"] = module
    spec.loader.exec_module(module)
    return module


def test_probe_axes_are_a_subset_of_the_server_allowlist():
    """The probe must exercise real axes, and can never drift into inventing
    one the server would reject."""
    probe = _load_probe()
    assert set(probe.PROBE_AXES) <= VARIANT_ALLOWLIST


def test_probe_corpus_is_synthetic_bounded_and_content_free():
    probe = _load_probe()
    corpus = probe.synthetic_corpus()
    assert len(corpus) == len(probe.CORPUS_BUCKETS) * probe.CORPUS_PER_BUCKET
    allowed = set(probe._TOKENS)
    for entry in corpus:
        assert entry, "empty corpus entry"
        assert len(entry) <= max(probe.CORPUS_BUCKETS)
        # Every whole word must come from the fixed filler vocabulary. The
        # final word may be truncated by the length bucket, so it only has to
        # be a PREFIX of a filler token -- never arbitrary text.
        words = entry.split()
        for word in words[:-1]:
            assert word in allowed, f"non-filler token in corpus: {word!r}"
        assert any(t.startswith(words[-1]) for t in allowed), words[-1]


def test_probe_sample_records_carry_no_content():
    """A sample record may only ever hold an index, an axis token, a LENGTH,
    and a duration."""
    probe = _load_probe()
    samples = asyncio.run(_probe_samples(probe))
    assert samples
    for record in samples:
        assert set(record) == {"n", "axis", "draft_chars", "ms"}
        assert isinstance(record["n"], int)
        assert isinstance(record["draft_chars"], int)
        assert isinstance(record["ms"], float)
        assert record["axis"] == "n/a" or record["axis"] in VARIANT_ALLOWLIST


async def _probe_samples(probe):
    origin = _StubOrigin()
    await origin.start()
    try:
        return await probe._drive_transport(
            f"http://127.0.0.1:{origin.port}/v1/messages",
            3, pooled=True, verify=True,
        )
    finally:
        await origin.stop()


def test_probe_percentiles_are_nearest_rank_and_deterministic():
    probe = _load_probe()
    values = [float(v) for v in range(1, 101)]
    assert probe.percentile(values, 50) == 50.0
    assert probe.percentile(values, 95) == 95.0
    assert probe.percentile([], 50) == 0.0
    assert probe.percentile([7.0], 95) == 7.0


def test_probe_pool_limits_match_the_server_pool_limits():
    """The probe's pooled arm must measure the client the server actually
    builds. If the server's limits move and the probe's do not, the benchmark
    quietly stops describing production.
    """
    probe = _load_probe()
    assert probe.PROBE_TIMEOUT_SECONDS == _PROVIDER_TIMEOUT_SECONDS
    limits = probe.probe_limits()
    assert limits.max_connections == _PROVIDER_LIMITS.max_connections
    assert (limits.max_keepalive_connections
            == _PROVIDER_LIMITS.max_keepalive_connections)
    assert limits.keepalive_expiry == _PROVIDER_LIMITS.keepalive_expiry


# ---------------------------------------------------------------------------
# 8. THE SHARED-POOL CONCURRENCY DELTA (verifier finding F-1) AND THE EXACT
#    BOUNDARY OF THE FAIL-CLOSED GUARANTEE (verifier finding F-2)
# ---------------------------------------------------------------------------
#
# F-1. Moving from a client-per-call to one shared client is only non-semantic
# if the shared pool never makes a caller WAIT. With httpx's default
# `max_connections=100`, it would: past 100 in-flight provider calls on one
# event loop, callers queue, the wait is charged to the same 30s budget via
# the `pool` timeout component, and the resulting `httpx.PoolTimeout` is a
# failure mode the per-call shape could not produce at all. These tests prove
# the queueing mechanism is real, prove the shipped limits do not exhibit it,
# and prove the escape route that would make it user-visible.
#
# F-2. `invoke_single_variant` catches `HTTPException` and nothing else. Raw
# transport errors propagate as 5xx. That is PRE-EXISTING -- it behaves
# identically on the untouched parent -- and it is pinned here so no one can
# read the fail-closed property as broader than it is.


def _connection_pool_limits(client: httpx.AsyncClient) -> tuple:
    """Read the connection-pool bounds actually installed on a client.

    Deliberately not written with `getattr(..., default)`: if httpx renames
    these internals, this must fail loudly rather than silently pass on a
    bound nobody is checking any more.
    """
    pool = client._transport._pool
    return (pool._max_connections, pool._max_keepalive_connections)


def test_provider_limits_are_declared_not_inherited_from_httpx():
    """The shipped pool must declare an unbounded connection count.

    This is the single value that decides whether the transport change is
    behaviour-preserving. Setting it to httpx's default 100 reintroduces both
    the shared ceiling and the `PoolTimeout` failure mode.
    """
    assert _PROVIDER_LIMITS.max_connections is None, (
        "the shared provider pool grew a connection ceiling the per-call "
        "shape never had; see the F-1 note above _PROVIDER_LIMITS"
    )
    assert _PROVIDER_LIMITS.max_keepalive_connections == 20
    assert _PROVIDER_LIMITS.keepalive_expiry == 5.0


@pytest.mark.asyncio
async def test_pooled_provider_client_is_unbounded_unlike_a_default_httpx_client():
    """The limits reach the real client, not just the constant.

    The contrast against a stock client is measured in-test rather than
    hard-coded, so this cannot pass by accident if httpx changes its default.
    """
    await aclose_provider_client()
    reference = httpx.AsyncClient()
    try:
        pooled_max, pooled_keepalive = _connection_pool_limits(provider_client())
        default_max, _ = _connection_pool_limits(reference)
        assert default_max == 100, (
            f"httpx's default max_connections is now {default_max}; re-read "
            "the F-1 reasoning before assuming the delta is unchanged"
        )
        assert pooled_max > default_max, (
            "the pooled provider client inherited a shared connection ceiling"
        )
        assert pooled_max >= sys.maxsize
        assert pooled_keepalive == 20
    finally:
        await reference.aclose()
        await aclose_provider_client()


async def _peak_concurrent_connections(limits, concurrency: int,
                                       delay: float = 0.2) -> int:
    """Drive `concurrency` simultaneous POSTs at a loopback origin and return
    the most connections that were open at the same instant.

    Connections-ever-opened cannot see queueing (a bounded pool still serves
    every request, just later). Peak simultaneous connections can.
    """
    origin = _StubOrigin(delay=delay)
    await origin.start()
    client = httpx.AsyncClient(timeout=_PROVIDER_TIMEOUT_SECONDS, limits=limits)
    try:
        url = f"http://127.0.0.1:{origin.port}/v1/messages"
        responses = await asyncio.gather(
            *(client.post(url, json={"i": i}) for i in range(concurrency))
        )
        assert all(r.status_code == 200 for r in responses)
        return origin.peak
    finally:
        await client.aclose()
        await origin.stop()


@pytest.mark.asyncio
async def test_a_bounded_shared_pool_queues_callers_and_the_shipped_limits_do_not():
    """The F-1 mechanism, measured on both arms of the same experiment.

    A bounded shared pool physically cannot exceed its cap, so its peak
    concurrency pins to the cap: later callers waited. The shipped limits open
    every connection at once, exactly as the per-call shape did.
    """
    concurrency = 12
    cap = 4
    bounded = await _peak_concurrent_connections(
        httpx.Limits(max_connections=cap, max_keepalive_connections=cap),
        concurrency,
    )
    unbounded = await _peak_concurrent_connections(_PROVIDER_LIMITS, concurrency)

    assert bounded <= cap, f"a cap of {cap} allowed {bounded} at once"
    assert bounded < concurrency, (
        "the bounded arm did not queue, so this experiment proves nothing "
        "about the unbounded arm"
    )
    assert unbounded == concurrency, (
        f"the shipped provider limits queued {concurrency - unbounded} of "
        f"{concurrency} concurrent provider calls (peak {unbounded})"
    )
    # Scope of the evidence above, stated rather than implied: it shows the
    # shipped limits do not queue AT THIS concurrency. Opening 100+ sockets in
    # a unit test is not worth the flakiness, so the absence of a ceiling
    # further up is asserted from the declared limit instead of measured.
    assert _PROVIDER_LIMITS.max_connections is None, (
        f"the shipped pool has a finite ceiling; peak-{concurrency} evidence "
        "does not cover it and this test no longer proves what it claims"
    )


@pytest.mark.asyncio
async def test_a_bounded_shared_pool_raises_pooltimeout_that_would_escape_as_5xx():
    """The failure mode a shared ceiling would introduce, demonstrated.

    Not hypothetical: a capped pool under contention really does raise
    `httpx.PoolTimeout`, and it really is not an `HTTPException`, so
    `invoke_single_variant` would NOT convert it into the strict blocked
    envelope -- the user would get a 5xx. The shipped limits never queue, so
    this is unreachable in production; that is the whole point of F-1.
    """
    origin = _StubOrigin(delay=0.5)
    await origin.start()
    client = httpx.AsyncClient(
        limits=httpx.Limits(max_connections=1, max_keepalive_connections=1),
        timeout=httpx.Timeout(connect=5.0, read=5.0, write=5.0, pool=0.05),
    )
    try:
        url = f"http://127.0.0.1:{origin.port}/v1/messages"
        results = await asyncio.gather(
            *(client.post(url, json={"i": i}) for i in range(3)),
            return_exceptions=True,
        )
        pool_timeouts = [r for r in results if isinstance(r, httpx.PoolTimeout)]
        assert pool_timeouts, (
            "a max_connections=1 pool under contention did not raise "
            "PoolTimeout; the F-1 mechanism claim needs re-deriving"
        )
        for exc in pool_timeouts:
            assert not isinstance(exc, HTTPException), (
                "PoolTimeout is an HTTPException after all -- then it WOULD "
                "fail closed and the F-1 escape analysis is wrong"
            )
        # The shipped configuration makes the above unreachable.
        assert _PROVIDER_LIMITS.max_connections is None
    finally:
        await client.aclose()
        await origin.stop()


@pytest.mark.asyncio
@pytest.mark.parametrize("exc_factory", [
    lambda: httpx.ReadTimeout("read timed out"),
    lambda: httpx.ConnectTimeout("connect timed out"),
    lambda: httpx.ConnectError("connection failed"),
    lambda: httpx.PoolTimeout("pool timed out"),
    lambda: httpx.RemoteProtocolError("peer closed connection"),
])
async def test_real_transport_errors_propagate_and_are_not_converted_to_blocked(
    exc_factory, monkeypatch
):
    """The exact boundary of the fail-closed guarantee (F-2).

    `invoke_single_variant` catches `HTTPException` only. A raw httpx
    transport error therefore propagates and surfaces as a 5xx rather than a
    `status="blocked"` envelope.

    This is PRE-EXISTING behaviour, identical on the untouched parent, and it
    is NOT changed here: converting transport errors into blocked envelopes
    would alter what the client sees for a real failure, which is a semantic
    change and out of scope for transport work. The test exists so the
    fail-closed property is never described as broader than it is.
    """
    async def raising(req, model):
        raise exc_factory()

    monkeypatch.setitem(ANALYZE_GLOBALS, "anthropic_single_variant", raising)
    with pytest.raises(httpx.HTTPError) as caught:
        await invoke_single_variant(
            VariantRequest(text="alpha bravo charlie", axis="warmer"),
            "anthropic",
        )
    # The reason it escapes, stated as an assertion rather than a comment.
    assert not isinstance(caught.value, HTTPException)


@pytest.mark.asyncio
async def test_the_fail_closed_boundary_is_httpexception_and_the_two_differ(
    monkeypatch,
):
    """Both sides of the boundary in one place, so the contrast is explicit."""
    async def raise_http_exception(req, model):
        raise HTTPException(502, "Anthropic API error: 529")

    monkeypatch.setitem(ANALYZE_GLOBALS, "anthropic_single_variant",
                        raise_http_exception)
    resp = await invoke_single_variant(
        VariantRequest(text="alpha bravo charlie", axis="warmer"), "anthropic")
    assert resp.status == "blocked"
    assert resp.reason == VariantBlockedReason.PROVIDER_FAILED

    async def raise_transport_error(req, model):
        raise httpx.ReadTimeout("read timed out")

    monkeypatch.setitem(ANALYZE_GLOBALS, "anthropic_single_variant",
                        raise_transport_error)
    with pytest.raises(httpx.ReadTimeout):
        await invoke_single_variant(
            VariantRequest(text="alpha bravo charlie", axis="warmer"),
            "anthropic",
        )
