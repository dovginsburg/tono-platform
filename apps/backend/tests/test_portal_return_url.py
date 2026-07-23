"""Unit coverage for the Stripe billing-portal return-URL allowlist.

The portal proxy lets the web app supply where Stripe returns the user after the
billing portal. `_portal_return_url` must honour only trusted https URLs (same
host as the public base URL, or a tonoit.com host) and otherwise fall back to
the on-brand account page — never an attacker-supplied open redirect, and never
the old 404 `/v1/checkout/return`.
"""

from __future__ import annotations

import pytest


class _FakeRequest:
    """Minimal stand-in; _public_base_url reads PUBLIC_BASE_URL from the env and
    only touches request.base_url when that is unset (not the case here)."""

    @property
    def base_url(self):  # pragma: no cover - not reached when PUBLIC_BASE_URL set
        return "https://api.tonoit.com/"


@pytest.fixture
def payments(monkeypatch):
    monkeypatch.setenv("PUBLIC_BASE_URL", "https://tonoit.com")
    from backend import payments as _payments

    return _payments


def test_default_is_account_page_when_no_request(payments):
    assert payments._portal_return_url(_FakeRequest(), None) == "https://tonoit.com/app/account"


def test_default_replaces_untrusted_host(payments):
    assert (
        payments._portal_return_url(_FakeRequest(), "https://evil.example.com/phish")
        == "https://tonoit.com/app/account"
    )


def test_rejects_non_https(payments):
    assert (
        payments._portal_return_url(_FakeRequest(), "http://tonoit.com/app/account")
        == "https://tonoit.com/app/account"
    )


def test_honours_same_host_https(payments):
    url = "https://tonoit.com/app/account"
    assert payments._portal_return_url(_FakeRequest(), url) == url


def test_honours_tonoit_subdomain(payments):
    url = "https://app.tonoit.com/app/account"
    assert payments._portal_return_url(_FakeRequest(), url) == url


def test_garbage_falls_back(payments):
    assert (
        payments._portal_return_url(_FakeRequest(), "not-a-url")
        == "https://tonoit.com/app/account"
    )
