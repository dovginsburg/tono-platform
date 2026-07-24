# Claude Receipt — Apple-Fidelity Keyboard Scope (build 96 worktree)

**Agent:** Claude (Opus 4.8), sole implementation writer for this sealed build96 worktree.
**Sole parent commit:** `27432583d56c9b3c11a2c89e11ae594ae0f6e804`
**Build number:** unchanged — all four shipped bundles remain `CFBundleVersion = 96`
(the `Verify Build Number` phase printed `build-number: all shipped bundles are build 96`).

## What shipped

Production UIKit Apple-fidelity keyboard logic modules, fully integrated into the
Xcode project (`Tono.xcodeproj`) and compiled by both the shipping `TonoKeyboard`
app-extension target and the `TonoTests` unit-test target:

| Source (`KeyboardExtension/AppleFidelity/`) | Scope |
| --- | --- |
| `TonoKeyboardGeometry.swift` | Width-bucketed key metrics, three-layer navigation graph, canonical key rows, globe action |
| `BackspaceRepeatEngine.swift` | Pure-value backspace repeat state machine (idle → wait → repeat, with acceleration ramp) |
| `EmojiKeyboard.swift` | Categorized emoji catalog, Fitzpatrick skin-tone insertion, ZWJ family assembly, bounded recents ring |

### Integration edits
- `Tono.xcodeproj/project.pbxproj`: added file references, an `AppleFidelity`
  group under `KeyboardExtension`, and build-file entries wiring the three
  sources into the `TonoKeyboard` **and** `TonoTests` Sources phases, plus the
  four new test files into `TonoTests`.

### Source corrections made to make the modules production-true
- `TonoGlobeAction`: dropped an unsatisfiable `Equatable` conformance (it wraps
  two closures, which Swift cannot compare) — this was a hard compile error.
- `EmojiKeyboard.memoryBudgetBytes`: the documented "under 8 KB" ceiling was
  false — the full Unicode 15.1 catalog measures **22,486 bytes assembled**. The
  ceiling and comments were corrected to a truthful **32 KB** so the enforced
  footprint test is meaningful and passes.

## Tests (executable, `Tests/Build97*.swift`)
Covering the required scopes geometry / state / rapid input / latency / emoji /
symbol / accessibility:

- `Build97KeyboardGeometryTests` (9) — height buckets, letter-key tiling, half-keycap
  row-2 centering, row-3 gap floor, 44 pt touch minimums, and a cross-check that the
  new metrics mirror the shipping `TonoKeyboardMetrics.portrait(_:)`.
- `Build97BackspaceStateTests` (11) — state transitions, steady cadence, latency
  catch-up bounds, rapid press/release cycles, acceleration ramp, long-hold clamp.
- `Build97LayerNavigationTests` (12) — the full three-layer navigation graph and the
  exact letter / number / symbol / punctuation row contents.
- `Build97EmojiTests` (11) — ten category tabs, skin-tone application vs. non-toneable
  glyphs, ZWJ families, bounded LRU recents, and the footprint budget.

## Verification results
- Focused new suites: **43 passed, 0 failures**.
- Full `TonoTests`: **210 passed, 0 failures** — every pre-existing contract
  (BuildNumberGuard, Coach, Live Tone, tone chips, control geometry, privacy)
  preserved.
- Release compile: `xcodebuild -configuration Release` → **BUILD SUCCEEDED**.

Simulator: iPhone 16, iOS 26.5.
