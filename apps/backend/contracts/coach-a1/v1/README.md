# Tono Coach A1 prompt contract v1

Status: Stage-1 candidate. This directory freezes the exact provider prompts, user templates, schemas, and generation settings required to benchmark the adjudicated A1 architecture. It does not authorize or implement `/v2/rewrite`, `/v2/axes`, streaming, charging, or client protocol changes.

## Bound contract

- R1 is one atomic primary rewrite from one provider call, capped at 120 output tokens. The provider output is validated as one complete string before any server response can commit or render.
- R2 starts only after R1 commit. It uses one independent provider call per canonical axis in order: `warmer`, `clearer`, `funnier`, `safer`, capped at 150 output tokens per axis. Each complete result is validated independently; a failed axis is omitted and never stubbed.
- Both stages return compact JSON only. No NDJSON, SSE, chunked progress, partial rendering, partial salvage, heuristic rewrite fallback, or unvalidated text exposure is permitted.
- Input is refused above 1,200 normalized characters rather than truncated.
- The prompts preserve the existing production safety/intent rules: one sentence, exactly one changed axis, recognizable voice, no invented facts/scenarios/apologies/deadlines/recipients/commitments, humor only for a playful source, and no tool narration or analysis dump.

## Stage-1 benchmark binding

The benchmark must hash the complete contents of this directory and must render `r1-user.txt` by replacing `{{draft}}` with each fixture. It must not reuse the old four-axis `SYSTEM_PROMPT` or the old `GENERATE REWRITES FOR AXES` user line. Fixed R1 settings are in `manifest.json`: temperature 0.4, max tokens 120, input cap 1,200 characters, and the pinned provider/model selected by the benchmark receipt.

A provider response counts as successful only if it ends normally, parses as a single JSON object, matches `r1-provider-output.schema.json`, and passes the existing deterministic whole-string semantic/safety validator. `max_tokens`, malformed JSON, schema failure, semantic failure, or safety failure are typed non-successes. Responses and prompts remain memory-only and are never written to benchmark telemetry.

Stage-1 GO/NO-GO remains exactly the adjudicated gate: provider terminal p95 <=1.5 s in at least 2/3 windows; provider-tier NO-GO if p95 >1.8 s in at least two windows. No protocol implementation may be accepted before that gate and the later quality/safety/cost gates pass.

## Files

- `r1-system.txt`: exact R1 system prompt.
- `r1-user.txt`: exact R1 user template.
- `r1-provider-output.schema.json`: strict provider output shape for the primary rewrite.
- `r2-axis-system.txt`: exact single-axis R2 system prompt.
- `r2-axis-user.txt`: exact single-axis R2 user template.
- `r2-axis-provider-output.schema.json`: strict provider output shape for each independently generated axis.
- `manifest.json`: generation limits, ordering, fail-closed semantics, and benchmark gates.
- `SHA256SUMS`: immutable artifact hashes; regenerate only when intentionally minting a new contract version.

Public HTTP response wrappers (`request_id`, safety attestation, one-unit charge receipt, and up-to-four R2 results) remain governed by the architecture adjudication and are intentionally not invented here before Stage 1 passes.
