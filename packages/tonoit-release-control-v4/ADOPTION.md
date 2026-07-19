# Adoption notes — tonoit-release-control-v4

## Current status: inert, imported by nothing

This package is **additive** and intentionally wired into nothing. Adopting it is
opt-in and must never be done as a side effect of merging this change.

## Design guarantees a caller can rely on

- **Total surface.** Every public function returns a well-typed value for *any*
  input and never raises for ordinary hostile input. Only genuine interpreter
  control signals (`KeyboardInterrupt`, `SystemExit`, and other non-`Exception`
  `BaseException`s) propagate.
- **Default-off.** `is_released` / `evaluate` deny unless every gate positively
  passes. Malformed config or context ⇒ not released.
- **No authority.** There is no API to grant, revoke, or mutate entitlements or
  capabilities. `PROTECTED_CAPABILITIES` is a read-only, deeply-immutable set.
- **No I/O.** No network, filesystem, database, schema, or clock access. The
  caller supplies `now` via `EvaluationContext`.

## If you choose to adopt it later (not part of this change)

1. Import `tonoit_release_control_v4` from the consuming module. Nothing imports
   it today; adding the first importer is a separate, reviewed change.
2. Construct `ReleaseConfig` / `EvaluationContext` **only** through the public
   constructors (never `tuple.__new__`). The validators exist to defend against
   forged instances, not to bless a normal construction path.
3. Gate behaviour on `is_released(cfg, ctx)` and record `telemetry_of(evaluate(...))`.
   Telemetry is finite-scalar-only and safe to log — it never echoes caller
   strings or objects.
4. Treat `serialize_config` output as a numeric fingerprint (it deliberately
   omits caller strings and capability member values).
5. Keep the package outside build/runtime/schema wiring unless a follow-up task
   explicitly authorises integration and re-reviews the boundary.

## Compatibility

- Python `>= 3.9`, standard library only, zero third-party dependencies.
- Verified on the baseline machine with CPython 3.9 (unittest + pytest) and, in a
  prior lane, CPython 3.11.
