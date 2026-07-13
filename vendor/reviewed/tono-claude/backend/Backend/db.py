"""SQLAlchemy Core table definitions for the Tono backend's Postgres schema.

Kept as plain Core `Table` objects (not the declarative ORM) because the
store layer's queries were ported near-verbatim from the previous
hand-written SQL — Core's `select()`/`insert()`/`update()` constructs map
onto that shape directly, without introducing an ORM identity map that the
original code never assumed.

Timestamps are kept as ISO-8601 strings (not native TIMESTAMPTZ) to
minimize behavior change in this migration — every existing comparison
(``ts >= cutoff``) relies on ISO-8601's lexicographic-equals-chronological
ordering, which still holds. A native timestamp column is a reasonable
follow-up, not done here to keep this migration's diff reviewable.
"""

from __future__ import annotations

from sqlalchemy import (
    BigInteger,
    Boolean,
    Column,
    ForeignKey,
    Index,
    Integer,
    LargeBinary,
    MetaData,
    String,
    Table,
    Text,
)

metadata = MetaData()

users = Table(
    "users",
    metadata,
    Column("device_id", String, primary_key=True),
    Column("api_token", String, nullable=False, unique=True),
    Column("plan", String, nullable=False, server_default="free"),
    Column("stripe_customer_id", String),
    Column("stripe_subscription_id", String),
    Column("subscription_status", String),
    Column("subscription_renews_at", String),
    Column("daily_count", Integer, nullable=False, server_default="0"),
    Column("daily_day", String),
    Column("created_at", String, nullable=False),
    Column("updated_at", String, nullable=False),
    Column("coupon_pro_expires_at", String),
    Column("account_id", String, ForeignKey("accounts.id")),
)
Index("idx_users_token", users.c.api_token)
Index("idx_users_stripe_customer", users.c.stripe_customer_id)

# A device (row in `users` above) is anonymous by default. Signing in with
# Apple/Google upserts a row here and sets `users.account_id`, so Pro status
# and identity travel with the person rather than the install. Plan/
# subscription fields are duplicated from `users` deliberately: once an
# account exists it is the source of truth for billing, and `users` keeps
# its own copy only for the anonymous (never-signed-in) case.
accounts = Table(
    "accounts",
    metadata,
    Column("id", String, primary_key=True),
    Column("apple_sub", String, unique=True),
    Column("google_sub", String, unique=True),
    Column("email", String),
    Column("plan", String, nullable=False, server_default="free"),
    Column("stripe_customer_id", String),
    Column("stripe_subscription_id", String),
    Column("subscription_status", String),
    Column("subscription_renews_at", String),
    Column("coupon_pro_expires_at", String),
    # Free-tier daily allowance, pooled across every device linked to this
    # account — see Store.consume_rewrite. Same shape as
    # users.daily_count/daily_day, deliberately: a device with no
    # account_id still counts against ITS OWN columns of the same name on
    # `users`.
    Column("daily_count", Integer, nullable=False, server_default="0"),
    Column("daily_day", String),
    Column("created_at", String, nullable=False),
    Column("updated_at", String, nullable=False),
)
Index("idx_accounts_apple_sub", accounts.c.apple_sub)
Index("idx_accounts_google_sub", accounts.c.google_sub)
Index("idx_accounts_stripe_customer", accounts.c.stripe_customer_id)

# A passkey (WebAuthn credential) is what makes Face ID / Touch ID /
# Windows Hello / Android biometric unlock work as a *login* method on web
# and desktop: the browser/OS handles the biometric prompt and only ever
# gives us back a signed assertion, never the biometric itself.
# credential_id is base64url-encoded (WebAuthn's own encoding), so it's a
# string despite being derived from bytes.
webauthn_credentials = Table(
    "webauthn_credentials",
    metadata,
    Column("credential_id", String, primary_key=True),
    Column("account_id", String, ForeignKey("accounts.id"), nullable=False),
    Column("public_key", LargeBinary, nullable=False),
    Column("sign_count", Integer, nullable=False, server_default="0"),
    Column("transports", Text),
    Column("nickname", String),
    Column("created_at", String, nullable=False),
    Column("last_used_at", String),
)
Index("idx_webauthn_account", webauthn_credentials.c.account_id)

usage_log = Table(
    "usage_log",
    metadata,
    Column("id", BigInteger, primary_key=True, autoincrement=True),
    Column("device_id", String, nullable=False),
    Column("ts", String, nullable=False),
    Column("endpoint", String, nullable=False),
    Column("status_code", Integer, nullable=False),
    Column("provider", String),
    Column("drafts_chars", Integer),
)
Index("idx_usage_device_ts", usage_log.c.device_id, usage_log.c.ts)

stripe_events = Table(
    "stripe_events",
    metadata,
    Column("event_id", String, primary_key=True),
    Column("received_at", String, nullable=False),
    Column("type", String, nullable=False),
    Column("payload", Text, nullable=False),
)

response_cache = Table(
    "response_cache",
    metadata,
    Column("cache_key", String, primary_key=True),
    Column("response_json", Text, nullable=False),
    Column("created_at", String, nullable=False),
)

axis_events = Table(
    "axis_events",
    metadata,
    Column("id", BigInteger, primary_key=True, autoincrement=True),
    Column("device_id", String, nullable=False),
    Column("ts", String, nullable=False),
    Column("axis", String, nullable=False),
    Column("risk_level", String, nullable=False),
)
Index("idx_axis_ts", axis_events.c.ts)

improvement_events = Table(
    "improvement_events",
    metadata,
    Column("id", BigInteger, primary_key=True, autoincrement=True),
    Column("device_id", String, nullable=False),
    Column("ts", String, nullable=False),
    Column("risk_predicted", String, nullable=False),
    Column("axis_selected", String),
    Column("mode", String, nullable=False, server_default="coach"),
    Column("msg_len_bucket", String, nullable=False, server_default="medium"),
    Column("rewrite_used", Boolean, nullable=False, server_default="false"),
    Column("edit_after", Boolean, nullable=False, server_default="false"),
)
Index("idx_improvement_ts", improvement_events.c.ts)
Index("idx_improvement_device", improvement_events.c.device_id)

slack_workspaces = Table(
    "slack_workspaces",
    metadata,
    Column("team_id", String, primary_key=True),
    Column("access_token", String, nullable=False),
    Column("team_name", String),
    Column("bot_user_id", String),
    Column("installed_at", String, nullable=False),
    Column("updated_at", String, nullable=False),
)

coupons = Table(
    "coupons",
    metadata,
    Column("code", String, primary_key=True),
    Column("duration_days", Integer, nullable=False),
    Column("max_uses", Integer, nullable=False, server_default="0"),
    Column("use_count", Integer, nullable=False, server_default="0"),
    Column("created_at", String, nullable=False),
    Column("expires_at", String),
)

coupon_redemptions = Table(
    "coupon_redemptions",
    metadata,
    Column("device_id", String, primary_key=True),
    Column("code", String, primary_key=True),
    Column("redeemed_at", String, nullable=False),
)

feature_flags = Table(
    "feature_flags",
    metadata,
    Column("key", String, primary_key=True),
    Column("enabled", Boolean, nullable=False, server_default="true"),
    Column("plan_required", String),
    Column("rollout_pct", Integer, nullable=False, server_default="100"),
    Column("user_controllable", Boolean, nullable=False, server_default="false"),
    Column("description", String),
    Column("updated_at", String),
)

user_feature_overrides = Table(
    "user_feature_overrides",
    metadata,
    Column("device_id", String, primary_key=True),
    Column("flag_key", String, primary_key=True),
    Column("enabled", Boolean, nullable=False),
    Column("set_by", String, nullable=False, server_default="user"),
    Column("created_at", String),
)

DEFAULT_FLAGS = [
    # (key, enabled, plan_required, rollout_pct, user_controllable, description)
    ("onboarding_calibration", True, None, 100, False, "First-run 3-question calibration flow"),
    ("thread_context", True, None, 100, True, "Paste prior message for context-aware rewrites"),
    ("weekly_digest", True, None, 100, True, "Weekly tone summary notification and report"),
    ("custom_axes", True, "pro", 100, False, "User-defined rewrite dimensions (Pro only)"),
    ("risk_delta", True, None, 100, True, "Show predicted risk change per rewrite suggestion"),
    ("memory_inference", True, None, 100, True, "Auto-infer facts from usage patterns (privacy)"),
    ("memory_context_hints", True, None, 100, True, "Send memory facts as LLM context hints (privacy)"),
    # Collective improvement signal — content-free behavioral outcomes only.
    # k-anonymity floor (COLLECTIVE_MIN_DEVICES) enforced at aggregation query level.
    ("improve_tono", True, None, 100, True, "Share anonymous outcome signals to improve Tono for everyone"),
]
