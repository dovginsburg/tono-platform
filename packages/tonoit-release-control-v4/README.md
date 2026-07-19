# tonoit-release-control-v4

An **inert, stdlib-only, additive** Python package: the release-control
*malformed-model successor (v4)*. It is imported by nothing in the platform and
is wired into no runtime, build, schema, network, or storage path. Its purpose
is to demonstrate a release-gating surface that stays **total** and **safe** when
handed adversarial, exact-type-but-malformed tuple-backed model instances.

> This package is a self-contained safety artifact. It does **not** issue,
> grant, or mutate any entitlement, and it performs no I/O.

## Why this exists

The models are `typing.NamedTuple`s — i.e. `tuple` subclasses. That makes them
deeply immutable, but it also means an adversary can *forge* an exact-type but
malformed instance without going through the constructor:

```python
tuple.__new__(ReleaseConfig, ())            # empty:  len 0
tuple.__new__(ReleaseConfig, (1, 2))        # short:  len 2
tuple.__new__(ReleaseConfig, [obj, ...])    # forged: right arity, hostile values
```

Reading a field off such an instance would raise `IndexError`, or worse, execute
a hostile field value. Every public entry point here is built to reject or
absorb these without raising and without ever falsely accepting.

## Safety invariants

| Invariant | How it is enforced |
|-----------|--------------------|
| Validators return `False`, never raise | positional `tuple.__getitem__` reads yield a `MISSING` sentinel on short tuples; whole body wrapped in a `guard` |
| Never falsely accept | `type(x) is Model` + exact arity + per-field type-identity checks |
| No `IndexError` through `evaluate`/`is_released` | validate first, then read; default-off on any failure |
| `telemetry_of`/`serialize_config` never raise on malformed input | validity-gated, `guard`-wrapped, safe zeroed fallback |
| Finite scalar-only telemetry | only `int`/`float`(finite) emitted; booleans as `0`/`1` |
| No caller object/string retention or echo | outputs carry integer reason codes and numeric scalars only |
| Hostile / hash-changing keys never execute | `frozenset` fields checked by **type identity only** — never hashed, compared, or iterated |
| No mutable callable / descriptor backdoor | field *values* are never called; reads bypass descriptors |
| `BaseException` (KeyboardInterrupt/SystemExit) propagates | `guard` catches `Exception` only, never `BaseException` |
| Deep immutability | `NamedTuple` (`__slots__ == ()`), `frozenset`, `MappingProxyType` constants |
| Strict gate precedence | invalid → kill → readiness → build → schema → TTL → enabled → rollout |
| Default-off unknowns | any unconfirmable state resolves to *not released* |
| No grant / entitlement authority | read-only `PROTECTED_CAPABILITIES`; no grant or membership-probe API |
| Strict finite TTL | TTL must be a finite, strictly-positive real |

## Public API

```python
import tonoit_release_control_v4 as rc

cfg = rc.ReleaseConfig(
    name="feature.x", enabled=True, kill_switch=False,
    min_build=100, schema_version=3, ttl_seconds=3600.0,
    rollout_permille=1000, capabilities=frozenset({"read"}),
)
ctx = rc.EvaluationContext(
    build_number=120, schema_version=3, ready=True,
    now=1000.0, issued_at=500.0, channel="stable",
)

rc.is_released(cfg, ctx)          # -> True
receipt = rc.evaluate(cfg, ctx)   # -> AuditReceipt (immutable, scalar-only)
rc.telemetry_of(receipt)          # -> {"valid": 1, "released": 1, ...}  finite scalars
rc.serialize_config(cfg)          # -> finite-scalar config fingerprint
rc.is_valid_release_config(cfg)   # -> True; False for any malformed input
rc.protected_capabilities()       # -> frozenset (read-only, no grant authority)
```

## Running the tests and the safety demo

The package and its tests are stdlib-only.

```bash
cd packages/tonoit-release-control-v4

# stdlib unittest
PYTHONPATH=. python3 -m unittest discover -t . -s tests -p 'test_*.py'

# or pytest
PYTHONPATH=. python3 -m pytest tests -q

# runnable safety demonstration (exits non-zero if any invariant fails)
PYTHONPATH=. python3 -m tonoit_release_control_v4.safety_demo
```

See [`ADOPTION.md`](./ADOPTION.md) and [`ROLLBACK.md`](./ROLLBACK.md).
