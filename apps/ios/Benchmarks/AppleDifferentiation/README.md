# Apple-Differentiation Benchmark Lane (`opus48/apple-differentiation`)

A deterministic, checked-in evaluation + product-contract package that pins the
one job Tono can win at against Apple Writing Tools, and gates the source so it
cannot quietly decay into a generic rewrite tool.

This lane **does not** implement the Live classifier, settings, or UI (other
lanes own those). It builds the corpus, the executable contract gate, and the
blind-rating scorecard, and reports the truth of what is wired today.

## Why this lane exists

Apple Writing Tools already gives every supported device free, systemwide
proofreading, summarization, and rewriting into Friendly / Professional /
Concise plus custom described changes. Tono cannot win on generic rewriting, OS
distribution, or first-party privacy.

Tono's binding differentiated job:

> **Catch grammatically correct messages that are socially wrong before send,
> explain how they may land, and offer meaningfully distinct alternatives with
> measurable interpersonal-risk reduction.**

Every risky case in the corpus is grammatically clean on purpose — that is the
exact blind spot of a proofreader/rewriter. A rewrite-only product scores 0%
detection on this corpus by construction.

## How to run

```sh
cd apps/ios/Benchmarks/AppleDifferentiation
./run.sh            # product-contract gate + offline corpus measurement
./run.sh --emit     # also regenerate report/ artifacts (deterministic)
```

No Xcode, no simulator, no network. `run.sh` compiles the harness together with
the **real** shipping sources (`Shared/*` engine + `KeyboardExtension/TonoCoachClient.swift`)
via `swiftc`, so the contract gate runs against production types, not a
re-implementation. Exit code is the contract gate: non-zero if any contract
fails.

## Current product truth — wired vs dormant

Labeled from source at base SHA `25b82c9` (`FeatureFlags.swift`, `ToneEngine.swift`,
`MockToneAnalyzer.swift`, `TonoBackend.swift`, `NotificationManager.swift`).

| Capability | Status | Evidence |
|---|---|---|
| Manual Coach (tap → risk + 4 rewrites) | **Wired** | `ToneEngine.analyze`, `MockToneAnalyzer.analyzeCoach`, keyboard/share/iMessage entry points |
| Risk + perception + subtext + reason diagnosis schema | **Wired** | `ToneAnalysis` fields; decoded by `ToneEngine.decode` and `TonoCoachClient.decode` |
| Four distinct axes (warmer/clearer/funnier/safer) | **Wired** | `RewriteAxis` + `canonicalCoachChoices` / `canonicalSuggestions` fail-closed |
| Read mode (diagnose a received message) | **Wired** | `AnalysisMode.read`, `MockToneAnalyzer.analyzeReceived` |
| Risk-after per rewrite (risk-reduction field) | **Schema wired, model-dependent** | `RewriteSuggestion.riskAfter`; populated only if backend returns it |
| Thread context / global style memory context hints | **Wired (flag default ON)** | `FeatureFlag.threadContext`, `.memoryContextHints`, `.memoryInference` |
| **Live Tone proactive pre-send classifier** | **Dormant / roadmap** | No live classifier in source; `NotificationManager` "nudge" is only a re-engagement reminder |
| **Per-recipient memory** | **Dormant (flag default OFF)** | `FeatureFlag.recipientMemory.defaultValue == false`; plumbing (`recipientHint`) exists, capability not surfaced |
| Widget / Siri / email sign-in / Slack | **Dormant (flag default OFF)** | `FeatureFlag` defaults |
| Offline analyzer quality | **Wired but weak** | `MockToneAnalyzer` is a small keyword heuristic; see scorecard recall |

## What is machine-scored vs human-rated

The differentiated outcome is a **quality** claim, so the package splits cleanly:

- **Machine-scored (in `report/scorecard.md`)** against the shipping offline
  `MockToneAnalyzer`: detection recall, benign false-positive rate, specificity,
  precision, risk-severity match, rewrite-distinctness proxy. These prove the
  gate runs end-to-end and establish the floor.
- **Blind human-rated (in `report/blind_rating_worksheet.csv`)**: explanation
  usefulness, rewrite diversity, intent preservation, and measurable risk
  reduction. These require judgment and the **wired LLM backend**, which this
  lane deliberately does not call. Labels are held out in `report/answer_key.csv`
  so rating is blind.

No Apple API is called and no Apple output is synthesized; Apple capability
facts are the baseline only.

### Reading the current numbers

The offline `MockToneAnalyzer` catches only a few overt patterns, so its
detection recall on this corpus is low **by design** — that is the honest gap
integration must close with the wired LLM backend. The contract gate (9/9)
proves the schema can express the differentiated outcome; it does **not** claim
Tono beats Apple. Superiority may be asserted only once the blind worksheet,
run against the wired backend, demonstrates the differentiated outcome.

## Artifact-verified positioning line

Proposed, and directly supported by the shipping schema (`ToneAnalysis` carries
risk + perception + subtext + reason + four distinct axes + risk-after) — not by
any capability Apple ships:

> **"Your grammar was already fine. Tono tells you how it'll land — and gives you
> four ways to fix the feeling, not the spelling."**

This is defensible because it claims exactly what the code supports (social-risk
diagnosis of grammatical text) and nothing Apple already does for free.

## Prohibited / unsupported claims found (report only — no copy edited here)

Per lane boundaries this package does **not** edit marketing or release copy. It
flags claims that current source does not yet back:

1. **`AppStore/description.txt`** — "Recipient memory with voice hints … rewrites
   adapt to who you're talking to." `FeatureFlag.recipientMemory` is default OFF;
   not surfaced. Do not present per-recipient adaptation as a live feature until wired.
2. **`AppStore/description.txt`** — "Widget to track usage" and "Siri Shortcuts
   support." `widgetEnabled` / `siriEnabled` are default OFF. Unsupported as shipped.
3. **`AppStore/description.txt`** — "an iOS keyboard that reads your message before
   you send it." Reads on **manual** tap-Coach; there is no proactive/Live
   classifier in source. Copy must not imply automatic pre-send detection until
   Live Tone is wired.
4. **General** — any "remembers your recipient / learns the relationship" Live
   claim: unsupported until `recipientMemory` ships. Contract **C9** guards the
   default so this cannot silently become false-by-default.

(Out of lane, noted for the owning lane: `description.txt` prices `$2.99/$28.99`
while `Tono.storekit` / `CLAUDE.md` use `$5.99/$39.99`. Not touched here.)

## Gaps integration must close

1. **Detection engine**: wire the LLM backend into this same harness (swap the
   `analyze` closure in `Scorecard.score`) and re-measure recall/precision on the
   corpus. Offline Mock is a floor, not the product.
2. **Risk-after**: ensure the backend actually returns `risk_after` per axis so
   the risk-reduction metric is populated, not just schema-possible.
3. **Live Tone**: build the proactive pre-send classifier the positioning
   depends on; until then, keep Live claims out of copy (see C9).
4. **Blind rating pass**: run the worksheet against the wired backend with human
   raters before any comparative ("beats Apple") claim.

## Files

```
corpus/social_risk_corpus.json   Human-reviewable adversarial corpus (synthetic, no PII)
Sources/BenchmarkCorpus.swift    Corpus model + loader + severity ranking
Sources/ProductContract.swift    C1–C9 executable contract gate (real shipping types)
Sources/Scorecard.swift          Deterministic scorecard + blind worksheet + answer key
Sources/main.swift               Runner / gate entry point
run.sh                           Compile against real sources and run
report/scorecard.md              Generated scorecard (deterministic)
report/blind_rating_worksheet.csv Generated blind worksheet (labels withheld)
report/answer_key.csv            Generated held-out labels
```
