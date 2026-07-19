# Build handoff — tonoit-release-control-v5

- Clean sole-parent baseline: `b4cf8b766f934d156f279b669c4190fcb7224623`.
- Scope: additive package only under `packages/tonoit-release-control-v5/`.
- Runtime status: inert and imported by nothing; no deployment, wiring, schema, provider, credential, billing, store, network, or production mutation.
- Strict-TTL correction: contexts issued in the future default off; age equal to or greater than `ttl_seconds` defaults off.
- Focused regressions: `test_future_issued_context_defaults_off` and `test_exact_ttl_boundary_defaults_off` exercise both `evaluate` and `is_released`.
- Preserved defenses: malformed exact-type tuples, descriptor/callable traps, hash-changing keys, ordinary-Exception fallback, BaseException propagation, scalar-only telemetry, deep immutability, and no entitlement authority.
- Builder verification policy: Gary authored the successor and did not execute its test suite. The immutable commit/tree/bundle must receive fresh, unlinked exact-object QA by Sherlock before any adoption.
