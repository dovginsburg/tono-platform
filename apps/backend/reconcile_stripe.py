"""Stripe reconciliation tool — heals missed/failed webhooks idempotently.

Fetches current Stripe truth for every subscription stored in our DB and
applies it through the same ``apply_stripe_subscription_fact`` path the
webhook uses, so all version-ordering and resurrection guards apply.

Usage (production):
    STRIPE_SECRET_KEY=sk_live_... TONO_DB_PATH=/data/tono.db \
    python -m backend.reconcile_stripe [--dry-run] [--limit N]

Production schedule (Railway cron or similar):
    0 4 * * *   # 04:00 UTC daily

Rollback:
    Makes NO Stripe API mutations (read-only Stripe calls).
    DB changes are idempotent reapplications of current-truth data;
    running again after an aborted run is always safe.

Environment variables:
    STRIPE_SECRET_KEY        required — Stripe secret key (sk_live_... or sk_test_...)
    TONO_DB_PATH             required — path to the SQLite database
    STRIPE_RECONCILE_LIMIT   optional — max subscriptions per run (default 500)

Exit codes:
    0  — all processed successfully (or dry-run)
    1  — one or more subscriptions could not be fetched/applied (check stderr)
"""
from __future__ import annotations

import argparse
import datetime as dt
import logging
import os
import sys

from backend.store import Store  # module-level so tests can monkeypatch reconciler.Store

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
logger = logging.getLogger(__name__)


def main() -> None:
    parser = argparse.ArgumentParser(description="Tono Stripe reconciliation")
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Fetch Stripe state and report diffs; make no DB changes",
    )
    parser.add_argument(
        "--limit", type=int,
        default=int(os.environ.get("STRIPE_RECONCILE_LIMIT", "500")),
        help="Max subscriptions to process per run",
    )
    args = parser.parse_args()

    import stripe  # noqa: PLC0415 — defer import so missing package fails clearly

    secret = os.environ.get("STRIPE_SECRET_KEY")
    if not secret:
        logger.error("STRIPE_SECRET_KEY is not set — aborting")
        sys.exit(1)
    stripe.api_key = secret

    db_path = os.environ.get("TONO_DB_PATH", "./tono.db")
    if not os.path.exists(db_path):
        logger.error("DB not found at %s — aborting", db_path)
        sys.exit(1)

    store = Store(db_path)
    healed = 0
    already_ok = 0
    skipped = 0
    dead_letters: list[tuple[str, str]] = []
    processed = 0

    logger.info(
        "Starting Stripe reconciliation (dry_run=%s, limit=%d)", args.dry_run, args.limit
    )
    accounts = store.list_accounts_with_stripe_subscriptions()
    invariant_failures = store.stripe_trial_invariants()
    if invariant_failures:
        for failure in invariant_failures:
            logger.error("Stripe trial invariant violation: %s", failure)
        store.close()
        sys.exit(1)
    logger.info("Found %d account-level Stripe subscriptions to check", len(accounts))

    for row in accounts:
        if processed >= args.limit:
            logger.info("Reached processing limit of %d — stopping", args.limit)
            break
        processed += 1

        sub_id: str = row["stripe_subscription_id"]
        account_id: str = row["id"]
        customer_id: str | None = row["stripe_customer_id"]
        db_status: str | None = row["subscription_status"]

        try:
            sub = stripe.Subscription.retrieve(sub_id)
        except stripe.error.InvalidRequestError as exc:
            if "No such subscription" in str(exc):
                logger.warning(
                    "Subscription %s no longer exists (account=%s) — will mark expired",
                    sub_id, account_id,
                )
                if not args.dry_run:
                    store.apply_stripe_terminal_fact(
                        subscription_id=sub_id,
                        account_id=account_id,
                        lifecycle_state="expired",
                    )
                    store.update_account_subscription(
                        account_id=account_id,
                        customer_id=customer_id,
                        subscription_id=None,
                        status="canceled",
                        renews_at=None,
                    )
                healed += 1
            else:
                logger.error("Stripe error for sub=%s account=%s: %s", sub_id, account_id, exc)
                dead_letters.append((sub_id, str(exc)))
            continue
        except Exception as exc:
            logger.error("Unexpected error for sub=%s: %s", sub_id, exc)
            dead_letters.append((sub_id, str(exc)))
            continue

        stripe_status: str = sub.get("status") or "unknown"
        period_end: int | None = sub.get("current_period_end")
        period_end_ms = int(period_end) * 1000 if period_end else None

        items = (sub.get("items") or {}).get("data") or []
        product_id = "stripe_pro"
        if items:
            product_id = (items[0].get("price") or {}).get("product") or product_id

        if period_end_ms is None:
            logger.warning(
                "Sub=%s has no current_period_end (status=%s) — skipping", sub_id, stripe_status
            )
            skipped += 1
            continue

        renews_at: str | None = None
        if stripe_status in ("active", "trialing", "past_due") and period_end:
            renews_at = dt.datetime.fromtimestamp(period_end, tz=dt.timezone.utc).isoformat(
                timespec="seconds"
            )

        if db_status != stripe_status:
            logger.info(
                "HEAL account=%s sub=%s: db_status=%s → stripe_status=%s",
                account_id, sub_id, db_status, stripe_status,
            )
            if not args.dry_run:
                store.apply_stripe_subscription_fact(
                    account_id=account_id,
                    subscription_id=sub_id,
                    stripe_status=stripe_status,
                    period_end_ms=period_end_ms,
                    product_id=product_id,
                )
                plan = "pro" if stripe_status in ("active", "trialing", "past_due") else "free"
                store.update_account_subscription(
                    account_id=account_id,
                    customer_id=customer_id,
                    subscription_id=sub_id if plan == "pro" else None,
                    status=stripe_status,
                    renews_at=renews_at if plan == "pro" else None,
                )
            healed += 1
        else:
            logger.debug(
                "OK account=%s sub=%s status=%s", account_id, sub_id, stripe_status
            )
            already_ok += 1

    store.close()

    logger.info(
        "Reconciliation finished: healed=%d already_ok=%d skipped=%d dead_letters=%d "
        "(dry_run=%s)",
        healed, already_ok, skipped, len(dead_letters), args.dry_run,
    )
    if dead_letters:
        logger.error(
            "%d subscription(s) could not be processed (dead letters):", len(dead_letters)
        )
        for sub_id, err in dead_letters:
            logger.error("  sub=%s error=%s", sub_id, err)
        sys.exit(1)


if __name__ == "__main__":
    main()
