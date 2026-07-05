#!/usr/bin/env python3
"""Local Apple/Google OAuth verification test harness.

Backend/social_auth.py's real verification code (JWKS fetch, RS256
signature check, aud/iss validation) has never run against a live Apple or
Google server in this sandbox — there's no network path to
appleid.apple.com or googleapis.com here, so every existing test overrides
`get_apple_verifier`/`get_google_verifier` and never exercises the real
`verify_apple_identity_token`/`verify_google_id_token` functions at all
(see social_auth.py's module docstring). That's a real, standing gap: the
one thing a mocked test can never catch is "does the actual JWKS-fetch +
RS256-verify + claims-check code work."

This script closes that gap without needing production Apple/Google
client IDs or network access to either provider:

  1. Generates a throwaway RSA keypair and serves it as a JWKS document
     over plain HTTP on localhost (`--jwks-port`, default 9100).
  2. Mints a real RS256-signed "identity token" shaped exactly like what
     Apple/Google actually issue (iss/aud/sub/email/exp), signed with that
     throwaway key.
  3. Prints the env vars you need to point a LOCAL backend at this fake
     JWKS server instead of the real one — this is the only override;
     `verify_apple_identity_token`/`verify_google_id_token` themselves run
     completely unmodified, so a pass here is a real signal about that
     code, not the harness's own logic.
  4. With `--auto`, drives the actual HTTP flow against a running backend
     (`--backend`, default http://localhost:8765): register a device,
     POST the minted token to /v1/auth/apple or /v1/auth/google, and
     report pass/fail.

Usage:
    # Terminal 1 — start the harness (keeps the JWKS server alive):
    python3 Backend/scripts/oauth_test_harness.py apple --auto

    # The script prints env vars; export them in Terminal 2, THEN start
    # (or restart) the backend there:
    export APPLE_JWKS_URL=http://127.0.0.1:9100/keys
    export APPLE_CLIENT_ID=com.tonit.app.harness-test
    uvicorn Backend.server:app --port 8765

    # Back in Terminal 1, the harness polls --backend until it's up, then
    # POSTs the minted token and reports PASS/FAIL — no need to press
    # anything, which also means this is safe to script/CI.

Before shipping, replace the harness entirely: unset APPLE_JWKS_URL /
APPLE_ISSUER / GOOGLE_JWKS_URL / GOOGLE_ISSUERS (they must stay at their
real-provider defaults — see social_auth.py) and set APPLE_CLIENT_ID /
GOOGLE_CLIENT_ID to your real Sign in with Apple Services ID / Google
Cloud Console OAuth client ID. This harness proves the verification CODE
works; it cannot prove your production client IDs are configured
correctly — that still needs one real device test against real Apple/
Google servers.
"""

from __future__ import annotations

import argparse
import http.server
import json
import sys
import threading
import time
import uuid
from http.client import HTTPConnection, HTTPSConnection

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa

DEFAULT_JWKS_PORT = 9100
HARNESS_KID = "harness-test-key-1"
HARNESS_AUDIENCE = "com.tonit.app.harness-test"

PROVIDER_CONFIG = {
    "apple": {
        "issuer": "https://appleid.apple.com",
        "jwks_env": "APPLE_JWKS_URL",
        "client_id_env": "APPLE_CLIENT_ID",
        "token_field": "identity_token",
        "endpoint": "/v1/auth/apple",
    },
    "google": {
        "issuer": "accounts.google.com",
        "jwks_env": "GOOGLE_JWKS_URL",
        "client_id_env": "GOOGLE_CLIENT_ID",
        "token_field": "id_token",
        "endpoint": "/v1/auth/google",
    },
}


def _make_keypair() -> rsa.RSAPrivateKey:
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _jwk_for(private_key: rsa.RSAPrivateKey, kid: str) -> dict:
    jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(private_key.public_key()))
    jwk.update({"kid": kid, "use": "sig", "alg": "RS256"})
    return jwk


def _mint_token(private_key: rsa.RSAPrivateKey, *, provider: str, sub: str, email: str) -> str:
    issuer = PROVIDER_CONFIG[provider]["issuer"]
    now = int(time.time())
    claims = {
        "iss": issuer,
        "aud": HARNESS_AUDIENCE,
        "sub": sub,
        "email": email,
        "email_verified": True,
        "iat": now,
        "exp": now + 600,
    }
    return jwt.encode(claims, private_key, algorithm="RS256", headers={"kid": HARNESS_KID})


class _JwksHandler(http.server.BaseHTTPRequestHandler):
    jwk: dict = {}

    def do_GET(self):  # noqa: N802 - http.server's naming convention
        body = json.dumps({"keys": [self.jwk]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # quiet — this is a test tool, not a server
        pass


def _serve_jwks(jwk: dict, port: int) -> http.server.HTTPServer:
    _JwksHandler.jwk = jwk
    server = http.server.HTTPServer(("127.0.0.1", port), _JwksHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def _http_post_json(base_url: str, path: str, body: dict, token: str | None = None) -> tuple[int, dict]:
    conn_cls = HTTPSConnection if base_url.startswith("https://") else HTTPConnection
    host = base_url.split("://", 1)[1]
    conn = conn_cls(host)
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    conn.request("POST", path, json.dumps(body), headers)
    resp = conn.getresponse()
    raw = resp.read().decode()
    conn.close()
    return resp.status, (json.loads(raw) if raw else {})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("provider", choices=["apple", "google"])
    parser.add_argument("--jwks-port", type=int, default=DEFAULT_JWKS_PORT)
    parser.add_argument("--backend", default="http://localhost:8765")
    parser.add_argument("--sub", default=f"harness-{uuid.uuid4().hex[:12]}")
    parser.add_argument("--email", default="harness-test@example.com")
    parser.add_argument(
        "--auto", action="store_true",
        help="Wait for --backend to come up with the printed env vars, then drive the "
             "real HTTP flow and report PASS/FAIL.",
    )
    parser.add_argument(
        "--timeout", type=float, default=60.0,
        help="With --auto, how long to wait (seconds) for --backend to become reachable "
             "before giving up (default 60). Polls /health rather than blocking on stdin, "
             "so this works the same whether you're driving it interactively or from a script.",
    )
    args = parser.parse_args()

    cfg = PROVIDER_CONFIG[args.provider]
    private_key = _make_keypair()
    jwk = _jwk_for(private_key, HARNESS_KID)
    server = _serve_jwks(jwk, args.jwks_port)
    jwks_url = f"http://127.0.0.1:{args.jwks_port}/keys"

    token = _mint_token(private_key, provider=args.provider, sub=args.sub, email=args.email)

    print(f"Serving a throwaway JWKS at {jwks_url} (real RSA key, real RS256 signing).\n")
    print("Set these env vars, then (re)start the backend in another terminal:")
    print(f"  export {cfg['jwks_env']}={jwks_url}")
    print(f"  export {cfg['client_id_env']}={HARNESS_AUDIENCE}")
    print(f"  uvicorn Backend.server:app --port 8765\n")
    print(f"Minted {args.provider} identity token (sub={args.sub}, email={args.email}):")
    print(f"  {token}\n")

    if not args.auto:
        print("Re-run with --auto to have this script drive the /v1/register + "
              f"POST {cfg['endpoint']} flow against --backend and report PASS/FAIL.")
        return 0

    print(f"Waiting up to {args.timeout:.0f}s for {args.backend}/health to respond "
          "(start/restart it now with the env vars above)...")
    deadline = time.time() + args.timeout
    status, reg = None, None
    while time.time() < deadline:
        try:
            status, reg = _http_post_json(args.backend, "/v1/register", {})
            break
        except OSError:
            time.sleep(1)
    if status is None:
        print(f"FAIL: {args.backend} never became reachable within {args.timeout:.0f}s")
        return 1
    if status != 200:
        print(f"FAIL: /v1/register returned {status}: {reg}")
        return 1
    device_token = reg["api_token"]
    print(f"Registered device {reg['device_id'][:8]}…")

    status, result = _http_post_json(
        args.backend, cfg["endpoint"], {cfg["token_field"]: token}, token=device_token
    )
    if status != 200:
        print(f"FAIL: {cfg['endpoint']} returned {status}: {result}")
        print("Common causes: env vars not set before the backend started, or the")
        print("backend process wasn't restarted after exporting them.")
        return 1

    print(f"PASS: {cfg['endpoint']} verified the real RS256-signed token end-to-end.")
    print(f"  account_id={result.get('account_id')} email={result.get('email')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
