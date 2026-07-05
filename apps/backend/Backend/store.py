"""Postgres-backed (SQLAlchemy async + asyncpg) user + usage store for the
Tono backend.

Single source of truth for:
  - devices (one row per install; identity = `device_id` issued by the iOS app)
  - bearer tokens (long random; opaque; rotated on demand)
  - daily rewrite counter (resets at UTC midnight)
  - Stripe customer + subscription linkage
  - plan tier ("free" | "pro")
  - response cache (SHA-256 keyed, 5-min TTL)
  - axis events (which rewrite axis users tap)
  - Slack workspace installs

Migrated off SQLite (see git history for the previous single-writer
implementation) once "< 50K devices at MVP scale on one SQLite writer" was
no longer the right assumption — this now runs against Postgres via an
async connection pool, so route handlers can genuinely run concurrently
instead of serializing through one executor thread. Short-lived, ephemeral
state that used to live in plain Python dicts (WebAuthn challenges, Slack
per-user rate-limit windows) moved to Redis for the same reason: an
in-memory dict is only correct with exactly one worker process, and this
migration is explicitly about not being pinned to that.
"""

from __future__ import annotations

import contextlib
import datetime as dt
import json
import os
import threading
import uuid
from dataclasses import dataclass
from typing import Optional

from sqlalchemy import Integer, cast, delete, func, insert, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from .db import (
    DEFAULT_FLAGS,
    accounts,
    axis_events,
    coupon_redemptions,
    coupons,
    feature_flags,
    improvement_events,
    metadata,
    response_cache,
    slack_workspaces,
    stripe_events,
    usage_log,
    user_feature_overrides,
    users,
    webauthn_credentials,
)


def normalize_database_url(url: str) -> str:
    """Rewrite a plain ``postgres://``/``postgresql://`` URL (what Railway,
    Heroku, and most Postgres add-ons hand you) to the ``+asyncpg`` driver
    SQLAlchemy's async engine requires. Already-correct URLs pass through
    unchanged."""
    if url.startswith("postgresql+asyncpg://"):
        return url
    if url.startswith("postgresql://"):
        return "postgresql+asyncpg://" + url[len("postgresql://"):]
    if url.startswith("postgres://"):
        return "postgresql+asyncpg://" + url[len("postgres://"):]
    return url


class AccountConflictError(Exception):
    """Raised when linking a provider identity or passkey would silently
    merge two distinct accounts. Callers (server.py) should surface this as
    a 409 — merging accounts is a decision a person confirms explicitly,
    never something inferred from a login attempt."""


def _plan_grants_pro(plan: str, subscription_status: Optional[str], coupon_pro_expires_at: Optional[str]) -> bool:
    if plan == "pro" and subscription_status in ("active", "trialing"):
        return True
    if coupon_pro_expires_at:
        try:
            exp = dt.datetime.fromisoformat(coupon_pro_expires_at)
            if exp > dt.datetime.now(dt.timezone.utc):
                return True
        except ValueError:
            pass
    return False


@dataclass
class Account:
    """A signed-in person, spanning every device they've linked via Apple/
    Google sign-in. Plan/subscription live here once an account exists —
    see the `accounts` table comment in db.py for why they're duplicated
    on `users` too."""

    id: str
    apple_sub: Optional[str]
    google_sub: Optional[str]
    email: Optional[str]
    plan: str
    stripe_customer_id: Optional[str]
    stripe_subscription_id: Optional[str]
    subscription_status: Optional[str]
    subscription_renews_at: Optional[str]
    coupon_pro_expires_at: Optional[str]
    created_at: str
    updated_at: str
    daily_count: int = 0
    daily_day: Optional[str] = None

    @property
    def is_pro(self) -> bool:
        return _plan_grants_pro(self.plan, self.subscription_status, self.coupon_pro_expires_at)


@dataclass
class WebAuthnCredential:
    """One registered passkey. `public_key` is the raw COSE-encoded key
    bytes py_webauthn hands back from registration — needed to verify every
    future login assertion from this credential."""

    credential_id: str  # base64url
    account_id: str
    public_key: bytes
    sign_count: int
    transports: list[str]
    nickname: Optional[str]
    created_at: str
    last_used_at: Optional[str]


@dataclass
class User:
    device_id: str
    api_token: str
    plan: str
    stripe_customer_id: Optional[str]
    stripe_subscription_id: Optional[str]
    subscription_status: Optional[str]
    subscription_renews_at: Optional[str]
    daily_count: int
    daily_day: Optional[str]
    created_at: str
    updated_at: str
    coupon_pro_expires_at: Optional[str] = None
    account_id: Optional[str] = None
    account: Optional[Account] = None

    @property
    def is_pro(self) -> bool:
        # A linked account is the source of truth once one exists — a
        # device that signed in inherits Pro from the account even if that
        # particular device never itself had a Stripe subscription.
        if self.account is not None:
            return self.account.is_pro
        return _plan_grants_pro(self.plan, self.subscription_status, self.coupon_pro_expires_at)

    @property
    def plan_resolved(self) -> str:
        """`plan`, but resolved through the linked account when present."""
        return self.account.plan if self.account is not None else self.plan


# ---------------------------------------------------------------------------
# Store
# ---------------------------------------------------------------------------


class Store:
    def __init__(self, database_url: str):
        self.database_url = database_url
        self._engine: AsyncEngine = create_async_engine(database_url, pool_pre_ping=True)

    # ---- lifecycle ----

    async def init_schema(self) -> None:
        async with self._engine.begin() as conn:
            await conn.run_sync(metadata.create_all)
        await self._seed_feature_flags()

    async def _seed_feature_flags(self) -> None:
        async with self._engine.begin() as conn:
            for key, enabled, plan_required, rollout_pct, user_controllable, description in DEFAULT_FLAGS:
                stmt = pg_insert(feature_flags).values(
                    key=key,
                    enabled=enabled,
                    plan_required=plan_required,
                    rollout_pct=rollout_pct,
                    user_controllable=user_controllable,
                    description=description,
                ).on_conflict_do_nothing(index_elements=[feature_flags.c.key])
                await conn.execute(stmt)

    async def close(self) -> None:
        with contextlib.suppress(Exception):
            await self._engine.dispose()

    # ---- user / device ----

    async def register_device(self, device_id: Optional[str] = None) -> User:
        now = _now_iso()
        async with self._engine.begin() as conn:
            if device_id:
                row = (await conn.execute(select(users).where(users.c.device_id == device_id))).mappings().first()
                if row:
                    if not row["api_token"]:
                        token = _new_token()
                        await conn.execute(
                            update(users).where(users.c.device_id == device_id)
                            .values(api_token=token, updated_at=now)
                        )
                        return _row_to_user({**dict(row), "api_token": token, "updated_at": now})
                    return _row_to_user(row)
            did = device_id or str(uuid.uuid4())
            token = _new_token()
            await conn.execute(
                insert(users).values(device_id=did, api_token=token, plan="free", created_at=now, updated_at=now)
            )
            row = (await conn.execute(select(users).where(users.c.device_id == did))).mappings().first()
            return _row_to_user(row)

    async def _attach_account(self, conn, user: User) -> User:
        """Populate `user.account` when the device is linked to one. Called
        with the caller's own connection so it participates in the same
        transaction rather than opening a second one."""
        if user.account_id:
            row = (await conn.execute(select(accounts).where(accounts.c.id == user.account_id))).mappings().first()
            if row:
                user.account = _row_to_account(row)
        return user

    async def get_by_token(self, token: str) -> Optional[User]:
        async with self._engine.begin() as conn:
            row = (await conn.execute(select(users).where(users.c.api_token == token))).mappings().first()
            if not row:
                return None
            return await self._attach_account(conn, _row_to_user(row))

    async def get_by_device(self, device_id: str) -> Optional[User]:
        async with self._engine.begin() as conn:
            row = (await conn.execute(select(users).where(users.c.device_id == device_id))).mappings().first()
            if not row:
                return None
            return await self._attach_account(conn, _row_to_user(row))

    async def rotate_token(self, device_id: str) -> Optional[str]:
        token = _new_token()
        async with self._engine.begin() as conn:
            result = await conn.execute(
                update(users).where(users.c.device_id == device_id).values(api_token=token, updated_at=_now_iso())
            )
            return token if result.rowcount else None

    async def attach_stripe_customer(self, device_id: str, customer_id: str) -> None:
        async with self._engine.begin() as conn:
            await conn.execute(
                update(users).where(users.c.device_id == device_id)
                .values(stripe_customer_id=customer_id, updated_at=_now_iso())
            )

    async def attach_account_stripe_customer(self, account_id: str, customer_id: str) -> None:
        async with self._engine.begin() as conn:
            await conn.execute(
                update(accounts).where(accounts.c.id == account_id)
                .values(stripe_customer_id=customer_id, updated_at=_now_iso())
            )

    async def update_subscription(
        self,
        *,
        device_id: Optional[str] = None,
        customer_id: Optional[str] = None,
        subscription_id: Optional[str],
        status: Optional[str],
        renews_at: Optional[str],
    ) -> None:
        assert device_id or customer_id, "need device_id or customer_id"
        plan = "pro" if status in ("active", "trialing") else "free"
        cond = users.c.device_id == device_id if device_id else users.c.stripe_customer_id == customer_id
        async with self._engine.begin() as conn:
            await conn.execute(
                update(users).where(cond).values(
                    plan=plan,
                    stripe_subscription_id=subscription_id,
                    subscription_status=status,
                    subscription_renews_at=renews_at,
                    updated_at=_now_iso(),
                )
            )

    # ---- accounts (Apple/Google sign-in) ----

    async def upsert_account_by_provider(
        self,
        provider: str,
        sub: str,
        email: Optional[str] = None,
        *,
        link_into_account_id: Optional[str] = None,
    ) -> Account:
        """Find the account for this Apple/Google subject, creating one on
        first sign-in. Idempotent — signing in again with the same subject
        just returns the existing account (updating email if it changed).

        ``link_into_account_id`` is the calling device's *current* account
        (if it's already signed in) — pass it so that adding a second
        provider (e.g. "also let me sign in with Google") attaches to the
        SAME account instead of silently creating a stray second one. If
        that subject already belongs to a *different* account, raises
        AccountConflictError rather than merging two accounts that may
        each have their own history — merging is a decision a person
        should confirm explicitly, not something we do for them.
        """
        assert provider in ("apple", "google"), f"unknown provider: {provider}"
        column = accounts.c[f"{provider}_sub"]
        now = _now_iso()

        async with self._engine.begin() as conn:
            row = (await conn.execute(select(accounts).where(column == sub))).mappings().first()

            if row:
                if link_into_account_id and row["id"] != link_into_account_id:
                    raise AccountConflictError(
                        f"this {provider} identity is already linked to a different account"
                    )
                if email and email != row["email"]:
                    await conn.execute(
                        update(accounts).where(accounts.c.id == row["id"]).values(email=email, updated_at=now)
                    )
                    row = (await conn.execute(select(accounts).where(accounts.c.id == row["id"]))).mappings().first()
                return _row_to_account(row)

            if link_into_account_id:
                # First time we've seen this identity, and the calling device
                # is already signed in — attach the provider to that account
                # (an upgrade, "add another way to sign in") instead of
                # minting a new one.
                existing = (
                    await conn.execute(select(accounts).where(accounts.c.id == link_into_account_id))
                ).mappings().first()
                if not existing:
                    raise AccountConflictError(f"account {link_into_account_id} does not exist")
                try:
                    async with conn.begin_nested():
                        await conn.execute(
                            update(accounts).where(accounts.c.id == link_into_account_id).values(
                                **{f"{provider}_sub": sub},
                                email=func.coalesce(accounts.c.email, email),
                                updated_at=now,
                            )
                        )
                except IntegrityError:
                    # Lost a race: something else claimed this identity for a
                    # different account between our SELECT above and this
                    # UPDATE. Re-check for real, don't just assume — it's
                    # possible (if unlikely) the race resolved in our favor.
                    row = (await conn.execute(select(accounts).where(column == sub))).mappings().first()
                    if row and row["id"] != link_into_account_id:
                        raise AccountConflictError(
                            f"this {provider} identity is already linked to a different account"
                        )
                row = (
                    await conn.execute(select(accounts).where(accounts.c.id == link_into_account_id))
                ).mappings().first()
                return _row_to_account(row)

            account_id = str(uuid.uuid4())
            try:
                async with conn.begin_nested():
                    await conn.execute(
                        insert(accounts).values(
                            id=account_id, **{f"{provider}_sub": sub}, email=email,
                            plan="free", created_at=now, updated_at=now,
                        )
                    )
            except IntegrityError:
                # Lost a race: two concurrent first-time sign-ins with the
                # same identity both got past the SELECT above and both
                # tried to insert a new account. The loser here isn't an
                # error — the winner's row is exactly the account we should
                # return, so re-select and use it instead of creating a
                # second, orphaned account.
                row = (await conn.execute(select(accounts).where(column == sub))).mappings().first()
                return _row_to_account(row)
            row = (await conn.execute(select(accounts).where(accounts.c.id == account_id))).mappings().first()
            return _row_to_account(row)

    async def get_account(self, account_id: str) -> Optional[Account]:
        async with self._engine.begin() as conn:
            row = (await conn.execute(select(accounts).where(accounts.c.id == account_id))).mappings().first()
            return _row_to_account(row) if row else None

    async def link_device_to_account(self, device_id: str, account_id: str) -> None:
        """Attach this device to an account. Safe to call repeatedly (e.g.
        re-signing-in on the same device) and safe to call from multiple
        devices for the same account — that's the whole point: every linked
        device shares the account's Pro status from then on."""
        async with self._engine.begin() as conn:
            await conn.execute(
                update(users).where(users.c.device_id == device_id)
                .values(account_id=account_id, updated_at=_now_iso())
            )

    async def update_account_subscription(
        self,
        *,
        account_id: Optional[str] = None,
        customer_id: Optional[str] = None,
        subscription_id: Optional[str],
        status: Optional[str],
        renews_at: Optional[str],
    ) -> None:
        """Account-level counterpart of `update_subscription` — what
        apps/backend/Backend/payments.py's webhook handler calls when a
        subscription is tied to a signed-in account, so it covers every
        device linked to that account rather than just the one that
        started checkout. Falls back to `customer_id` lookup the same way
        the device-level method does, for webhook events that don't carry
        our metadata (e.g. a Billing Portal-initiated cancellation)."""
        assert account_id or customer_id, "need account_id or customer_id"
        plan = "pro" if status in ("active", "trialing") else "free"
        cond = accounts.c.id == account_id if account_id else accounts.c.stripe_customer_id == customer_id
        async with self._engine.begin() as conn:
            await conn.execute(
                update(accounts).where(cond).values(
                    plan=plan,
                    stripe_subscription_id=subscription_id,
                    subscription_status=status,
                    subscription_renews_at=renews_at,
                    updated_at=_now_iso(),
                )
            )

    # ---- passkeys (WebAuthn) ----

    async def create_bare_account(self) -> Account:
        """A brand-new account with no Apple/Google identity — passkey
        registration can be someone's *first* sign-up, not just an addition
        to an existing Apple/Google account."""
        account_id = str(uuid.uuid4())
        now = _now_iso()
        async with self._engine.begin() as conn:
            await conn.execute(insert(accounts).values(id=account_id, plan="free", created_at=now, updated_at=now))
            row = (await conn.execute(select(accounts).where(accounts.c.id == account_id))).mappings().first()
            return _row_to_account(row)

    async def add_webauthn_credential(
        self,
        *,
        credential_id: str,
        account_id: str,
        public_key: bytes,
        sign_count: int,
        transports: Optional[list[str]] = None,
        nickname: Optional[str] = None,
    ) -> None:
        async with self._engine.begin() as conn:
            await conn.execute(
                insert(webauthn_credentials).values(
                    credential_id=credential_id,
                    account_id=account_id,
                    public_key=public_key,
                    sign_count=sign_count,
                    transports=json.dumps(transports or []),
                    nickname=nickname,
                    created_at=_now_iso(),
                )
            )

    async def get_webauthn_credential(self, credential_id: str) -> Optional[WebAuthnCredential]:
        async with self._engine.begin() as conn:
            row = (
                await conn.execute(
                    select(webauthn_credentials).where(webauthn_credentials.c.credential_id == credential_id)
                )
            ).mappings().first()
            return _row_to_webauthn_credential(row) if row else None

    async def list_webauthn_credentials(self, account_id: str) -> list[WebAuthnCredential]:
        async with self._engine.begin() as conn:
            rows = (
                await conn.execute(
                    select(webauthn_credentials)
                    .where(webauthn_credentials.c.account_id == account_id)
                    .order_by(webauthn_credentials.c.created_at)
                )
            ).mappings().all()
            return [_row_to_webauthn_credential(r) for r in rows]

    async def update_webauthn_sign_count(self, credential_id: str, new_count: int) -> None:
        async with self._engine.begin() as conn:
            await conn.execute(
                update(webauthn_credentials).where(webauthn_credentials.c.credential_id == credential_id)
                .values(sign_count=new_count, last_used_at=_now_iso())
            )

    async def delete_webauthn_credential(self, credential_id: str, account_id: str) -> bool:
        """Scoped to account_id so one account can't delete another's
        credential by guessing/enumerating credential_id values."""
        async with self._engine.begin() as conn:
            result = await conn.execute(
                delete(webauthn_credentials).where(
                    webauthn_credentials.c.credential_id == credential_id,
                    webauthn_credentials.c.account_id == account_id,
                )
            )
            return result.rowcount > 0

    # ---- rate limit ----

    async def consume_rewrite(self, device_id: str) -> tuple[bool, int, int]:
        """Check + increment the daily free-tier counter.

        Anonymous devices count against their own `users.daily_count` row,
        exactly as before accounts existed. A device linked to an account
        counts against `accounts.daily_count` instead — pooled across every
        device linked to that account, so a free user's daily allowance is
        one shared quota across their phone, laptop, etc., not N per
        device. The quota row is locked with `SELECT ... FOR UPDATE` for
        the duration of the transaction, which is what actually makes the
        increment safe under concurrent requests now that Postgres allows
        genuinely concurrent connections (SQLite's single-writer executor
        used to make this safe implicitly by serializing everything).
        """
        async with self._engine.begin() as conn:
            row = (
                await conn.execute(
                    select(users.c.account_id).where(users.c.device_id == device_id)
                )
            ).mappings().first()
            if not row:
                return (False, 0, 0)

            if row["account_id"]:
                table, key_col, key_val = accounts, accounts.c.id, row["account_id"]
            else:
                table, key_col, key_val = users, users.c.device_id, device_id

            quota_row = (
                await conn.execute(
                    select(
                        table.c.plan, table.c.subscription_status, table.c.coupon_pro_expires_at,
                        table.c.daily_count, table.c.daily_day,
                    )
                    .where(key_col == key_val)
                    .with_for_update()
                )
            ).mappings().first()

            if quota_row["plan"] == "pro" and quota_row["subscription_status"] in ("active", "trialing"):
                return (True, quota_row["daily_count"], -1)
            if quota_row["coupon_pro_expires_at"] and quota_row["coupon_pro_expires_at"] > _now_iso():
                return (True, quota_row["daily_count"], -1)

            today = _today_utc()
            used = quota_row["daily_count"] if quota_row["daily_day"] == today else 0
            limit = int(os.environ.get("FREE_DAILY_LIMIT", "10"))
            if used >= limit:
                return (False, used, limit)

            new_used = 1 if quota_row["daily_day"] != today else used + 1
            await conn.execute(
                update(table).where(key_col == key_val)
                .values(daily_count=new_used, daily_day=today, updated_at=_now_iso())
            )
            return (True, new_used, limit)

    # ---- response cache ----

    async def get_cached_response(self, cache_key: str, ttl_seconds: int = 300) -> Optional[dict]:
        async with self._engine.begin() as conn:
            row = (
                await conn.execute(
                    select(response_cache.c.response_json, response_cache.c.created_at)
                    .where(response_cache.c.cache_key == cache_key)
                )
            ).mappings().first()
            if not row:
                return None
            age = (dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(row["created_at"])).total_seconds()
            if age > ttl_seconds:
                await conn.execute(delete(response_cache).where(response_cache.c.cache_key == cache_key))
                return None
            return json.loads(row["response_json"])

    async def set_cached_response(self, cache_key: str, response: dict) -> None:
        stmt = pg_insert(response_cache).values(
            cache_key=cache_key, response_json=json.dumps(response), created_at=_now_iso()
        )
        stmt = stmt.on_conflict_do_update(
            index_elements=[response_cache.c.cache_key],
            set_={"response_json": stmt.excluded.response_json, "created_at": stmt.excluded.created_at},
        )
        async with self._engine.begin() as conn:
            await conn.execute(stmt)

    async def purge_expired_cache(self, ttl_seconds: int = 300) -> None:
        cutoff = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=ttl_seconds)).isoformat(timespec="seconds")
        async with self._engine.begin() as conn:
            await conn.execute(delete(response_cache).where(response_cache.c.created_at < cutoff))

    # ---- axis events ----

    async def log_axis_event(self, device_id: str, axis: str, risk_level: str) -> None:
        async with self._engine.begin() as conn:
            await conn.execute(
                insert(axis_events).values(device_id=device_id, ts=_now_iso(), axis=axis, risk_level=risk_level)
            )

    async def axis_stats(self, days: int = 30) -> dict:
        """Aggregate axis tap counts for the last N days."""
        cutoff = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)).strftime("%Y-%m-%d")
        async with self._engine.begin() as conn:
            rows = (
                await conn.execute(
                    select(axis_events.c.axis, func.count().label("cnt"))
                    .where(axis_events.c.ts >= cutoff)
                    .group_by(axis_events.c.axis)
                    .order_by(func.count().desc())
                )
            ).mappings().all()
            return {r["axis"]: r["cnt"] for r in rows}

    async def axis_stats_by_risk(self, days: int = 30) -> dict:
        """Axis tap counts broken down by risk level for the last N days.

        Returns ``{risk_level: {axis: count}}``. Used to understand which
        axes resonate when messages are high-risk vs low-risk — feeds into
        prompt ordering when no per-user preference exists.
        """
        cutoff = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)).strftime("%Y-%m-%d")
        async with self._engine.begin() as conn:
            rows = (
                await conn.execute(
                    select(axis_events.c.risk_level, axis_events.c.axis, func.count().label("cnt"))
                    .where(axis_events.c.ts >= cutoff)
                    .group_by(axis_events.c.risk_level, axis_events.c.axis)
                    .order_by(axis_events.c.risk_level, func.count().desc())
                )
            ).mappings().all()
            result: dict = {}
            for r in rows:
                result.setdefault(r["risk_level"], {})[r["axis"]] = r["cnt"]
            return result

    async def global_axis_ranking(self, days: int = 30) -> list:
        """Return all four axes sorted by global win count (most-chosen first).

        Used as the collective-intelligence default when a client has no
        per-user StyleMemory preference yet. Falls back to the canonical
        default order when the DB has no axis events.
        """
        _default = ["warmer", "clearer", "funnier", "safer"]
        stats = await self.axis_stats(days=days)
        if not stats:
            return _default
        return sorted(_default, key=lambda a: stats.get(a, 0), reverse=True)

    # ---- collective improvement events ----

    async def log_improvement_event(
        self,
        device_id: str,
        risk_predicted: str,
        axis_selected: "Optional[str]",
        mode: str,
        msg_len_bucket: str,
        rewrite_used: bool,
        edit_after: bool = False,
    ) -> None:
        """Store one content-free behavioral outcome for the collective signal.

        Called only when the 'improve_tono' flag is enabled for the device.
        device_id is retained solely to enforce the k-anonymity floor at
        aggregation time; individual rows are never queried outside of bulk
        aggregates.
        """
        async with self._engine.begin() as conn:
            await conn.execute(
                insert(improvement_events).values(
                    device_id=device_id,
                    ts=_now_iso(),
                    risk_predicted=risk_predicted,
                    axis_selected=axis_selected,
                    mode=mode,
                    msg_len_bucket=msg_len_bucket,
                    rewrite_used=bool(rewrite_used),
                    edit_after=bool(edit_after),
                )
            )

    async def get_axis_effectiveness(self, days: int = 30, min_devices: int = 50) -> dict:
        """Axis win rates by risk level.

        k-anonymity: only returns patterns backed by >= min_devices distinct
        devices. This is enforced at the SQL level with HAVING, not by
        convention — a pattern with fewer contributors is discarded entirely.

        Returns ``{risk_level: [{axis, events, distinct_devices}, ...]}``.
        """
        cutoff = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)).strftime("%Y-%m-%d")
        distinct_devices = func.count(func.distinct(improvement_events.c.device_id))
        async with self._engine.begin() as conn:
            rows = (
                await conn.execute(
                    select(
                        improvement_events.c.risk_predicted,
                        improvement_events.c.axis_selected,
                        func.count().label("event_count"),
                        distinct_devices.label("device_count"),
                    )
                    .where(
                        improvement_events.c.ts >= cutoff,
                        improvement_events.c.rewrite_used.is_(True),
                        improvement_events.c.axis_selected.isnot(None),
                    )
                    .group_by(improvement_events.c.risk_predicted, improvement_events.c.axis_selected)
                    .having(distinct_devices >= min_devices)
                    .order_by(improvement_events.c.risk_predicted, func.count().desc())
                )
            ).mappings().all()
            result: dict = {}
            for r in rows:
                result.setdefault(r["risk_predicted"], []).append(
                    {"axis": r["axis_selected"], "events": r["event_count"], "distinct_devices": r["device_count"]}
                )
            return result

    async def get_rewrite_quality(self, days: int = 30, min_devices: int = 50) -> dict:
        """Edit-after-insert rate by axis — a proxy for rewrite quality.

        High edit_after_rate = users are choosing the axis but rewriting the
        suggestion, meaning the rewrite is close-but-wrong. Feed this into
        prompt revision for those axes.

        k-anonymity: same HAVING floor as get_axis_effectiveness.

        Returns ``{axis: {total_insertions, edit_after_count, edit_after_rate,
        distinct_devices}}``.
        """
        cutoff = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)).strftime("%Y-%m-%d")
        distinct_devices = func.count(func.distinct(improvement_events.c.device_id))
        async with self._engine.begin() as conn:
            rows = (
                await conn.execute(
                    select(
                        improvement_events.c.axis_selected,
                        func.count().label("total"),
                        func.sum(cast(improvement_events.c.edit_after, Integer)).label("edits"),
                        distinct_devices.label("device_count"),
                    )
                    .where(
                        improvement_events.c.ts >= cutoff,
                        improvement_events.c.rewrite_used.is_(True),
                        improvement_events.c.axis_selected.isnot(None),
                    )
                    .group_by(improvement_events.c.axis_selected)
                    .having(distinct_devices >= min_devices)
                    .order_by(improvement_events.c.axis_selected)
                )
            ).mappings().all()
            result: dict = {}
            for r in rows:
                total = r["total"]
                edits = r["edits"] or 0
                result[r["axis_selected"]] = {
                    "total_insertions": total,
                    "edit_after_count": edits,
                    "edit_after_rate": round(edits / total, 3) if total > 0 else 0.0,
                    "distinct_devices": r["device_count"],
                }
            return result

    async def age_out_improvement_events(self, retain_days: int = 90) -> int:
        """Delete improvement_events older than retain_days. Returns count deleted.

        Raw events are kept only long enough to compute rolling aggregates;
        after that they are discarded. Call periodically (e.g. nightly).
        """
        cutoff = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=retain_days)).strftime("%Y-%m-%d")
        async with self._engine.begin() as conn:
            result = await conn.execute(delete(improvement_events).where(improvement_events.c.ts < cutoff))
            return result.rowcount

    # ---- Slack ----

    async def upsert_slack_workspace(
        self, team_id: str, access_token: str, team_name: str, bot_user_id: str
    ) -> None:
        now = _now_iso()
        stmt = pg_insert(slack_workspaces).values(
            team_id=team_id, access_token=access_token, team_name=team_name,
            bot_user_id=bot_user_id, installed_at=now, updated_at=now,
        )
        stmt = stmt.on_conflict_do_update(
            index_elements=[slack_workspaces.c.team_id],
            set_={
                "access_token": stmt.excluded.access_token,
                "team_name": stmt.excluded.team_name,
                "bot_user_id": stmt.excluded.bot_user_id,
                "updated_at": stmt.excluded.updated_at,
            },
        )
        async with self._engine.begin() as conn:
            await conn.execute(stmt)

    # ---- coupons ----

    async def redeem_coupon(self, device_id: str, code: str) -> str:
        """Redeem a coupon code for the given device. Returns the new
        coupon_pro_expires_at ISO string on success.
        Raises ValueError with a user-visible message on failure."""
        now = _now_iso()
        async with self._engine.begin() as conn:
            row = (
                await conn.execute(select(coupons).where(coupons.c.code == code).with_for_update())
            ).mappings().first()
            if not row:
                raise ValueError("Invalid code.")
            if row["expires_at"] and row["expires_at"] < now:
                raise ValueError("This code has expired.")
            if row["max_uses"] > 0 and row["use_count"] >= row["max_uses"]:
                raise ValueError("This code has reached its usage limit.")
            existing = (
                await conn.execute(
                    select(coupon_redemptions).where(
                        coupon_redemptions.c.device_id == device_id, coupon_redemptions.c.code == code
                    )
                )
            ).first()
            if existing:
                raise ValueError("You've already redeemed this code.")

            expires_at = (
                dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=int(row["duration_days"]))
            ).isoformat(timespec="seconds")
            await conn.execute(insert(coupon_redemptions).values(device_id=device_id, code=code, redeemed_at=now))
            await conn.execute(update(coupons).where(coupons.c.code == code).values(use_count=coupons.c.use_count + 1))
            await conn.execute(
                update(users).where(users.c.device_id == device_id)
                .values(coupon_pro_expires_at=expires_at, updated_at=now)
            )
            return expires_at

    async def create_coupon(
        self,
        code: str,
        duration_days: int,
        max_uses: int = 0,
        expires_at: Optional[str] = None,
    ) -> bool:
        """Insert a new coupon. Returns False if the code already exists."""
        async with self._engine.begin() as conn:
            try:
                async with conn.begin_nested():
                    await conn.execute(
                        insert(coupons).values(
                            code=code, duration_days=duration_days, max_uses=max_uses,
                            use_count=0, created_at=_now_iso(), expires_at=expires_at,
                        )
                    )
                return True
            except IntegrityError:
                return False

    async def get_slack_workspace(self, team_id: str) -> Optional[dict]:
        async with self._engine.begin() as conn:
            row = (
                await conn.execute(select(slack_workspaces).where(slack_workspaces.c.team_id == team_id))
            ).mappings().first()
            return dict(row) if row else None

    # ---- audit ----

    async def log_usage(
        self,
        device_id: str,
        endpoint: str,
        status_code: int,
        provider: Optional[str] = None,
        drafts_chars: Optional[int] = None,
    ) -> None:
        async with self._engine.begin() as conn:
            await conn.execute(
                insert(usage_log).values(
                    device_id=device_id, ts=_now_iso(), endpoint=endpoint,
                    status_code=status_code, provider=provider, drafts_chars=drafts_chars,
                )
            )

    # ---- feature flags ----

    async def get_features(self, device_id: str, is_pro: bool) -> dict[str, bool]:
        """Resolve flags for a device: global default → plan gate → user override."""
        async with self._engine.begin() as conn:
            flag_rows = (
                await conn.execute(select(feature_flags.c.key, feature_flags.c.enabled, feature_flags.c.plan_required))
            ).mappings().all()
            flags = {r["key"]: {"enabled": r["enabled"], "plan": r["plan_required"]} for r in flag_rows}

            override_rows = (
                await conn.execute(
                    select(user_feature_overrides.c.flag_key, user_feature_overrides.c.enabled)
                    .where(user_feature_overrides.c.device_id == device_id)
                )
            ).mappings().all()
            overrides = {r["flag_key"]: r["enabled"] for r in override_rows}

            result: dict[str, bool] = {}
            for key, meta in flags.items():
                if meta["plan"] == "pro" and not is_pro:
                    result[key] = False
                    continue
                result[key] = overrides.get(key, meta["enabled"])
            return result

    async def get_all_flags(self) -> list[dict]:
        async with self._engine.begin() as conn:
            rows = (await conn.execute(select(feature_flags).order_by(feature_flags.c.key))).mappings().all()
            return [dict(r) for r in rows]

    async def update_flag(
        self,
        key: str,
        enabled: Optional[bool] = None,
        plan_required: Optional[str] = "UNCHANGED",
        rollout_pct: Optional[int] = None,
    ) -> bool:
        values: dict = {}
        if enabled is not None:
            values["enabled"] = enabled
        if plan_required != "UNCHANGED":
            values["plan_required"] = plan_required
        if rollout_pct is not None:
            values["rollout_pct"] = rollout_pct
        if not values:
            return True
        values["updated_at"] = _now_iso()
        async with self._engine.begin() as conn:
            result = await conn.execute(update(feature_flags).where(feature_flags.c.key == key).values(**values))
            return result.rowcount > 0

    async def set_user_flag_override(
        self, device_id: str, flag_key: str, enabled: bool, set_by: str = "admin"
    ) -> None:
        stmt = pg_insert(user_feature_overrides).values(
            device_id=device_id, flag_key=flag_key, enabled=enabled, set_by=set_by, created_at=_now_iso(),
        )
        stmt = stmt.on_conflict_do_update(
            index_elements=[user_feature_overrides.c.device_id, user_feature_overrides.c.flag_key],
            set_={"enabled": stmt.excluded.enabled, "set_by": stmt.excluded.set_by},
        )
        async with self._engine.begin() as conn:
            await conn.execute(stmt)

    async def delete_user_flag_override(self, device_id: str, flag_key: str) -> None:
        async with self._engine.begin() as conn:
            await conn.execute(
                delete(user_feature_overrides).where(
                    user_feature_overrides.c.device_id == device_id,
                    user_feature_overrides.c.flag_key == flag_key,
                )
            )

    async def get_weekly_digest(self, device_id: str) -> dict:
        now = dt.datetime.now(dt.timezone.utc)
        cutoff = (now - dt.timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")
        prev_cutoff = (now - dt.timedelta(days=14)).strftime("%Y-%m-%dT%H:%M:%SZ")

        async with self._engine.begin() as conn:
            total = (
                await conn.execute(
                    select(func.count()).select_from(axis_events)
                    .where(axis_events.c.device_id == device_id, axis_events.c.ts >= cutoff)
                )
            ).scalar_one()

            rows = (
                await conn.execute(
                    select(axis_events.c.axis, func.count().label("cnt"))
                    .where(axis_events.c.device_id == device_id, axis_events.c.ts >= cutoff)
                    .group_by(axis_events.c.axis).order_by(func.count().desc())
                )
            ).mappings().all()
            axis_breakdown = {r["axis"]: r["cnt"] for r in rows}

            prev_rows = (
                await conn.execute(
                    select(axis_events.c.axis, func.count().label("cnt"))
                    .where(
                        axis_events.c.device_id == device_id,
                        axis_events.c.ts >= prev_cutoff,
                        axis_events.c.ts < cutoff,
                    )
                    .group_by(axis_events.c.axis).order_by(func.count().desc())
                )
            ).mappings().all()
            prev_axis_breakdown = {r["axis"]: r["cnt"] for r in prev_rows}

            # `ts` is stored as an ISO-8601 string (see db.py), so the date
            # is its first 10 characters — a substring, not a real DATE()
            # cast, matching the "timestamps stay as text" scope decision.
            days_active = (
                await conn.execute(
                    select(func.count(func.distinct(func.substr(axis_events.c.ts, 1, 10))))
                    .where(axis_events.c.device_id == device_id, axis_events.c.ts >= cutoff)
                )
            ).scalar_one()

            return {
                "period_days": 7,
                "rewrites": total,
                "days_active": days_active,
                "top_axis": next(iter(axis_breakdown), None),
                "axis_breakdown": axis_breakdown,
                "prev_axis_breakdown": prev_axis_breakdown,
            }

    # ---- stripe events ----

    async def record_stripe_event(self, event_id: str, type_: str, payload: str) -> bool:
        async with self._engine.begin() as conn:
            try:
                async with conn.begin_nested():
                    await conn.execute(
                        insert(stripe_events).values(
                            event_id=event_id, received_at=_now_iso(), type=type_, payload=payload
                        )
                    )
                return True
            except IntegrityError:
                return False

    # ---- admin aggregates ----

    async def admin_summary_stats(self) -> dict:
        async with self._engine.begin() as conn:
            total_devices = (await conn.execute(select(func.count()).select_from(users))).scalar_one()

            stripe_pro = (
                await conn.execute(
                    select(func.count()).select_from(users).where(
                        users.c.plan == "pro", users.c.subscription_status.in_(("active", "trialing"))
                    )
                )
            ).scalar_one()

            now_iso = _now_iso()
            coupon_pro = (
                await conn.execute(
                    select(func.count()).select_from(users).where(
                        users.c.coupon_pro_expires_at.isnot(None), users.c.coupon_pro_expires_at > now_iso
                    )
                )
            ).scalar_one()

            total_redemptions = (await conn.execute(select(func.count()).select_from(coupon_redemptions))).scalar_one()

            today = _today_utc()
            rewrites_today = (
                await conn.execute(
                    select(func.coalesce(func.sum(users.c.daily_count), 0)).where(users.c.daily_day == today)
                )
            ).scalar_one()

            cutoff = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=30)).strftime("%Y-%m-%d")
            axis_rows = (
                await conn.execute(
                    select(axis_events.c.axis, func.count().label("cnt")).where(axis_events.c.ts >= cutoff)
                    .group_by(axis_events.c.axis).order_by(func.count().desc())
                )
            ).mappings().all()

            return {
                "total_devices": total_devices,
                "pro_stripe": stripe_pro,
                "pro_coupon": coupon_pro,
                "coupon_redemptions": total_redemptions,
                "rewrites_today": rewrites_today,
                "axis_stats_30d": {r["axis"]: r["cnt"] for r in axis_rows},
            }


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _row_to_user(row) -> User:
    d = dict(row)
    return User(
        device_id=d["device_id"],
        api_token=d["api_token"],
        plan=d.get("plan") or "free",
        stripe_customer_id=d.get("stripe_customer_id"),
        stripe_subscription_id=d.get("stripe_subscription_id"),
        subscription_status=d.get("subscription_status"),
        subscription_renews_at=d.get("subscription_renews_at"),
        daily_count=d.get("daily_count") or 0,
        daily_day=d.get("daily_day"),
        created_at=d.get("created_at") or "",
        updated_at=d.get("updated_at") or "",
        coupon_pro_expires_at=d.get("coupon_pro_expires_at"),
        account_id=d.get("account_id"),
    )


def _row_to_account(row) -> Account:
    d = dict(row)
    return Account(
        id=d["id"],
        apple_sub=d.get("apple_sub"),
        google_sub=d.get("google_sub"),
        email=d.get("email"),
        plan=d.get("plan") or "free",
        stripe_customer_id=d.get("stripe_customer_id"),
        stripe_subscription_id=d.get("stripe_subscription_id"),
        subscription_status=d.get("subscription_status"),
        subscription_renews_at=d.get("subscription_renews_at"),
        coupon_pro_expires_at=d.get("coupon_pro_expires_at"),
        created_at=d.get("created_at") or "",
        updated_at=d.get("updated_at") or "",
        daily_count=d.get("daily_count") or 0,
        daily_day=d.get("daily_day"),
    )


def _row_to_webauthn_credential(row) -> WebAuthnCredential:
    d = dict(row)
    raw_transports = d.get("transports")
    return WebAuthnCredential(
        credential_id=d["credential_id"],
        account_id=d["account_id"],
        public_key=bytes(d["public_key"]),
        sign_count=d.get("sign_count") or 0,
        transports=json.loads(raw_transports) if raw_transports else [],
        nickname=d.get("nickname"),
        created_at=d.get("created_at") or "",
        last_used_at=d.get("last_used_at"),
    )


def _new_token() -> str:
    import secrets
    return secrets.token_urlsafe(32)


def _now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def _today_utc() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")


# ---------------------------------------------------------------------------
# Module-level singleton
# ---------------------------------------------------------------------------


_store: Optional[Store] = None
_store_lock = threading.Lock()


def get_store() -> Store:
    global _store
    if _store is None:
        with _store_lock:
            if _store is None:
                url = normalize_database_url(
                    os.environ.get(
                        "DATABASE_URL",
                        "postgresql+asyncpg://postgres:postgres@localhost:5432/tono_dev",
                    )
                )
                _store = Store(url)
    return _store


def reset_store() -> None:
    """Drop the module-level Store singleton so the next `get_store()` call
    builds a fresh one with its own engine/connection pool.

    Does NOT dispose the old engine — the caller (FastAPI's lifespan
    shutdown handler) is responsible for `await store.close()` first. This
    exists mainly for tests, where each TestClient run gets its own event
    loop: an asyncpg pool created on one loop can't be reused on another,
    so tests must force a brand-new Store (and therefore a brand-new pool)
    per test rather than reusing the previous test's now-orphaned one.
    """
    global _store
    _store = None
