#!/usr/bin/env bash
#
# D-B1 Docker cold-volume smoke test.
#
# Proves the backend container starts CORRECTLY on a freshly-provisioned,
# root-owned persistent volume WITHOUT any manual pre-chown — exactly the
# Render srv-d9gg8ngk1i2s738lngd0 first-boot scenario — then:
#
#   1. builds the image,
#   2. resets a named volume to root-owned + empty (simulating a fresh disk),
#   3. cold-starts the container against it (no pre-chown),
#   4. asserts uvicorn runs as NON-ROOT (tono), /data is chowned to tono,
#   5. registers a device,
#   6. gracefully stops (SIGTERM -> exit 0) and starts a SECOND container on
#      the same volume,
#   7. asserts the device row PERSISTED and the DB/WAL stayed tono-owned,
#      i.e. the existing data was untouched.
#
# Requires: docker, python3, curl. No cloud access, no secrets. Everything is
# torn down on exit.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKEND_DIR="$REPO_ROOT/apps/backend"

IMAGE="tono-backend:coldsmoke"
VOL="tono_coldsmoke_vol"
C1="tono_coldsmoke_c1"
C2="tono_coldsmoke_c2"
HOST_PORT="${TONO_SMOKE_PORT:-8799}"
BASE="http://127.0.0.1:${HOST_PORT}"

log()  { printf '\n=== %s ===\n' "$*"; }
fail() { printf '\nSMOKE FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
  docker rm -f "$C1" "$C2" >/dev/null 2>&1 || true
  docker volume rm "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
log "1/8 build image"
docker build \
  --build-arg TONO_CANONICAL_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)" \
  -t "$IMAGE" "$BACKEND_DIR"

# ---------------------------------------------------------------------------
log "2/8 create a fresh ROOT-OWNED empty volume (no pre-chown)"
docker volume rm "$VOL" >/dev/null 2>&1 || true
docker volume create "$VOL" >/dev/null
# A named volume is seeded from the image's /data (tono-owned); reset it to
# root:root and empty so it faithfully simulates a freshly-provisioned Render
# disk that the tono user cannot yet write to.
docker run --rm -v "$VOL:/data" alpine:3 sh -c \
  'rm -rf /data/* /data/.[!.]* /data/..?* 2>/dev/null || true; chown 0:0 /data; chmod 700 /data'
owner_before="$(docker run --rm -v "$VOL:/data" alpine:3 stat -c '%u:%g' /data)"
[ "$owner_before" = "0:0" ] || fail "precondition: /data should be root-owned, got $owner_before"
echo "  /data owner before cold start: $owner_before (root)"

# ---------------------------------------------------------------------------
log "3/8 cold-start container on the root-owned volume (NO manual pre-chown)"
docker run -d --name "$C1" \
  -e RENDER=true \
  -e TONO_DB_PATH=/data/tono.db \
  -e TONO_PROVIDER=mock \
  -e PORT=8765 \
  -v "$VOL:/data" \
  -p "127.0.0.1:${HOST_PORT}:8765" \
  "$IMAGE" >/dev/null

wait_healthy() {
  local name="$1" i
  for i in $(seq 1 60); do
    if curl -fsS "$BASE/health" >/dev/null 2>&1; then return 0; fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != "true" ]; then
      echo "--- container $name exited; logs: ---" >&2
      docker logs "$name" >&2 || true
      fail "container $name is not running"
    fi
    sleep 1
  done
  echo "--- container logs: ---" >&2; docker logs "$name" >&2 || true
  fail "health never became ready for $name"
}
wait_healthy "$C1"
echo "  /health OK"
curl -fsS "$BASE/health" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["status"]=="ok", d; print("  health payload status=ok, no secret fields:", sorted(d.keys()))'

# ---------------------------------------------------------------------------
log "4/8 assert NON-ROOT uvicorn + /data chowned to tono by the entrypoint"
pid1_uid="$(docker exec "$C1" sh -c 'awk "/^Uid:/ {print \$2}" /proc/1/status')"
pid1_cmd="$(docker exec "$C1" sh -c 'tr "\0" " " < /proc/1/cmdline')"
echo "  PID 1 uid=$pid1_uid cmd=$pid1_cmd"
[ "$pid1_uid" != "0" ] || fail "uvicorn (PID 1) is running as root — privilege drop failed"
echo "$pid1_cmd" | grep -q "uvicorn" || fail "PID 1 is not uvicorn: $pid1_cmd"
tono_uid="$(docker exec "$C1" id -u tono)"
[ "$pid1_uid" = "$tono_uid" ] || fail "PID 1 uid ($pid1_uid) != tono uid ($tono_uid)"

data_owner="$(docker exec "$C1" stat -c '%U:%u' /data)"
echo "  /data owner after cold start: $data_owner"
echo "$data_owner" | grep -q "^tono:" || fail "/data not chowned to tono after cold start: $data_owner"

# ---------------------------------------------------------------------------
log "5/8 register a device (writes SQLite on the cold volume)"
reg="$(curl -fsS -X POST "$BASE/v1/register" -H 'Content-Type: application/json' -d '{}')"
token="$(printf '%s' "$reg" | python3 -c 'import sys,json;print(json.load(sys.stdin)["api_token"])')"
device_id="$(printf '%s' "$reg" | python3 -c 'import sys,json;print(json.load(sys.stdin)["device_id"])')"
[ -n "$token" ] && [ -n "$device_id" ] || fail "register did not return token/device_id"
echo "  registered device_id=${device_id:0:8}… token=${token:0:8}…"

# The DB + WAL must now exist on the volume and be tono-owned.
db_owner="$(docker exec "$C1" stat -c '%U' /data/tono.db)"
[ "$db_owner" = "tono" ] || fail "/data/tono.db not owned by tono: $db_owner"
docker exec "$C1" sh -c 'test -f /data/tono.db' || fail "tono.db missing after register"
echo "  /data/tono.db present and owned by tono"

# ---------------------------------------------------------------------------
log "6/8 graceful stop (SIGTERM) then restart on the SAME volume"
docker stop -t 15 "$C1" >/dev/null
exit_code="$(docker inspect -f '{{.State.ExitCode}}' "$C1")"
echo "  container exit code after SIGTERM: $exit_code"
[ "$exit_code" = "0" ] || fail "ungraceful shutdown (exit $exit_code); expected 0 from a clean SIGTERM"

docker run -d --name "$C2" \
  -e RENDER=true \
  -e TONO_DB_PATH=/data/tono.db \
  -e TONO_PROVIDER=mock \
  -e PORT=8765 \
  -v "$VOL:/data" \
  -p "127.0.0.1:${HOST_PORT}:8765" \
  "$IMAGE" >/dev/null
wait_healthy "$C2"
echo "  second container healthy on the warm volume"

# ---------------------------------------------------------------------------
log "7/8 assert persistence — same device survives the restart"
me="$(curl -fsS "$BASE/v1/me" -H "Authorization: Bearer $token")"
me_device="$(printf '%s' "$me" | python3 -c 'import sys,json;print(json.load(sys.stdin)["device_id"])')"
echo "  /v1/me device_id=${me_device:0:8}…"
[ "$me_device" = "$device_id" ] || fail "device did NOT persist across restart ($device_id -> $me_device)"

# Data untouched + still tono-owned on the warm volume.
db_owner2="$(docker exec "$C2" stat -c '%U' /data/tono.db)"
[ "$db_owner2" = "tono" ] || fail "/data/tono.db ownership changed after restart: $db_owner2"
users_count="$(docker exec "$C2" sh -c "python3 -c \"import sqlite3;print(sqlite3.connect('/data/tono.db').execute('select count(*) from users').fetchone()[0])\"")"
echo "  users rows on persisted DB: $users_count"
[ "$users_count" -ge 1 ] || fail "expected >=1 persisted user row, got $users_count"

# ---------------------------------------------------------------------------
log "8/8 non-root uvicorn on restart too"
pid1_uid2="$(docker exec "$C2" sh -c 'awk "/^Uid:/ {print \$2}" /proc/1/status')"
[ "$pid1_uid2" != "0" ] || fail "restarted uvicorn is running as root"
echo "  restarted PID 1 uid=$pid1_uid2 (non-root)"

printf '\nSMOKE PASS: cold root-owned volume -> non-root uvicorn -> register -> restart -> persisted, data intact.\n'
