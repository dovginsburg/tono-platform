"""Commercial catalog loader — the single server-side source of truth for the
mapping (Stripe web / Apple App Store / Google Play) -> the ONE canonical paid
entitlement.

The catalog itself lives at ``packages/contracts/commercial-catalog.v1.json``
(versioned, committed, no secrets). This module loads it once, validates the
launch invariants, and exposes the small typed surface the backend needs so the
product-id / price-env-var mapping is never duplicated across payments.py and
app_store.py.

Fail-closed: a malformed or duplicated-plan catalog raises ``CatalogError`` at
load time rather than silently degrading. Callers that must never hard-fail on a
packaging hiccup (e.g. the App Store product-id default) can catch it and fall
back to the historical literal, which the accompanying test pins equal to the
catalog — so the fallback can never drift.
"""

from __future__ import annotations

import json
import os
from functools import lru_cache
from pathlib import Path
from typing import Any, Optional

# ``apps/backend/catalog.py`` -> parents[2] is the repository root.
_DEFAULT_CATALOG_PATH = (
    Path(__file__).resolve().parents[2] / "packages" / "contracts" / "commercial-catalog.v1.json"
)


class CatalogError(RuntimeError):
    """Raised when the commercial catalog is missing, unreadable, or violates a
    launch invariant (e.g. more than one canonical entitlement)."""


def _catalog_path() -> Path:
    """Allow an explicit override for tests / alternate layouts, else the
    committed default."""
    override = os.environ.get("TONO_COMMERCIAL_CATALOG_PATH", "").strip()
    return Path(override) if override else _DEFAULT_CATALOG_PATH


@lru_cache(maxsize=1)
def load_catalog() -> dict[str, Any]:
    """Load + validate the catalog once. Raises CatalogError on any problem so a
    broken catalog can never quietly grant/deny access."""
    path = _catalog_path()
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise CatalogError(f"commercial catalog not readable at {path}: {exc}") from exc
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise CatalogError(f"commercial catalog is not valid JSON ({path}): {exc}") from exc

    _validate(data, path)
    return data


def _validate(data: dict[str, Any], path: Path) -> None:
    entitlements = data.get("canonical_entitlements")
    if not isinstance(entitlements, dict) or not entitlements:
        raise CatalogError(f"catalog {path} has no canonical_entitlements")
    # Launch invariant: exactly ONE canonical paid entitlement, no duplicate plan.
    if set(entitlements) != {"pro"}:
        raise CatalogError(
            f"catalog {path} must declare exactly one canonical entitlement 'pro'; "
            f"found {sorted(entitlements)}"
        )

    providers = data.get("providers")
    if not isinstance(providers, dict) or not providers:
        raise CatalogError(f"catalog {path} has no providers")

    for name, provider in providers.items():
        products = (provider or {}).get("products")
        if not isinstance(products, list) or not products:
            raise CatalogError(f"catalog provider {name!r} has no products")
        for product in products:
            ent = product.get("entitlement")
            if ent not in entitlements:
                raise CatalogError(
                    f"catalog provider {name!r} product maps to unknown entitlement {ent!r}"
                )
            interval = product.get("interval")
            if interval not in ("month", "year"):
                raise CatalogError(
                    f"catalog provider {name!r} product has bad interval {interval!r}"
                )


# ---------------------------------------------------------------------------
# Typed accessors (the surface payments.py / app_store.py consume)
# ---------------------------------------------------------------------------


def catalog_version() -> str:
    return str(load_catalog().get("catalog_version", "unknown"))


def canonical_entitlement_ids() -> frozenset[str]:
    return frozenset(load_catalog()["canonical_entitlements"].keys())


def _provider(name: str) -> dict[str, Any]:
    provider = load_catalog()["providers"].get(name)
    if not provider:
        raise CatalogError(f"catalog has no provider {name!r}")
    return provider


def apple_product_ids() -> frozenset[str]:
    """Every App Store product id that maps to the canonical entitlement."""
    return frozenset(
        p["product_id"] for p in _provider("app_store")["products"] if p.get("product_id")
    )


def google_play_subscription_ids() -> frozenset[str]:
    return frozenset(
        p["subscription_id"]
        for p in _provider("google_play")["products"]
        if p.get("subscription_id")
    )


def stripe_price_env_var(interval: str) -> Optional[str]:
    """The environment-variable NAME holding the Stripe Price id for this
    interval, per the catalog. Never returns a secret value."""
    for product in _provider("stripe")["products"]:
        if product.get("interval") == interval:
            return product.get("price_env_var")
    return None


def approved_price(interval: str) -> Optional[str]:
    """The approved display price string for an interval (reference only)."""
    return load_catalog().get("approved_prices", {}).get("intervals", {}).get(interval)
