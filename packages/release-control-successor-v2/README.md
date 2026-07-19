# release-control-successor-v2

A fail-closed, privacy-first **release-control decision core**.

> **Status: unwired / default-off.** This package is source-only, standard-library
> only, and imported by nothing in the monorepo. Importing it performs no I/O
> (no network, filesystem, subprocess, environment, clock, schema, database,
> logging, or provider access) and starts no work. It is a pure decision core
> and is intentionally *not* integrated into any runtime.

## What it does

Given four plain-data inputs it returns a fail-closed `Decision`:

| input | type | meaning |
| --- | --- | --- |
| `capability` | `str` | the flag / capability being gated |
| `config` | `ReleaseConfig` | validated flag → rollout-rule store |
| `entitlement` | `Entitlement` | a *pre-existing* authorization to attempt the capability |
| `context` | `EvaluationContext` | caller-supplied runtime facts (build, schema, now, cohort, readiness, kill switch) |

```python
from release_control_successor_v2 import (
    evaluate, ReleaseConfig, Entitlement, EvaluationContext,
)

config = ReleaseConfig({
    "new_export_ui": {
        "percentage": 100,
        "issued_at": 1_700_000_000,
        "ttl_seconds": 86_400,
        "min_build": 100,
        "min_schema": 5,
        "allowlist": ["cohort-alpha"],
    },
})
entitlement = Entitlement(["new_export_ui"])
context = EvaluationContext(
    build=120, schema=5, now=1_700_001_000,
    cohort="cohort-alpha", ready=True, kill_switch=False,
)

decision = evaluate("new_export_ui", config, entitlement, context)
assert decision.allowed
decision.to_dict()            # -> plain dict of scalars
decision.to_telemetry().to_dict()
decision.to_audit_receipt().to_dict()
```

## Guarantees

* **Fail closed.** Unknown/malformed flags, configs, entitlements and contexts
  default off. Only exact plain trusted types are accepted; subclasses, custom
  mappings/sequences, hostile objects, `bool`-as-`int`, non-finite/huge numbers
  and raising accessors cannot bypass safety.
* **Never grants.** Release control can only *restrict* an already-authorized
  capability. It never creates entitlement or capability.
* **Protected capabilities** — `safety`, `help`, `export`, `delete`, `recovery`
  — can never be disabled or withheld, and precede every gate (including the
  kill switch).
* **Strict gates.** Kill switch and readiness fail closed and take precedence;
  build and schema compatibility are strict; TTL rejects future-issued, zero,
  negative, expired, `bool`, non-finite, huge, and wrong-type values with no
  implicit coercion; cohort percentage is an exact integer `0..100` where `0`
  never enables and `100` enables only after every other gate and entitlement.
* **Minimized privacy.** `TelemetryEvent`, `AuditReceipt` and `RollbackReceipt`
  each have one exact, finite, flat schema of scalar/enum values — no bags,
  nested objects, caller strings, raw identifiers, hashes, or reason echoes.
  Two callers with equivalent safe inputs emit identical output; caller
  secrets/identifiers never leak. Every `to_dict()` returns a newly isolated
  plain dict of built-in scalars.

## Tests

```sh
cd packages/release-control-successor-v2
python3 -m unittest discover -s tests -t . -v
```

The suite is standard-library `unittest` only; no third-party dependencies.
