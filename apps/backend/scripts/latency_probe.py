#!/usr/bin/env python3
"""Content-free four-clock latency probe for the Tono selected-tone path.

WHAT THIS IS
------------
A reproducible, offline measurement harness for the latency of one user tone
tap. It exists so that any latency claim about the Coach path is backed by raw
samples rather than by reading the code and guessing.

HARD PRIVACY RULE
-----------------
Every sample record this harness emits is content-free. A record carries only:

  * ``n``            -- sample index (int)
  * ``axis``         -- one token from the server-side ``VARIANT_ALLOWLIST``
  * ``draft_chars``  -- the LENGTH of the synthetic draft (int)
  * ``ms``           -- a duration (float)

The draft text itself is NEVER written to the sample stream, and the corpus is
synthetic and generated in-process (see ``synthetic_corpus``) -- there is no
production corpus, no user content, and no PII anywhere in this file or its
output. ``scripts/../tests/test_latency_clocks.py`` asserts this mechanically.

THE FOUR CLOCKS
---------------
The mission-relevant clocks for one tone tap are:

  tap -> request_start -> [network] -> server_accept -> preflight_end
      -> provider_start -> provider_end -> response_sent -> [network]
      -> response_receipt -> decode -> render

``tap``, ``request_start``, ``response_receipt`` and ``render`` are captured on
iOS (``KeyboardViewController.runCoach`` / ``completeCoach``, phases
``loading`` / ``request`` / ``response`` / ``render``). This harness measures
the SERVER-side and TRANSPORT-side segments, which are the ones that dominate
and the only ones reproducible without a device:

  MODE ``app``        -- server_accept -> preflight_end -> provider_start
                         -> response_sent, measured end-to-end through the real
                         ASGI app, plus client-side JSON decode of the
                         envelope. The provider is replaced by an in-process
                         stub with a configurable fixed delay so that server
                         overhead is isolated from provider time.

  MODE ``transport``  -- the provider round trip itself, measured against a
                         local stub HTTP/HTTPS origin, comparing the two client
                         constructions:
                           ``per_call`` -- a fresh ``httpx.AsyncClient`` per
                                           provider call (the shape the backend
                                           used before this change), and
                           ``pooled``   -- one reused ``httpx.AsyncClient``.
                         This isolates connection-establishment cost, which is
                         exactly the delta the connection-reuse change removes.

HONEST SCOPE / WHAT THIS DOES NOT MEASURE
-----------------------------------------
This harness makes ZERO calls to any live provider, account, or store. The
``transport`` mode talks to a loopback origin, so its RTT is ~0. Real
``api.anthropic.com`` connection setup additionally costs one TCP round trip
plus one TLS round trip (TLS 1.3 full handshake), which loopback cannot
reproduce. The loopback numbers are therefore a strict LOWER BOUND on the
connection-establishment cost removed by pooling: they capture the CPU cost of
the handshake honestly and the network cost not at all. No number produced here
may be presented as a measured production or user-visible improvement.

USAGE
-----
    python3 scripts/latency_probe.py --mode all --iterations 60
    python3 scripts/latency_probe.py --mode transport --json out.json
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import math
import os
import ssl
import statistics
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable, Optional

# Allow ``python3 scripts/latency_probe.py`` from apps/backend without an
# installed package: put the repo's apps/ dir on the path so ``backend.*``
# resolves the same way the test suite resolves it.
_HERE = os.path.dirname(os.path.abspath(__file__))
_BACKEND = os.path.dirname(_HERE)
_APPS = os.path.dirname(_BACKEND)
if _APPS not in sys.path:
    sys.path.insert(0, _APPS)

import httpx  # noqa: E402


# ---------------------------------------------------------------------------
# Synthetic corpus. Generated, bounded, obviously non-human, no PII.
# ---------------------------------------------------------------------------

# Deterministic filler tokens. Chosen to be meaningless: this is a length
# generator, not a message. Nothing here resembles a real user draft.
_TOKENS = (
    "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
    "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa",
)

# The exact server-side allowlist. Kept as a literal (not imported) so the
# harness can run standalone; ``test_latency_clocks.py`` asserts it matches
# ``analyze.VARIANT_ALLOWLIST`` so the two can never silently drift.
PROBE_AXES = ("warmer", "clearer", "safer", "professional", "concise")

# The pooled arm must measure the client the server actually builds, not a
# default-limits stand-in, or the benchmark stops describing production. These
# mirror ``analyze._PROVIDER_LIMITS`` and are kept as literals for the same
# standalone reason as ``PROBE_AXES``; ``test_latency_clocks.py`` asserts they
# match so the two can never silently drift. (The transport arms drive calls
# sequentially, so the connection cap does not affect these numbers -- matching
# it is about measuring the right object, not about changing the result.)
PROBE_TIMEOUT_SECONDS = 30
PROBE_MAX_CONNECTIONS = None
PROBE_MAX_KEEPALIVE_CONNECTIONS = 20
PROBE_KEEPALIVE_EXPIRY = 5.0


def probe_limits() -> "httpx.Limits":
    """The connection limits the server's pooled provider client uses."""
    return httpx.Limits(
        max_connections=PROBE_MAX_CONNECTIONS,
        max_keepalive_connections=PROBE_MAX_KEEPALIVE_CONNECTIONS,
        keepalive_expiry=PROBE_KEEPALIVE_EXPIRY,
    )

# Bounded corpus: 5 length buckets x 8 samples. The buckets bracket the
# realistic draft-length range without ever approaching ``_DRAFT_MAX_CHARS``.
CORPUS_BUCKETS = (24, 80, 200, 480, 900)
CORPUS_PER_BUCKET = 8


def synthetic_corpus() -> list[str]:
    """Return the bounded synthetic corpus.

    Deterministic, generated in-process, content-free by construction: each
    entry is a repeated cycle of the filler tokens truncated to a target
    length. No user content, no production corpus, no PII.
    """
    corpus: list[str] = []
    for bucket in CORPUS_BUCKETS:
        for i in range(CORPUS_PER_BUCKET):
            words: list[str] = []
            length = 0
            k = i
            while length < bucket:
                token = _TOKENS[k % len(_TOKENS)]
                words.append(token)
                length += len(token) + 1
                k += 1
            corpus.append(" ".join(words)[:bucket])
    return corpus


# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------


def percentile(values: list[float], q: float) -> float:
    """Nearest-rank percentile: the ``ceil(q/100 * N)``-th smallest value.

    ``q`` in [0, 100]. Empty -> 0.0. Deterministic and interpolation-free, so
    every reported number is an actually-observed sample rather than a
    synthesized one.
    """
    if not values:
        return 0.0
    ordered = sorted(values)
    rank = max(1, min(len(ordered), math.ceil(q / 100.0 * len(ordered))))
    return ordered[rank - 1]


def calibrate_host() -> dict[str, Any]:
    """Measure this host's timing noise floor before trusting any number.

    A shared or loaded machine can overshoot ``time.sleep`` by hundreds of
    percent, which silently inflates every absolute latency figure. Reporting
    the overshoot alongside the results is what keeps the numbers honest: a
    run whose ``sleep_10ms_p50_ms`` is far above 10 has a noisy clock, and its
    ABSOLUTE figures should be read as indicative only. Ratios measured
    back-to-back under the same load (per_call vs pooled) stay meaningful, and
    the connection COUNTS are exact regardless of load.
    """
    out: dict[str, Any] = {}
    for target_ms in (1.0, 10.0, 50.0):
        observed: list[float] = []
        for _ in range(10):
            t0 = time.perf_counter()
            time.sleep(target_ms / 1000.0)
            observed.append((time.perf_counter() - t0) * 1000.0)
        out[f"sleep_{int(target_ms)}ms_p50_ms"] = round(percentile(observed, 50), 3)
    try:
        out["loadavg_1m"] = round(os.getloadavg()[0], 2)
    except (OSError, AttributeError):
        out["loadavg_1m"] = None
    out["cpu_count"] = os.cpu_count()
    worst = out.get("sleep_10ms_p50_ms") or 0.0
    out["timer_inflation_x"] = round(worst / 10.0, 2) if worst else None
    out["absolute_numbers_trustworthy"] = bool(worst and worst < 15.0)
    return out


def summarize(name: str, samples: list[dict[str, Any]]) -> dict[str, Any]:
    """Reduce content-free samples to a content-free summary."""
    ms = [float(s["ms"]) for s in samples]
    return {
        "name": name,
        "n": len(ms),
        "p50_ms": round(percentile(ms, 50), 3),
        "p95_ms": round(percentile(ms, 95), 3),
        "min_ms": round(min(ms), 3) if ms else 0.0,
        "max_ms": round(max(ms), 3) if ms else 0.0,
        "mean_ms": round(statistics.fmean(ms), 3) if ms else 0.0,
    }


# ---------------------------------------------------------------------------
# MODE `transport` -- provider round trip: per-call client vs pooled client
# ---------------------------------------------------------------------------


class _StubOrigin:
    """A minimal loopback HTTP/HTTPS origin standing in for the provider.

    Answers every POST with a fixed, tiny JSON body. It exists only so the
    httpx client performs a real connection establishment + request/response
    cycle; it deliberately does NOT emulate provider think-time, because the
    quantity under measurement is connection cost, not model latency.
    """

    def __init__(self, tls: bool = False) -> None:
        self.tls = tls
        self.server: Optional[asyncio.AbstractServer] = None
        self.port = 0
        self.connections = 0

    async def start(self, certfile: Optional[str] = None) -> None:
        ssl_ctx = None
        if self.tls:
            assert certfile is not None
            ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ssl_ctx.load_cert_chain(certfile)
        self.server = await asyncio.start_server(
            self._handle, "127.0.0.1", 0, ssl=ssl_ctx
        )
        self.port = self.server.sockets[0].getsockname()[1]

    async def _handle(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        self.connections += 1
        try:
            while True:
                # Read request head.
                head = await reader.readuntil(b"\r\n\r\n")
                length = 0
                for line in head.split(b"\r\n"):
                    if line.lower().startswith(b"content-length:"):
                        length = int(line.split(b":", 1)[1].strip())
                if length:
                    await reader.readexactly(length)
                body = b'{"content":[{"type":"text","text":"{}"}]}'
                writer.write(
                    b"HTTP/1.1 200 OK\r\n"
                    b"Content-Type: application/json\r\n"
                    b"Content-Length: " + str(len(body)).encode() + b"\r\n"
                    b"Connection: keep-alive\r\n\r\n" + body
                )
                await writer.drain()
        except (asyncio.IncompleteReadError, ConnectionResetError,
                asyncio.CancelledError, ssl.SSLError, OSError):
            pass
        finally:
            try:
                writer.close()
            except Exception:
                pass

    async def stop(self) -> None:
        if self.server is not None:
            self.server.close()
            await self.server.wait_closed()


def _make_selfsigned_cert(directory: str) -> Optional[str]:
    """Generate a throwaway self-signed cert with the system openssl.

    Local key generation only -- no network, no dependency download. Returns
    the combined PEM path, or ``None`` if openssl is unavailable (the TLS
    sub-benchmark is then skipped and reported as skipped, never faked).
    """
    pem = os.path.join(directory, "probe.pem")
    try:
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-keyout", pem, "-out", pem, "-days", "1",
             "-subj", "/CN=127.0.0.1"],
            check=True, capture_output=True, timeout=60,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    # openssl writes key then cert to the same path with -keyout == -out only
    # on some builds; verify the file has both blocks, else give up honestly.
    try:
        with open(pem, "r", encoding="utf-8") as fh:
            blob = fh.read()
    except OSError:
        return None
    if "PRIVATE KEY" not in blob or "CERTIFICATE" not in blob:
        return None
    return pem


async def _drive_transport(
    url: str, iterations: int, pooled: bool, verify: Any
) -> list[dict[str, Any]]:
    """Measure one provider POST, either pooled or with a per-call client."""
    body = {"model": "stub", "max_tokens": 400, "messages": [{"role": "user",
            "content": "x" * 200}]}
    samples: list[dict[str, Any]] = []
    shared: Optional[httpx.AsyncClient] = None
    if pooled:
        # The production shape: one reused client with the server's limits.
        shared = httpx.AsyncClient(timeout=PROBE_TIMEOUT_SECONDS,
                                   limits=probe_limits(), verify=verify)
    try:
        for i in range(iterations):
            t0 = time.perf_counter()
            if pooled:
                assert shared is not None
                r = await shared.post(url, json=body)
                r.raise_for_status()
            else:
                # Exactly the pre-change shape: a fresh client per call.
                async with httpx.AsyncClient(timeout=PROBE_TIMEOUT_SECONDS,
                                             verify=verify) as c:
                    r = await c.post(url, json=body)
                    r.raise_for_status()
            samples.append({
                "n": i,
                "axis": "n/a",
                "draft_chars": 200,
                "ms": (time.perf_counter() - t0) * 1000.0,
            })
    finally:
        if shared is not None:
            await shared.aclose()
    return samples


async def _drive_fanout(
    url: str, iterations: int, pooled: bool, verify: Any, optionals: int
) -> list[dict[str, Any]]:
    """Measure the build-94 dispatch shape: 1 serialized Safer call, then
    ``optionals`` concurrent optional calls. Measures the whole wave so the
    pooled/per-call delta is expressed in the shape the server actually uses.
    """
    body = {"model": "stub", "max_tokens": 800, "messages": [{"role": "user",
            "content": "x" * 200}]}
    samples: list[dict[str, Any]] = []
    shared: Optional[httpx.AsyncClient] = None
    if pooled:
        # The production shape: one reused client with the server's limits.
        shared = httpx.AsyncClient(timeout=PROBE_TIMEOUT_SECONDS,
                                   limits=probe_limits(), verify=verify)

    async def one() -> None:
        if pooled:
            assert shared is not None
            r = await shared.post(url, json=body)
            r.raise_for_status()
        else:
            async with httpx.AsyncClient(timeout=PROBE_TIMEOUT_SECONDS,
                                         verify=verify) as c:
                r = await c.post(url, json=body)
                r.raise_for_status()

    try:
        for i in range(iterations):
            t0 = time.perf_counter()
            await one()  # Safer gate: strictly serialized first.
            await asyncio.gather(*(one() for _ in range(optionals)))
            samples.append({
                "n": i,
                "axis": "n/a",
                "draft_chars": 200,
                "ms": (time.perf_counter() - t0) * 1000.0,
            })
    finally:
        if shared is not None:
            await shared.aclose()
    return samples


async def run_transport(iterations: int) -> dict[str, Any]:
    """Run the connection-reuse benchmark over loopback HTTP and HTTPS."""
    out: dict[str, Any] = {"summaries": [], "raw": {}, "notes": []}

    async def bench(tag: str, tls: bool, certfile: Optional[str]) -> None:
        origin = _StubOrigin(tls=tls)
        await origin.start(certfile)
        scheme = "https" if tls else "http"
        url = f"{scheme}://127.0.0.1:{origin.port}/v1/messages"
        verify: Any = False if tls else True
        try:
            # Warm the path once so the first-sample import/JIT cost of either
            # arm does not land inside the measured window.
            await _drive_transport(url, 2, pooled=True, verify=verify)
            await _drive_transport(url, 2, pooled=False, verify=verify)

            origin.connections = 0
            per_call = await _drive_transport(url, iterations, False, verify)
            conns_per_call = origin.connections

            origin.connections = 0
            pooled = await _drive_transport(url, iterations, True, verify)
            conns_pooled = origin.connections

            origin.connections = 0
            fan_per_call = await _drive_fanout(url, max(8, iterations // 4),
                                               False, verify, optionals=3)
            fan_conns_per_call = origin.connections

            origin.connections = 0
            fan_pooled = await _drive_fanout(url, max(8, iterations // 4),
                                             True, verify, optionals=3)
            fan_conns_pooled = origin.connections
        finally:
            await origin.stop()

        for name, samples in (
            (f"{tag}.single.per_call", per_call),
            (f"{tag}.single.pooled", pooled),
            (f"{tag}.fanout_1plus3.per_call", fan_per_call),
            (f"{tag}.fanout_1plus3.pooled", fan_pooled),
        ):
            out["summaries"].append(summarize(name, samples))
            out["raw"][name] = samples
        out["notes"].append({
            "transport": tag,
            "tcp_connections_single_per_call": conns_per_call,
            "tcp_connections_single_pooled": conns_pooled,
            "tcp_connections_fanout_per_call": fan_conns_per_call,
            "tcp_connections_fanout_pooled": fan_conns_pooled,
        })

    await bench("http", tls=False, certfile=None)

    with tempfile.TemporaryDirectory() as td:
        pem = _make_selfsigned_cert(td)
        if pem is None:
            out["notes"].append({"transport": "https", "skipped":
                                 "openssl unavailable; TLS arm not measured"})
        else:
            await bench("https", tls=True, certfile=pem)

    return out


# ---------------------------------------------------------------------------
# MODE `app` -- end-to-end selected-variant path through the real ASGI app
# ---------------------------------------------------------------------------


def run_app(iterations: int, provider_delay_ms: float) -> dict[str, Any]:
    """Drive ``POST /api/analyze/variant`` through the real FastAPI app.

    The provider is replaced with an in-process stub that sleeps a fixed
    ``provider_delay_ms``. That makes provider time a known constant so the
    remaining time is unambiguously server overhead: routing, auth, the
    entitlement gate, the deterministic safety preflight, model routing,
    post-validation, envelope serialization -- plus the client-side decode.
    """
    os.environ["TONO_PROVIDER"] = "mock"
    os.environ.setdefault("FREE_DAILY_LIMIT", "100000")
    # Raise ONLY this throwaway probe process's own per-IP budget so the
    # sample size is statistically meaningful. The limiter still runs on every
    # measured request (so its cost IS in the numbers) and the shipped default
    # (``IP_RATE_LIMIT_PER_MIN`` = 20) is untouched -- this is an env var read
    # by the in-process app, not a code change.
    os.environ["IP_RATE_LIMIT_PER_MIN"] = "1000000"
    tmpdir = tempfile.mkdtemp(prefix="tono-latency-")
    os.environ["TONO_DB_PATH"] = os.path.join(tmpdir, "probe.db")

    # The probe is a measurement tool: server INFO logging would otherwise
    # dominate the wall clock it is trying to measure.
    logging.disable(logging.INFO)

    for name in list(sys.modules):
        if name in ("backend", "Backend") or name.startswith(("backend.", "Backend.")):
            del sys.modules[name]

    from fastapi.testclient import TestClient  # noqa: E402

    from backend import analyze as analyze_mod  # noqa: E402
    from backend.server import app  # noqa: E402

    # Give the in-process mock provider a known, fixed think-time so the
    # remaining wall time is unambiguously server overhead. ``_provider_call``
    # in ``invoke_single_variant`` resolves ``mock_single_variant`` from the
    # module globals at call time, so patching the global is enough. The probe
    # drives requests serially, so a blocking sleep measures accurately.
    delay_s = provider_delay_ms / 1000.0
    real_mock = analyze_mod.mock_single_variant
    if delay_s:
        def _delayed_mock(req: Any) -> dict[str, Any]:
            time.sleep(delay_s)
            return real_mock(req)
        analyze_mod.mock_single_variant = _delayed_mock

    corpus = synthetic_corpus()
    samples_e2e: list[dict[str, Any]] = []
    samples_decode: list[dict[str, Any]] = []
    server_clocks: list[dict[str, Any]] = []

    with TestClient(app) as client:
        r = client.post("/v1/register",
                        json={"platform": "ios", "app_version": "0.0.0-probe"})
        r.raise_for_status()
        reg = r.json()
        _grant_probe_entitlement(reg)
        headers = {"Authorization": f"Bearer {reg['api_token']}"}

        # Warm: first request pays import/route-build cost that is not part of
        # steady-state latency.
        client.post("/api/analyze/variant", headers=headers,
                    json={"text": corpus[0], "axis": "warmer"})

        n = 0
        for i in range(iterations):
            draft = corpus[i % len(corpus)]
            axis = PROBE_AXES[i % len(PROBE_AXES)]
            t0 = time.perf_counter()
            r = client.post("/api/analyze/variant", headers=headers,
                            json={"text": draft, "axis": axis})
            t_recv = time.perf_counter()
            if r.status_code != 200:
                continue
            payload = json.loads(r.content)
            t_decoded = time.perf_counter()
            if payload.get("status") != "ok":
                continue
            samples_e2e.append({"n": n, "axis": axis,
                                "draft_chars": len(draft),
                                "ms": (t_recv - t0) * 1000.0})
            samples_decode.append({"n": n, "axis": axis,
                                   "draft_chars": len(draft),
                                   "ms": (t_decoded - t_recv) * 1000.0})
            clocks = payload.get("clocks")
            if isinstance(clocks, dict):
                server_clocks.append({
                    "n": n, "axis": axis, "draft_chars": len(draft),
                    "preflight_ms": clocks.get("preflight_ms"),
                    "provider_ms": clocks.get("provider_ms"),
                    "server_total_ms": clocks.get("response_sent_ms"),
                })
            n += 1

    out: dict[str, Any] = {
        "summaries": [
            summarize("app.e2e_request", samples_e2e),
            summarize("app.client_decode", samples_decode),
        ],
        "raw": {
            "app.e2e_request": samples_e2e,
            "app.client_decode": samples_decode,
        },
        "notes": [{
            "provider_delay_ms": provider_delay_ms,
            "clocks_emitted": len(server_clocks),
            "corpus_size": len(corpus),
        }],
    }
    if server_clocks:
        for field in ("preflight_ms", "provider_ms", "server_total_ms"):
            vals = [s for s in server_clocks if isinstance(s.get(field), int)]
            out["summaries"].append(summarize(
                f"app.server_clock.{field}",
                [{"ms": float(s[field]), "n": s["n"], "axis": s["axis"],
                  "draft_chars": s["draft_chars"]} for s in vals],
            ))
        out["raw"]["app.server_clocks"] = server_clocks
    return out


def _grant_probe_entitlement(reg: dict[str, Any]) -> None:
    """Give the throwaway probe device a rewrite entitlement.

    Identical to the test suite's ``_register_authed`` helper: a local
    ``update_subscription`` row in a throwaway SQLite file under a temp dir.
    No live account, no store/billing provider is contacted, and no payment
    truth is altered -- the row exists only so the server-authoritative
    entitlement gate lets the probe reach the measured path.
    """
    from backend.store import get_store

    get_store().update_subscription(
        device_id=reg["device_id"],
        customer_id=None,
        subscription_id=f"sub_probe_{reg['device_id']}",
        status="active",
        renews_at=None,
    )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _print_table(title: str, summaries: list[dict[str, Any]]) -> None:
    print(f"\n=== {title} ===")
    print(f"{'metric':<38} {'n':>5} {'p50_ms':>10} {'p95_ms':>10} {'min':>9} {'max':>9}")
    for s in summaries:
        print(f"{s['name']:<38} {s['n']:>5} {s['p50_ms']:>10.3f} "
              f"{s['p95_ms']:>10.3f} {s['min_ms']:>9.3f} {s['max_ms']:>9.3f}")


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--mode", choices=("transport", "app", "all"), default="all")
    ap.add_argument("--iterations", type=int, default=60)
    ap.add_argument("--provider-delay-ms", type=float, default=0.0)
    ap.add_argument("--json", type=str, default=None,
                    help="write the full content-free sample stream here")
    args = ap.parse_args(argv)

    calibration = calibrate_host()
    result: dict[str, Any] = {
        "summaries": [], "raw": {}, "notes": [], "calibration": calibration,
    }
    print("=== host calibration (timing noise floor) ===")
    for key, value in calibration.items():
        print(f"  {key}: {value}")
    if not calibration.get("absolute_numbers_trustworthy"):
        print("  WARNING: this host's timer is inflated under load. Treat "
              "ABSOLUTE p50/p95 as indicative only; the per_call-vs-pooled "
              "RATIO and the connection COUNTS remain valid.")

    if args.mode in ("transport", "all"):
        t = asyncio.run(run_transport(args.iterations))
        result["summaries"] += t["summaries"]
        result["raw"].update(t["raw"])
        result["notes"] += t["notes"]
        _print_table("transport: connection reuse", t["summaries"])
        for note in t["notes"]:
            print(f"  note: {note}")

    if args.mode in ("app", "all"):
        a = run_app(args.iterations, args.provider_delay_ms)
        result["summaries"] += a["summaries"]
        result["raw"].update(a["raw"])
        result["notes"] += a["notes"]
        _print_table("app: selected-variant end-to-end", a["summaries"])
        for note in a["notes"]:
            print(f"  note: {note}")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(result, fh, indent=2, sort_keys=True)
        print(f"\nwrote content-free samples -> {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
