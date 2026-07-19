# Verification & TDD evidence — tonoit-release-control-v4

Baseline (sole parent): `b4cf8b766f934d156f279b669c4190fcb7224623`
Branch: `claude/t_e971802b-release-control-successor-v4`
Environment: macOS, CPython 3.9.6 (stdlib-only package; verified on 3.11 in a prior lane).

## TDD: RED → GREEN

| Phase | Command | Result | Receipt |
|-------|---------|--------|---------|
| RED   | `unittest discover` with implementation dir removed | **5 errors** (`ModuleNotFoundError: tonoit_release_control_v4`) — tests fail without impl | `RED-unittest.txt` |
| GREEN | `python3 -m unittest discover -t . -s tests` | **43 passed** | `GREEN-unittest.txt` |
| GREEN | `python3 -m pytest tests -q` | **43 passed** | `GREEN-pytest.txt` |
| DEMO  | `python3 -m tonoit_release_control_v4.safety_demo` | **13/13 invariants held**, exit 0 | `SAFETY-DEMO.txt` |

Focused RED repros included the mandatory malformed exact-type cases:
`tuple.__new__(Model, ())` (empty), short tuples, and forged same-arity tuples
with hostile values — asserting every public validator returns `False`.

## Hostile-gate coverage (all GREEN)

- Empty / short / forged exact-type instances rejected by **every** validator; never raise, never falsely accept (`test_malformed_models.py`).
- NaN/Inf scalars rejected; plain foreign tuples not falsely accepted.
- `evaluate` / `is_released` never propagate `IndexError`; default-off on malformed config **or** context (`test_engine.py`).
- Strict gate precedence: invalid → kill → readiness → build → schema → TTL → enabled → rollout (`test_engine.py`).
- `telemetry_of` / `serialize_config` never raise on malformed input; finite scalar-only; no caller string/object echo (`test_telemetry_serialize.py`).
- Hostile / hash-changing keys never hashed or compared — including one dropped into **every** field position (`test_hostile_gates.py`).
- No mutable callable / descriptor backdoor: field values never called, `__get__` never triggered.
- `BaseException` (KeyboardInterrupt/SystemExit/custom) propagates through the totality guard; ordinary `Exception` is absorbed.
- No grant / entitlement / membership-probe API; `PROTECTED_CAPABILITIES` read-only frozenset.
- Deep immutability of models (`__slots__ == ()`) and public constants.
- No network/storage module imported by the package.

## Repository-hygiene checks

| Check | Result | Receipt |
|-------|--------|---------|
| `git diff --cached --check` | clean (exit 0, no whitespace/conflict markers) | `git-diff-check.txt` |
| Imported-by-nothing | no references outside the package | `imported-by-nothing.txt` |
| Bounded credential/secret scan | no real secrets; only benign word/fixture matches | `credential-scan.txt` |
| Canonical baseline backend tests | collection error: `ModuleNotFoundError: httpx` — **pre-existing environment/dependency gap**, unrelated to this additive package | `BASELINE-backend-tests.txt` |

The backend-suite failure is an environment gap (backend third-party deps not
installed on this machine) recorded honestly; this package is imported by nothing
in the backend and cannot affect its result.

## Scope compliance

- Additive only, confined to `packages/tonoit-release-control-v4/`.
- No changes to lockfiles, deployment, runtime, schema, DNS, store, billing,
  providers, credentials, or production.
- No I/O / network / schema / runtime wiring.
