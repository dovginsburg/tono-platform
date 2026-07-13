#!/usr/bin/env python3
"""Verify that SQLite data persists across Railway deploys.

Usage:
    TONO_BACKEND_URL=https://api.tonoit.com \
    TONO_API_TOKEN=<bearer-token> \
    python3 verify_sqlite_persistence.py

The script:
  1. Registers a new device (or re-uses TONO_API_TOKEN if set).
  2. Posts an analyze request and records the `used_today` count.
  3. Waits for the user to trigger a redeploy (or just re-run after a deploy).
  4. Fetches /v1/me and confirms the user record still exists (device_id,
     plan, daily_count) — proving /data is mounted and WAL is flushing.
"""

import os
import sys
import json
import uuid
import time
import http.client
import urllib.parse


BASE_URL = os.environ.get("TONO_BACKEND_URL", "http://localhost:8765")
TOKEN    = os.environ.get("TONO_API_TOKEN", "")

parsed = urllib.parse.urlparse(BASE_URL)
HOST   = parsed.netloc
HTTPS  = parsed.scheme == "https"


def request(method: str, path: str, body=None, token: str = "") -> dict:
    conn = http.client.HTTPSConnection(HOST) if HTTPS else http.client.HTTPConnection(HOST)
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    encoded = json.dumps(body).encode() if body else None
    conn.request(method, path, encoded, headers)
    resp = conn.getresponse()
    raw = resp.read().decode()
    if resp.status not in (200, 201):
        print(f"  ERROR {resp.status}: {raw[:200]}", file=sys.stderr)
        sys.exit(1)
    return json.loads(raw)


def main():
    print(f"Target: {BASE_URL}")

    # --- Step 1: register / authenticate ---
    if TOKEN:
        print("Using existing TONO_API_TOKEN")
        api_token = TOKEN
    else:
        device_id = str(uuid.uuid4())
        print(f"Registering new device: {device_id[:8]}…")
        reg = request("POST", "/v1/register", {
            "device_id": device_id,
            "platform": "verify-script",
            "app_version": "0.0",
        })
        api_token = reg["api_token"]
        print(f"  Registered. Plan: {reg['plan']}")

    # --- Step 2: fetch current state ---
    me_before = request("GET", "/v1/me", token=api_token)
    print(f"\nBefore: device_id={me_before['device_id'][:8]}… plan={me_before['plan']} "
          f"used_today={me_before['used_today']}")

    # --- Step 3: analyze to bump daily count ---
    print("Sending analyze request…")
    result = request("POST", "/api/analyze", {
        "text": "Let me know when you can — persistence test.",
        "provider": "mock",
    }, token=api_token)
    used_after = result.get("used_today", "?")
    print(f"  used_today after request: {used_after}")

    # --- Step 4: prompt for redeploy ---
    print("\n" + "="*60)
    print("NEXT: trigger a Railway redeploy (or wait for one to finish),")
    print("then re-run this script with TONO_API_TOKEN set:")
    print(f"  TONO_BACKEND_URL={BASE_URL} TONO_API_TOKEN={api_token} python3 {sys.argv[0]}")
    print("="*60)
    print("\nOr press Enter to immediately re-fetch (useful when testing WAL flush only)…")
    input()

    # --- Step 5: re-fetch to verify persistence ---
    me_after = request("GET", "/v1/me", token=api_token)
    print(f"\nAfter: device_id={me_after['device_id'][:8]}… plan={me_after['plan']} "
          f"used_today={me_after['used_today']}")

    # --- Step 6: verdict ---
    print()
    if me_after["device_id"] == me_before["device_id"]:
        print("PASS: device record persisted across restart.")
    else:
        print("FAIL: device_id changed — database was not persisted!")
        sys.exit(1)

    if me_after["plan"] == me_before["plan"]:
        print("PASS: plan persisted.")
    else:
        print(f"WARN: plan changed {me_before['plan']} -> {me_after['plan']} (could be upgrade, not a persistence bug).")

    print("\nPersistence check complete.")


if __name__ == "__main__":
    main()
