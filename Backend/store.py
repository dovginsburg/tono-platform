"""SQLite-backed user + usage store for the Tono backend.

Single source of truth for:
  - devices (one row per install; identity = `device_id` issued by the iOS app)
  - bearer tokens (long random; opaque; rotated on demand)
  - daily rewrite counter (resets at UTC midnight)
  - Stripe customer + subscription linkage
  - plan tier ("free" | "pro")
  - response cache (SHA-256 keyed, 5-min TTL)
  - axis events (which rewrite axis users tap)
  - Slack workspace installs

Why SQLite: Tono's traffic profile is < 50K devices at MVP scale. SQLite
+ WAL + a single FastAPI worker on Railway/Fly handles that for free.
We move to Postgres only when single-writer becomes a bottleneck.
"""

from __future__ import annotations

import contextlib
import datetime as dt
import json
import os
import secrets
import sqlite3
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Iterator, Optional


# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    device_id            TEXT PRIMARY KEY,
    api_token            TEXT NOT NULL UNIQUE,
    plan                 TEXT NOT NULL DEFAULT 'free',
    stripe_customer_id   TEXT,
    stripe_subscription_id TEXT,
    subscription_status  TEXT,
    subscription_renews_at TEXT,
    daily_count          INTEGER NOT NULL DEFAULT 0,
    daily_day            TEXT,
    created_at           TEXT NOT NULL,
    updated_at           TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_users_token ON users(api_token);
CREATE INDEX IF NOT EXISTS idx_users_stripe_customer ON users(stripe_customer_id);

CREATE TABLE IF NOT EXISTS usage_log (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id     TEXT NOT NULL,
    ts            TEXT NOT NULL,
    endpoint      TEXT NOT NULL,
    status_code   INTEGER NOT NULL,
    provider      TEXT,
    drafts_chars  INTEGER
);
CREATE INDEX IF NOT EXISTS idx_usage_device_ts ON usage_log(device_id, ts);

CREATE TABLE IF NOT EXISTS stripe_events (
    event_id      TEXT PRIMARY KEY,
    received_at   TEXT NOT NULL,
    type          TEXT NOT NULL,
    payload       TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS response_cache (
    cache_key     TEXT PRIMARY KEY,
    response_json TEXT NOT NULL,
    created_at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS axis_events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id  TEXT NOT NULL,
    ts         TEXT NOT NULL,
    axis       TEXT NOT NULL,
    risk_level TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_axis_ts ON axis_events(ts);

CREATE TABLE IF NOT EXISTS improvement_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id       TEXT NOT NULL,
    ts              TEXT NOT NULL,
    risk_predicted  TEXT NOT NULL,
    axis_selected   TEXT,
    mode            TEXT NOT NULL DEFAULT 'coach',
    msg_len_bucket  TEXT NOT NULL DEFAULT 'medium',
    rewrite_used    INTEGER NOT NULL DEFAULT 0,
    edit_after      INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_improvement_ts ON improvement_events(ts);
CREATE INDEX IF NOT EXISTS idx_improvement_device ON improvement_events(device_id);

CREATE TABLE IF NOT EXISTS slack_workspaces (
    team_id       TEXT PRIMARY KEY,
    access_token  TEXT NOT NULL,
    team_name     TEXT,
    bot_user_id   TEXT,
    installed_at  TEXT NOT NULL,
    updated_at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS coupons (
    code           TEXT PRIMARY KEY,
    duration_days  INTEGER NOT NULL,
    max_uses       INTEGER NOT NULL DEFAULT 0,
    use_count      INTEGER NOT NULL DEFAULT 0,
    created_at     TEXT NOT NULL,
    expires_at     TEXT
);

CREATE TABLE IF NOT EXISTS coupon_redemptions (
    device_id     TEXT NOT NULL,
    code          TEXT NOT NULL,
    redeemed_at   TEXT NOT NULL,
    PRIMARY KEY (device_id, code)
);

CREATE TABLE IF NOT EXISTS feature_flags (
    key             TEXT PRIMARY KEY,
    enabled         INTEGER NOT NULL DEFAULT 1,
    plan_required   TEXT,
    rollout_pct     INTEGER NOT NULL DEFAULT 100,
    user_controllable INTEGER NOT NULL DEFAULT 0,
    description     TEXT,
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE IF NOT EXISTS user_feature_overrides (
    device_id   TEXT NOT NULL,
    flag_key    TEXT NOT NULL,
    enabled     INTEGER NOT NULL,
    set_by      TEXT NOT NULL DEFAULT 'user',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (device_id, flag_key)
);
"""

_DEFAULT_FLAGS = [
    # (key, enabled, plan_required, rollout_pct, user_controllable, description)
    ("onboarding_calibration", 1, None, 100, 0, "First-run 3-question calibration flow"),
    ("thread_context",         1, None, 100, 1, "Paste prior message for context-aware rewrites"),
    ("weekly_digest",          1, None, 100, 1, "Weekly tone summary notification and report"),
    ("custom_axes",            1, "pro", 100, 0, "User-defined rewrite dimensions (Pro only)"),
    ("risk_delta",             1, None, 100, 1, "Show predicted risk change per rewrite suggestion"),
    ("memory_inference",       1, None, 100, 1, "Auto-infer facts from usage patterns (privacy)"),
    ("memory_context_hints",   1, None, 100, 1, "Send memory facts as LLM context hints (privacy)"),
    # Collective improvement signal — content-free behavioral outcomes only.
    # k-anonymity floor (COLLECTIVE_MIN_DEVICES) enforced at aggregation query level.
    ("improve_tono",           1, None, 100, 1, "Share anonymous outcome signals to improve Tono for everyone"),
]


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

    @property
    def is_pro(self) -> bool:
        if self.plan == "pro" and self.subscription_status in ("active", "trialing"):
            return True
        if self.coupon_pro_expires_at:
            try:
                exp = dt.datetime.fromisoformat(self.coupon_pro_expires_at)
                if exp > dt.datetime.now(dt.timezone.utc):
                    return True
            except ValueError:
                pass
        return False


# ---------------------------------------------------------------------------
# Store
# ---------------------------------------------------------------------------


class Store:
    def __init__(self, path: str):
        self.path = path
        self._conn = sqlite3.connect(
            path,
            check_same_thread=False,
            isolation_level=None,
            timeout=10.0,
        )
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA foreign_keys=ON")
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="db")
        self._closed = False
        self._init_schema()

    # ---- lifecycle ----

    def _init_schema(self) -> None:
        with contextlib.closing(self._conn.cursor()) as c:
            c.executescript(SCHEMA)
        for stmt in (
            "ALTER TABLE users ADD COLUMN stripe_customer_id TEXT",
            "ALTER TABLE users ADD COLUMN stripe_subscription_id TEXT",
            "ALTER TABLE users ADD COLUMN subscription_status TEXT",
            "ALTER TABLE users ADD COLUMN subscription_renews_at TEXT",
            "ALTER TABLE users ADD COLUMN coupon_pro_expires_at TEXT",
        ):
            with contextlib.suppress(sqlite3.OperationalError):
                self._conn.execute(stmt)
        self._seed_feature_flags()

    def _seed_feature_flags(self) -> None:
        cur = self._conn.cursor()
        for key, enabled, plan_required, rollout_pct, user_controllable, description in _DEFAULT_FLAGS:
            cur.execute(
                """INSERT OR IGNORE INTO feature_flags
                   (key, enabled, plan_required, rollout_pct, user_controllable, description)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (key, enabled, plan_required, rollout_pct, user_controllable, description),
            )

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        with contextlib.suppress(Exception):
            self._executor.shutdown(wait=False)
        with contextlib.suppress(Exception):
            self._conn.close()

    def _ensure_open(self) -> None:
        if self._closed or self._conn is None:
            self._conn = sqlite3.connect(
                self.path,
                check_same_thread=False,
                isolation_level=None,
                timeout=10.0,
            )
            self._conn.row_factory = sqlite3.Row
            self._conn.execute("PRAGMA journal_mode=WAL")
            self._conn.execute("PRAGMA foreign_keys=ON")
            self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="db")
            self._init_schema()
            self._closed = False

    def _ensure_executor(self) -> None:
        self._ensure_open()
        if self._executor is None or getattr(self._executor, "_shutdown", False):
            self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="db")

    def _run(self, fn, /, *args, **kwargs):
        def wrapper():
            try:
                return fn(*args, **kwargs)
            except Exception:
                with contextlib.suppress(sqlite3.Error):
                    self._conn.execute("ROLLBACK")
                raise

        self._ensure_executor()
        return self._executor.submit(wrapper)

    # ---- user / device ----

    def register_device(self, device_id: Optional[str] = None) -> User:
        now = _now_iso()

        def _do() -> User:
            cur = self._conn.cursor()
            if device_id:
                cur.execute("SELECT * FROM users WHERE device_id = ?", (device_id,))
                row = cur.fetchone()
                if row:
                    if not row["api_token"]:
                        token = _new_token()
                        cur.execute(
                            "UPDATE users SET api_token=?, updated_at=? WHERE device_id=?",
                            (token, now, device_id),
                        )
                        return _row_to_user({**dict(row), "api_token": token, "updated_at": now})
                    return _row_to_user(row)
            did = device_id or str(uuid.uuid4())
            token = _new_token()
            cur.execute(
                "INSERT INTO users (device_id, api_token, plan, created_at, updated_at) VALUES (?, ?, 'free', ?, ?)",
                (did, token, now, now),
            )
            cur.execute("SELECT * FROM users WHERE device_id = ?", (did,))
            return _row_to_user(cur.fetchone())

        return self._run(_do).result()

    def get_by_token(self, token: str) -> Optional[User]:
        def _do() -> Optional[User]:
            cur = self._conn.cursor()
            cur.execute("SELECT * FROM users WHERE api_token = ?", (token,))
            row = cur.fetchone()
            return _row_to_user(row) if row else None

        return self._run(_do).result()

    def get_by_device(self, device_id: str) -> Optional[User]:
        def _do() -> Optional[User]:
            cur = self._conn.cursor()
            cur.execute("SELECT * FROM users WHERE device_id = ?", (device_id,))
            row = cur.fetchone()
            return _row_to_user(row) if row else None

        return self._run(_do).result()

    def rotate_token(self, device_id: str) -> Optional[str]:
        def _do() -> Optional[str]:
            cur = self._conn.cursor()
            token = _new_token()
            cur.execute(
                "UPDATE users SET api_token=?, updated_at=? WHERE device_id=?",
                (token, _now_iso(), device_id),
            )
            return token if cur.rowcount else None

        return self._run(_do).result()

    def attach_stripe_customer(self, device_id: str, customer_id: str) -> None:
        def _do() -> None:
            self._conn.execute(
                "UPDATE users SET stripe_customer_id=?, updated_at=? WHERE device_id=?",
                (customer_id, _now_iso(), device_id),
            )

        self._run(_do).result()

    def update_subscription(
        self,
        *,
        device_id: Optional[str] = None,
        customer_id: Optional[str] = None,
        subscription_id: Optional[str],
        status: Optional[str],
        renews_at: Optional[str],
    ) -> None:
        assert device_id or customer_id, "need device_id or customer_id"

        def _do() -> None:
            cur = self._conn.cursor()
            where = "device_id = ?" if device_id else "stripe_customer_id = ?"
            arg = device_id or customer_id
            plan = "pro" if status in ("active", "trialing") else "free"
            cur.execute(
                f"""
                UPDATE users
                   SET plan = ?,
                       stripe_subscription_id = ?,
                       subscription_status = ?,
                       subscription_renews_at = ?,
                       updated_at = ?
                 WHERE {where}
                """,
                (plan, subscription_id, status, renews_at, _now_iso(), arg),
            )

        self._run(_do).result()

    # ---- rate limit ----

    def consume_rewrite(self, device_id: str) -> tuple[bool, int, int]:
        def _do() -> tuple[bool, int, int]:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT plan, subscription_status, coupon_pro_expires_at, daily_count, daily_day FROM users WHERE device_id = ?",
                (device_id,),
            )
            row = cur.fetchone()
            if not row:
                return (False, 0, 0)
            if row["plan"] == "pro" and row["subscription_status"] in ("active", "trialing"):
                return (True, row["daily_count"], -1)
            if row["coupon_pro_expires_at"] and row["coupon_pro_expires_at"] > _now_iso():
                return (True, row["daily_count"], -1)
            today = _today_utc()
            used = row["daily_count"] if row["daily_day"] == today else 0
            limit = int(os.environ.get("FREE_DAILY_LIMIT", "10"))
            if used >= limit:
                return (False, used, limit)
            cur.execute("BEGIN IMMEDIATE")
            try:
                if row["daily_day"] != today:
                    cur.execute(
                        "UPDATE users SET daily_count=1, daily_day=?, updated_at=? WHERE device_id=?",
                        (today, _now_iso(), device_id),
                    )
                    used = 1
                else:
                    cur.execute(
                        "UPDATE users SET daily_count=daily_count+1, updated_at=? WHERE device_id=?",
                        (_now_iso(), device_id),
                    )
                    used += 1
                cur.execute("COMMIT")
            except Exception:
                cur.execute("ROLLBACK")
                raise
            return (True, used, limit)

        return self._run(_do).result()

    # ---- response cache ----

    def get_cached_response(self, cache_key: str, ttl_seconds: int = 300) -> Optional[dict]:
        def _do() -> Optional[dict]:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT response_json, created_at FROM response_cache WHERE cache_key = ?",
                (cache_key,),
            )
            row = cur.fetchone()
            if not row:
                return None
            age = (dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(row["created_at"])).total_seconds()
            if age > ttl_seconds:
                cur.execute("DELETE FROM response_cache WHERE cache_key = ?", (cache_key,))
                return None
            return json.loads(row["response_json"])

        return self._run(_do).result()

    def set_cached_response(self, cache_key: str, response: dict) -> None:
        def _do() -> None:
            self._conn.execute(
                "INSERT OR REPLACE INTO response_cache (cache_key, response_json, created_at) VALUES (?, ?, ?)",
                (cache_key, json.dumps(response), _now_iso()),
            )

        self._executor.submit(_do)

    def purge_expired_cache(self, ttl_seconds: int = 300) -> None:
        def _do() -> None:
            cutoff = (
                dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=ttl_seconds)
            ).isoformat(timespec="seconds")
            self._conn.execute(
                "DELETE FROM response_cache WHERE created_at < ?", (cutoff,)
            )

        self._executor.submit(_do)

    # ---- axis events ----

    def log_axis_event(self, device_id: str, axis: str, risk_level: str) -> None:
        def _do() -> None:
            self._conn.execute(
                "INSERT INTO axis_events (device_id, ts, axis, risk_level) VALUES (?, ?, ?, ?)",
                (device_id, _now_iso(), axis, risk_level),
            )

        self._executor.submit(_do)

    def axis_stats(self, days: int = 30) -> dict:
        """Aggregate axis tap counts for the last N days."""
        def _do() -> dict:
            cutoff = (
                dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)
            ).strftime("%Y-%m-%d")
            cur = self._conn.cursor()
            cur.execute(
                "SELECT axis, COUNT(*) as cnt FROM axis_events WHERE ts >= ? GROUP BY axis ORDER BY cnt DESC",
                (cutoff,),
            )
            return {row["axis"]: row["cnt"] for row in cur.fetchall()}

        return self._run(_do).result()

    def axis_stats_by_risk(self, days: int = 30) -> dict:
        """Axis tap counts broken down by risk level for the last N days.

        Returns ``{risk_level: {axis: count}}``. Used to understand which
        axes resonate when messages are high-risk vs low-risk — feeds into
        prompt ordering when no per-user preference exists.
        """
        def _do() -> dict:
            cutoff = (
                dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)
            ).strftime("%Y-%m-%d")
            cur = self._conn.cursor()
            cur.execute(
                """SELECT risk_level, axis, COUNT(*) as cnt
                   FROM axis_events WHERE ts >= ?
                   GROUP BY risk_level, axis
                   ORDER BY risk_level, cnt DESC""",
                (cutoff,),
            )
            result: dict = {}
            for row in cur.fetchall():
                rl = row["risk_level"]
                if rl not in result:
                    result[rl] = {}
                result[rl][row["axis"]] = row["cnt"]
            return result

        return self._run(_do).result()

    def global_axis_ranking(self, days: int = 30) -> list:
        """Return all four axes sorted by global win count (most-chosen first).

        Used as the collective-intelligence default when a client has no
        per-user StyleMemory preference yet. Falls back to the canonical
        default order when the DB has no axis events.
        """
        _default = ["warmer", "clearer", "funnier", "safer"]
        stats = self.axis_stats(days=days)
        if not stats:
            return _default
        return sorted(_default, key=lambda a: stats.get(a, 0), reverse=True)

    # ---- collective improvement events ----

    def log_improvement_event(
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
        def _do() -> None:
            self._conn.execute(
                """INSERT INTO improvement_events
                   (device_id, ts, risk_predicted, axis_selected, mode,
                    msg_len_bucket, rewrite_used, edit_after)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    device_id, _now_iso(), risk_predicted, axis_selected, mode,
                    msg_len_bucket, int(rewrite_used), int(edit_after),
                ),
            )
        self._executor.submit(_do)

    def get_axis_effectiveness(
        self,
        days: int = 30,
        min_devices: int = 50,
    ) -> dict:
        """Axis win rates by risk level.

        k-anonymity: only returns patterns backed by >= min_devices distinct
        devices. This is enforced at the SQL level with HAVING, not by
        convention — a pattern with fewer contributors is discarded entirely.

        Returns ``{risk_level: [{axis, events, distinct_devices}, ...]}``.
        """
        def _do() -> dict:
            cutoff = (
                dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)
            ).strftime("%Y-%m-%d")
            cur = self._conn.cursor()
            cur.execute(
                """SELECT risk_predicted, axis_selected,
                          COUNT(*) AS event_count,
                          COUNT(DISTINCT device_id) AS device_count
                   FROM improvement_events
                   WHERE ts >= ? AND rewrite_used = 1 AND axis_selected IS NOT NULL
                   GROUP BY risk_predicted, axis_selected
                   HAVING COUNT(DISTINCT device_id) >= ?
                   ORDER BY risk_predicted, event_count DESC""",
                (cutoff, min_devices),
            )
            result: dict = {}
            for row in cur.fetchall():
                rp = row["risk_predicted"]
                if rp not in result:
                    result[rp] = []
                result[rp].append({
                    "axis": row["axis_selected"],
                    "events": row["event_count"],
                    "distinct_devices": row["device_count"],
                })
            return result
        return self._run(_do).result()

    def get_rewrite_quality(
        self,
        days: int = 30,
        min_devices: int = 50,
    ) -> dict:
        """Edit-after-insert rate by axis — a proxy for rewrite quality.

        High edit_after_rate = users are choosing the axis but rewriting the
        suggestion, meaning the rewrite is close-but-wrong. Feed this into
        prompt revision for those axes.

        k-anonymity: same HAVING floor as get_axis_effectiveness.

        Returns ``{axis: {total_insertions, edit_after_count, edit_after_rate,
        distinct_devices}}``.
        """
        def _do() -> dict:
            cutoff = (
                dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)
            ).strftime("%Y-%m-%d")
            cur = self._conn.cursor()
            cur.execute(
                """SELECT axis_selected,
                          COUNT(*) AS total,
                          SUM(edit_after) AS edits,
                          COUNT(DISTINCT device_id) AS device_count
                   FROM improvement_events
                   WHERE ts >= ? AND rewrite_used = 1 AND axis_selected IS NOT NULL
                   GROUP BY axis_selected
                   HAVING COUNT(DISTINCT device_id) >= ?
                   ORDER BY axis_selected""",
                (cutoff, min_devices),
            )
            result: dict = {}
            for row in cur.fetchall():
                total = row["total"]
                edits = row["edits"] or 0
                result[row["axis_selected"]] = {
                    "total_insertions": total,
                    "edit_after_count": edits,
                    "edit_after_rate": round(edits / total, 3) if total > 0 else 0.0,
                    "distinct_devices": row["device_count"],
                }
            return result
        return self._run(_do).result()

    def age_out_improvement_events(self, retain_days: int = 90) -> int:
        """Delete improvement_events older than retain_days. Returns count deleted.

        Raw events are kept only long enough to compute rolling aggregates;
        after that they are discarded. Call periodically (e.g. nightly).
        """
        def _do() -> int:
            cutoff = (
                dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=retain_days)
            ).strftime("%Y-%m-%d")
            cur = self._conn.cursor()
            cur.execute(
                "DELETE FROM improvement_events WHERE ts < ?", (cutoff,)
            )
            return cur.rowcount
        return self._run(_do).result()

    # ---- Slack ----

    def upsert_slack_workspace(
        self, team_id: str, access_token: str, team_name: str, bot_user_id: str
    ) -> None:
        now = _now_iso()
        def _do() -> None:
            self._conn.execute(
                """
                INSERT INTO slack_workspaces (team_id, access_token, team_name, bot_user_id, installed_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(team_id) DO UPDATE SET
                    access_token = excluded.access_token,
                    team_name    = excluded.team_name,
                    bot_user_id  = excluded.bot_user_id,
                    updated_at   = excluded.updated_at
                """,
                (team_id, access_token, team_name, bot_user_id, now, now),
            )

        self._run(_do).result()

    # ---- coupons ----

    def redeem_coupon(self, device_id: str, code: str) -> str:
        """Redeem a coupon code for the given device. Returns the new
        coupon_pro_expires_at ISO string on success.
        Raises ValueError with a user-visible message on failure."""
        def _do() -> str:
            now = _now_iso()
            cur = self._conn.cursor()
            cur.execute("SELECT * FROM coupons WHERE code = ?", (code,))
            row = cur.fetchone()
            if not row:
                raise ValueError("Invalid code.")
            if row["expires_at"] and row["expires_at"] < now:
                raise ValueError("This code has expired.")
            if row["max_uses"] > 0 and row["use_count"] >= row["max_uses"]:
                raise ValueError("This code has reached its usage limit.")
            cur.execute(
                "SELECT 1 FROM coupon_redemptions WHERE device_id = ? AND code = ?",
                (device_id, code),
            )
            if cur.fetchone():
                raise ValueError("You've already redeemed this code.")
            expires_at = (
                dt.datetime.now(dt.timezone.utc)
                + dt.timedelta(days=int(row["duration_days"]))
            ).isoformat(timespec="seconds")
            cur.execute("BEGIN IMMEDIATE")
            try:
                cur.execute(
                    "INSERT INTO coupon_redemptions (device_id, code, redeemed_at) VALUES (?, ?, ?)",
                    (device_id, code, now),
                )
                cur.execute(
                    "UPDATE coupons SET use_count = use_count + 1 WHERE code = ?",
                    (code,),
                )
                cur.execute(
                    "UPDATE users SET coupon_pro_expires_at = ?, updated_at = ? WHERE device_id = ?",
                    (expires_at, now, device_id),
                )
                cur.execute("COMMIT")
            except Exception:
                cur.execute("ROLLBACK")
                raise
            return expires_at

        return self._run(_do).result()

    def create_coupon(
        self,
        code: str,
        duration_days: int,
        max_uses: int = 0,
        expires_at: Optional[str] = None,
    ) -> bool:
        """Insert a new coupon. Returns False if the code already exists."""
        def _do() -> bool:
            cur = self._conn.cursor()
            try:
                cur.execute(
                    """
                    INSERT INTO coupons (code, duration_days, max_uses, use_count, created_at, expires_at)
                    VALUES (?, ?, ?, 0, ?, ?)
                    """,
                    (code, duration_days, max_uses, _now_iso(), expires_at),
                )
                return True
            except sqlite3.IntegrityError:
                return False

        return self._run(_do).result()

    def get_slack_workspace(self, team_id: str) -> Optional[dict]:
        def _do() -> Optional[dict]:
            cur = self._conn.cursor()
            cur.execute("SELECT * FROM slack_workspaces WHERE team_id = ?", (team_id,))
            row = cur.fetchone()
            return dict(row) if row else None

        return self._run(_do).result()

    # ---- audit ----

    def log_usage(
        self,
        device_id: str,
        endpoint: str,
        status_code: int,
        provider: Optional[str] = None,
        drafts_chars: Optional[int] = None,
    ) -> None:
        def _do() -> None:
            self._conn.execute(
                "INSERT INTO usage_log (device_id, ts, endpoint, status_code, provider, drafts_chars) VALUES (?, ?, ?, ?, ?, ?)",
                (device_id, _now_iso(), endpoint, status_code, provider, drafts_chars),
            )

        self._executor.submit(_do)

    # ---- feature flags ----

    def get_features(self, device_id: str, is_pro: bool) -> dict[str, bool]:
        """Resolve flags for a device: global default → plan gate → user override."""
        def _do() -> dict[str, bool]:
            cur = self._conn.cursor()
            cur.execute("SELECT key, enabled, plan_required FROM feature_flags")
            flags = {row["key"]: {"enabled": bool(row["enabled"]), "plan": row["plan_required"]}
                     for row in cur.fetchall()}
            cur.execute(
                "SELECT flag_key, enabled FROM user_feature_overrides WHERE device_id = ?",
                (device_id,),
            )
            overrides = {row["flag_key"]: bool(row["enabled"]) for row in cur.fetchall()}
            result: dict[str, bool] = {}
            for key, meta in flags.items():
                if meta["plan"] == "pro" and not is_pro:
                    result[key] = False
                    continue
                result[key] = overrides.get(key, meta["enabled"])
            return result

        return self._run(_do).result()

    def get_all_flags(self) -> list[dict]:
        def _do() -> list[dict]:
            cur = self._conn.cursor()
            cur.execute("SELECT * FROM feature_flags ORDER BY key")
            return [dict(row) for row in cur.fetchall()]

        return self._run(_do).result()

    def update_flag(
        self,
        key: str,
        enabled: Optional[bool] = None,
        plan_required: Optional[str] = "UNCHANGED",
        rollout_pct: Optional[int] = None,
    ) -> bool:
        def _do() -> bool:
            sets, params = [], []
            if enabled is not None:
                sets.append("enabled = ?")
                params.append(int(enabled))
            if plan_required != "UNCHANGED":
                sets.append("plan_required = ?")
                params.append(plan_required)
            if rollout_pct is not None:
                sets.append("rollout_pct = ?")
                params.append(rollout_pct)
            if not sets:
                return True
            sets.append("updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')")
            params.append(key)
            cur = self._conn.cursor()
            cur.execute(f"UPDATE feature_flags SET {', '.join(sets)} WHERE key = ?", params)
            return cur.rowcount > 0

        return self._run(_do).result()

    def set_user_flag_override(
        self, device_id: str, flag_key: str, enabled: bool, set_by: str = "admin"
    ) -> None:
        def _do() -> None:
            self._conn.execute(
                """INSERT OR REPLACE INTO user_feature_overrides
                   (device_id, flag_key, enabled, set_by)
                   VALUES (?, ?, ?, ?)""",
                (device_id, flag_key, int(enabled), set_by),
            )

        self._run(_do).result()

    def delete_user_flag_override(self, device_id: str, flag_key: str) -> None:
        def _do() -> None:
            self._conn.execute(
                "DELETE FROM user_feature_overrides WHERE device_id = ? AND flag_key = ?",
                (device_id, flag_key),
            )

        self._run(_do).result()

    def get_weekly_digest(self, device_id: str) -> dict:
        def _do() -> dict:
            cur = self._conn.cursor()
            now = dt.datetime.now(dt.timezone.utc)
            cutoff      = (now - dt.timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")
            prev_cutoff = (now - dt.timedelta(days=14)).strftime("%Y-%m-%dT%H:%M:%SZ")

            cur.execute(
                "SELECT COUNT(*) as cnt FROM axis_events WHERE device_id = ? AND ts >= ?",
                (device_id, cutoff),
            )
            total = cur.fetchone()["cnt"]

            cur.execute(
                """SELECT axis, COUNT(*) as cnt
                   FROM axis_events WHERE device_id = ? AND ts >= ?
                   GROUP BY axis ORDER BY cnt DESC""",
                (device_id, cutoff),
            )
            axis_breakdown = {row["axis"]: row["cnt"] for row in cur.fetchall()}

            cur.execute(
                """SELECT axis, COUNT(*) as cnt
                   FROM axis_events WHERE device_id = ? AND ts >= ? AND ts < ?
                   GROUP BY axis ORDER BY cnt DESC""",
                (device_id, prev_cutoff, cutoff),
            )
            prev_axis_breakdown = {row["axis"]: row["cnt"] for row in cur.fetchall()}

            cur.execute(
                """SELECT COUNT(DISTINCT DATE(ts)) as days
                   FROM axis_events WHERE device_id = ? AND ts >= ?""",
                (device_id, cutoff),
            )
            days_active = cur.fetchone()["days"]

            return {
                "period_days": 7,
                "rewrites": total,
                "days_active": days_active,
                "top_axis": next(iter(axis_breakdown), None),
                "axis_breakdown": axis_breakdown,
                "prev_axis_breakdown": prev_axis_breakdown,
            }

        return self._run(_do).result()

    # ---- stripe events ----

    def record_stripe_event(self, event_id: str, type_: str, payload: str) -> bool:
        def _do() -> bool:
            cur = self._conn.cursor()
            try:
                cur.execute(
                    "INSERT INTO stripe_events (event_id, received_at, type, payload) VALUES (?, ?, ?, ?)",
                    (event_id, _now_iso(), type_, payload),
                )
                return True
            except sqlite3.IntegrityError:
                return False

        return self._run(_do).result()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _row_to_user(row: sqlite3.Row | dict) -> User:
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
    )


def _new_token() -> str:
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
                path = os.environ.get("TONO_DB_PATH", "./tono.db")
                _store = Store(path)
    return _store


def reset_store() -> None:
    global _store
    if _store is not None:
        with contextlib.suppress(Exception):
            _store.close()
    _store = None
