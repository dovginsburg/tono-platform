# Render production service, persistent disk, and why there is no `render.yaml`

Status: documentation only. This file contains no secrets, tokens, or
row-level data. It records an intentional operational decision plus the
fail-closed guard that enforces it in code.

## The production Render service

- Service: `srv-d9gg8ngk1i2s738lngd0` (externally managed, created in the
  Render dashboard).
- Runtime: the backend Docker image (`apps/backend/Dockerfile`), one uvicorn
  worker (`--workers 1`).
- Persistent disk: mounted at `/data`, backing a single SQLite file in WAL
  mode (`/data/tono.db` + `-wal` + `-shm`).
- DB path: `TONO_DB_PATH=/data/tono.db`, set as a service environment variable
  in the Render dashboard.

Render injects `RENDER=true` into every service's environment at runtime.

## Why the SQLite path must fail closed on Render (G-1)

The container's own filesystem is ephemeral: it is rebuilt on every deploy and
every restart. Only the disk mounted at `/data` survives. If the backend ever
opened its SQLite database anywhere else — the historical `./tono.db` default
in the working directory, or any path outside `/data` — every device row,
account, entitlement, and Stripe linkage would be silently wiped on the next
deploy. That is data loss, not a soft misconfiguration.

`backend.store.resolve_db_path()` therefore fails closed **on Render only**:

- `RENDER` truthy + `TONO_DB_PATH` unset/blank → `EphemeralDatabasePathError`.
- `RENDER` truthy + `TONO_DB_PATH` resolving (via `os.path.realpath`, so `..`
  and symlink escapes are collapsed) outside `/data` → `EphemeralDatabasePathError`.
- `RENDER` truthy + `TONO_DB_PATH` under `/data` → accepted.
- `RENDER` absent (local, dev, test, CI) → the historical `./tono.db` default
  and any explicit `TONO_DB_PATH` are preserved unchanged.

Startup (`get_store()` → the app lifespan) raises rather than booting against a
disk that would lose data. Render's health check then fails the deploy loudly
instead of promoting a data-losing container.

## Why there is deliberately NO `render.yaml` (no Blueprint)

The production Render service and its `/data` disk are **externally managed**:
they were created and are maintained directly in the Render dashboard, and
they hold the live production database.

We do **not** add a `render.yaml` Blueprint to this repository, on purpose:

1. **A Blueprint can create a parallel service and a parallel disk.** Applying
   a `render.yaml` in a Render "Blueprint instance" provisions the services and
   disks it declares. Because the existing service was created manually, a
   Blueprint would not adopt it in place; it would stand up a *second* service
   (and a *second*, empty `/data` disk) alongside the real one. That risks
   split-brain traffic and — far worse — an operator mistaking the empty
   Blueprint disk for production and cutting over to it, losing the real data.

2. **Disk lifecycle is destructive under IaC drift.** A Blueprint that ever
   disagreed with the live disk's size, mount path, or name could trigger a
   disk replacement. The production SQLite file is the single source of truth;
   it must never be subject to automated replace-on-drift.

3. **The service needs no reproducible fan-out.** There is exactly one
   production service. The value a Blueprint provides — declaratively spinning
   up many identical environments — does not apply, while its failure modes
   (parallel service, parallel/replaced disk) are precisely the data-loss
   traps we are trying to avoid.

The durable, in-repo contract is instead:

- the Dockerfile (build + one worker + persistent-disk assumptions, D-B1),
- `TONO_DB_PATH=/data/tono.db` as a documented service env var, and
- the `resolve_db_path()` fail-closed guard above, which makes a
  misconfigured disk a hard startup failure rather than silent data loss.

If we ever move Render management to IaC, it must be done as a Render
**"adopt existing resources"** flow (or a service-then-disk import that
explicitly binds to `srv-d9gg8ngk1i2s738lngd0` and its existing `/data`
disk), reviewed by the release owner — never by dropping a fresh `render.yaml`
that could provision new infrastructure.
