# Database migrations (Alembic)

Real schema migrations for the Postgres database — see
`ARCHITECTURE.md`'s "Postgres + Redis migration" section for the full
story of why this exists alongside `Store.init_schema()`'s `create_all()`.

**The short version**: `create_all()` only creates tables that don't exist
yet — it never alters an existing table to match a changed column
definition. That's fine for bootstrapping a brand-new dev/test database
(which is all it's used for now — see `tests/conftest.py` and
`Store.init_schema()`), but it's not a real migration tool. From here
forward, **any schema change** (new column, new table, new index, a
changed constraint) should go through a new Alembic revision, not just an
edit to `Backend/db.py` that you assume `create_all` will pick up on an
existing database — it won't.

## Day-to-day usage

```bash
# After changing a Table definition in Backend/db.py:
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/tono_dev \
  alembic revision --autogenerate -m "describe the change"

# Review the generated file in versions/ — autogenerate is a good first
# draft, not a guarantee; check it against what you actually intended,
# especially for anything involving data migration (autogenerate only
# ever produces schema DDL, never a data backfill).

# Apply it:
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/tono_dev \
  alembic upgrade head
```

`DATABASE_URL` works the same way here as everywhere else in the backend
(see root `.env.example`) — `migrations/env.py` reads it directly, same
`postgres://` → `postgresql+asyncpg://` normalization included.

## Onboarding an existing database

A database that already has all the tables — e.g. this repo's own
`tono_dev`/`tono_test`, bootstrapped via `create_all()` before Alembic
existed — needs to be told "you're already at the current schema" rather
than have the initial migration's `CREATE TABLE` statements run against
tables that already exist (which will error):

```bash
alembic stamp head
```

Only do this once, for a database you've confirmed already matches
`Backend/db.py`'s current table definitions exactly. Any database created
fresh from here forward should use `alembic upgrade head` instead — never
`create_all()` — so its migration history is real.

## Production deploys

Run `alembic upgrade head` as part of your deploy step, before the new
app code starts serving traffic (a Railway pre-deploy command, or a
Docker entrypoint script that runs it before `exec uvicorn ...`). This
repo doesn't wire that up automatically — the app's own startup
(`Store.init_schema()`, called from `server.py`'s lifespan) intentionally
keeps using `create_all()` for its own dev/test bootstrap purpose and does
**not** run Alembic migrations itself, so a stale schema won't silently
"just work" via `create_all()` papering over a missing column — it'll
fail loudly instead, which is what you want in production.
