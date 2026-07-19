# tonoit release-control — successor-v3

An **isolated, default-off, source-only, stdlib-only** release-gating library.
It is deliberately **not wired** into any runtime, schema, telemetry sink,
provider, billing, account, DNS, credential store, native app, or build. It is
reference/adoption material only: importing it and calling it performs **no I/O
and no network access**.

## What it does

Given a `ReleaseConfig`, a flag name, and an `EvaluationContext`, it decides
whether that flag is *released* — always **failing closed**:

- Unknown flags are **off by default**.
- Gates are applied in strict precedence:
  **kill → readiness → authority → build → schema → TTL → allowlist → cohort.**
- TTL is strictly finite: only a finite, in-range, future expiry passes;
  zero/negative/expired/non-finite/bool/huge/wrong-typed values fail closed.
- Cohort assignment is a **deterministic 0..100** rollout, stable across
  processes (SHA-256 based), with an allowlist override.

## What it never does

- **Never grants entitlements or authority.** Authority is only an input gate
  that a context must already satisfy; passing it grants nothing.
  `release_grants_entitlements()` is a hard `False`.
- **Never disables protected capabilities.** `safety`, `help`, `export`,
  `delete`, and `recovery` are always available, regardless of config, context,
  or kill switches.
- **Never mutates** a model after construction. All models are immutable
  tuple-backed records with no `_set`/`_replace`/`update` backdoor; direct
  assignment, `object.__setattr__`, item assignment, and descriptor bypass all
  fail closed.
- **Never trusts hostile inputs.** Hostile-keyed dicts (raising/colliding/
  changing `__hash__`/`__eq__`) never make constructors raise and can never
  enable a flag; validators fail closed without probing, rehashing, or
  executing caller keys. Constructors and validators are total for ordinary
  `Exception`-derived hostility while letting process-control `BaseException`
  (KeyboardInterrupt/SystemExit) propagate.
- **Never echoes caller data.** Telemetry and serialized output are freshly
  built, finite, scalar-only, and contain no caller keys/strings/ids/objects/
  nesting/reasons.

## Layout

```
src/tonoit_release_control/   # the importable package (stdlib-only)
  _reasons.py                 # fixed int reason/gate codes + bounds
  _normalize.py               # fail-closed normalization of untrusted input
  _models.py                  # immutable tuple-backed records
  _evaluate.py                # gates, deterministic cohort, capabilities
  _validate.py                # total, fail-closed public validators
  _telemetry.py               # scalar-only telemetry/serialization/receipts
  _credscan.py                # bounded, in-memory credential scan
tests/                        # stdlib unittest suite (hostile regressions)
safety_demo.py                # self-contained I/O-free safety demonstration
```

## Reproducible local checks (stdlib only, no third-party deps)

```sh
cd packages/release-control-successor-v3
PYTHONPATH=src python3 -m unittest discover -s tests -t tests -v
PYTHONPATH=src python3 safety_demo.py
```

## Adoption gate

This package takes effect **only** after a separate, reviewed change explicitly
constructs a `ReleaseConfig` and calls `evaluate()` from a wired caller. Until
then it is inert. It grants no authority and cannot weaken any existing safety,
help, export, delete, or recovery path.

## Known limitations

- Immutability is guaranteed at the **instance** level. Python permits
  class-object monkeypatching (reassigning a class attribute/property); that is
  a language-level capability outside this library's guarantee.
- `cohort_bucket` uses SHA-256 for stable bucketing, not for cryptographic
  authentication.
- The credential scan is a **bounded heuristic** over in-memory strings for
  hygiene checks; it is not a complete secret detector and does no file/network
  I/O of its own (callers feed it lines).
