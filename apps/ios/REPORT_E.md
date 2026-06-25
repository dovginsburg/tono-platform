# Section E — Report Back

Status as of branch `claude/ios-app-capabilities-42z5ig`.

---

## E1 — Extension memory footprint ⏳ needs device

**Design choices that keep the hot path lean:**

- `TonoAnalytics` is a fire-and-forget `URLSession` call with zero startup cost — no SDK init in the extension.
- MetricKit registers in the **host app only**. Extension OOM events surface via `MXAppExitMetric` grouped with the host process, so the extension carries no MetricKit weight.
- `CrashReporter.swift` compiles to nothing today. The risk is Crashlytics binary size after Firebase is added.

**Budget gate (already documented in `CrashReporter.swift:24-29`):** after adding Firebase, check the extension binary-size delta in Xcode (Product → Archive → Distribute, or compare `.app` sizes). If the extension grows by more than ~300 KB, omit `-DFIREBASE_ENABLED` from the **extension** target's Other Swift Flags and keep it only in the host app. MetricKit covers extension OOM regardless.

**Measurement procedure:**
1. Run the keyboard extension inside Messages (or any host app) on a physical device.
2. Open Instruments → Allocations (or Memory Debugger in Xcode).
3. Tap Coach, let it complete, tap Back.
4. Record the **persistent** (post-release) footprint — not the peak.
5. iOS jetsams keyboard extensions around 48–60 MB. Target: ≤30 MB steady-state.

---

## E2 — No message content in telemetry ✅ closed

Exactly three channels leave the device. All are audited below.

### Channel 1: Analytics → `/v1/events` (`TonoAnalytics.swift`)

The `AnalyticsEvent` enum is the only way to call `track()`. Every case carries only:

| Case | Payload fields |
|---|---|
| `coachRequested(mode:)` | `mode` — literal string `"coach"` or `"read"` |
| `analysisShown(riskLevel:latencyMs:source:)` | `riskLevel` — enum rawValue; `latencyMs` — Int; `source` — literal `"mock"` or `"llm"` |
| `rewriteInserted(selectedAxis:shownAxes:)` | axis rawValues (`"warmer"` etc.) |
| `rewriteEditedAfterInsert` | no extra fields |
| `axisRejected(shownAxes:pickedAxis:)` | axis rawValues |

There is no enum case that accepts draft text, rewrite text, or a recipient name. The type system enforces this — you cannot attach message content without adding a new enum case and properties, which would be caught in code review.

### Channel 2: MetricKit → `/v1/metrics` (`MetricKitReporter.swift`)

Payload is exclusively `Double`/`Int` counters from `MXMetricPayload` and `MXDiagnosticPayload`:
- `avg_memory_mb`, `fg_oom`, `bg_oom`, `bg_watchdog`, `fg_normal`, `bg_normal`
- `crash_count`, `hang_count`, `disk_write_exception_count`

Crash diagnostics capture **counts only** — no stack symbolics, no crash logs, no user text (`MetricKitReporter.swift:59-68`).

### Channel 3: Crashlytics custom keys (`CrashReporter.swift`)

All 23 call sites in `KeyboardRootView.swift` pass only:

| Key | Value type | Example values |
|---|---|---|
| `keyboard_mode` | string literal | `"loading"`, `"results_mock"`, `"results_real"` |
| `network_in_flight` | Bool | `true` / `false` |
| `memory_facts_loaded` | Bool | `hintsEnabled` — the flag state, not the content |
| Breadcrumbs | string literal | `"Coach tapped"`, `"Rewrite inserted: warmer"` |

The breadcrumb for insert carries only the axis name (`suggestion.axis.rawValue`), never `suggestion.text`.

### Server-side enforcement (fail-closed)

`EventRequest` and `MetricsRequest` set `model_config = ConfigDict(extra="forbid")`. Any field outside the declared schema — `message_text`, `rewrite_text`, `recipient`, `draft`, or anything else — is **rejected with HTTP 422**. The privacy contract fails loud and testably rather than relying on silent Pydantic drop behavior.

**Test coverage:** `test_analytics_event_rejects_message_content` sends each of `message_text`, `rewrite_text`, `recipient`, `draft` as extra fields and asserts 422. `test_metrics_rejects_unknown_fields` does the same for the metrics endpoint. Both pass in the 41-test suite.

---

## E3 — Measured tap→badge / tap→rewrites latency ⏳ needs device

The instrumentation to produce these numbers is already live in the field. Once on TestFlight:

- `analysis_shown` with `source: "mock"` = **tap→badge** latency (the instant preview; should be sub-100 ms)
- `analysis_shown` with `source: "llm"` = **tap→real-rewrites** latency (network round trip; target p50 ≤800 ms on LTE)

The backend logs both as `latency_ms` in `server.py:536`. Querying the logs for the two `source` values gives the real p50/p95 without any additional instrumentation.

**If you want a pre-TestFlight number:** run Charles Proxy on the device, tap Coach, check the time from request to response on `/api/analyze`. The latency mask means the badge always appears instantly — only the real rewrites replace it once the LLM responds.

---

## E4 — All 5 signals captured ✅ closed

All five C4 signals are wired in `KeyboardRootView.swift`:

| Signal | Location | Notes |
|---|---|---|
| `coach_requested(mode)` | `runCoach()` L99, `runRead()` L217 | Fires immediately on tap, before any network call |
| `analysis_shown(risk, latency, source: "mock")` | `runCoach()` L131 | Fires when mock preview appears (sub-second) |
| `analysis_shown(risk, latency, source: "llm")` | `runCoach()` L177 | Fires when real LLM result arrives |
| `rewrite_inserted(selected_axis, shown_axes)` | `insertRewrite()` L278 | Fires on chip tap |
| `rewrite_edited_after_insert` ⭐ | `loadDraft()` L79 | Diff of draft vs `lastInsertedRewrite` on next focus |
| `axis_rejected(shown_axes, picked_axis)` | `insertRewrite()` L282 | Derived from non-picked axes |

The highest-value training signal — user edited the rewrite after inserting it — is captured by comparing `proxy.documentContextBeforeInput` on the next `loadDraft()` call against the `lastInsertedRewrite` stored at insert time.

**Persistent learning hooks also fire on insert** (independent of analytics):
- `StyleMemory.recordTap(axis:recipientId:)` — per-recipient axis preference weights
- `UserMemory.recordSession(flags:chosenAxis:)` — session-level pattern accumulation

---

## Remaining before TestFlight

- Replace `XXXXXXXXXX` Team ID placeholder in `SharedKeychain.swift:16`
- Add Firebase SPM package + `Google-Services.plist` per `CrashReporter.swift:1-29` (optional — works without it)
- Register StoreKit product IDs `com.tono.pro.monthly` and `com.tono.pro.yearly` in App Store Connect
- Deploy backend to Railway (`railway.toml` and `Dockerfile` already present)
- One Instruments run for E1, one TestFlight build for E3
