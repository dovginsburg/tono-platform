#!/usr/bin/env bash
#
# Docker WARM-VOLUME backups-permission smoke test.
#
# Reproduces and proves the fix for the exact Render deploy blocker observed on
# srv-d9gg8ngk1i2s738lngd0: a WARM persistent volume that already carries a
# ROOT-OWNED /data/backups (created by an older lineage whose backup step ran as
# root). The unprivileged `tono` predeploy backup then cannot create its
# timestamped snapshot inside that directory, and the deploy aborts with the
# exact runtime error we saw in the deploy log:
#
#     predeploy backup: aborting deploy — unable to open database file
#
# This test:
#   1. builds the image,
#   2. cold-starts on a FRESH ROOT-OWNED volume (the Render first-provision
#      state) to create a real WAL-mode DB, asserting the entrypoint chowns
#      /data AND creates+chowns /data/backups to tono from nothing,
#   3. SABOTAGES the volume the way production is broken: makes /data/backups
#      root-owned + 0700 and seeds 11 ROOT-OWNED old snapshot files inside it
#      (with distinct old mtimes and recorded content hashes),
#   4. restarts the container — the previously-FAILING scenario — and asserts:
#        * /health 200 and uvicorn runs NON-ROOT (privilege drop intact),
#        * /data/backups is now tono-owned (the entrypoint repaired it),
#        * a NEW, tono-owned snapshot was written (backup gate ran),
#        * the account row + DB/WAL survived and stayed tono-owned,
#        * pruning removed the TWO OLDEST seeded snapshots — proving tono can
#          unlink root-owned files in the now-tono-owned directory,
#        * every SURVIVING seeded snapshot is byte-for-byte intact AND still
#          ROOT-owned — proving the repair did NOT chown -R or rewrite contents,
#   5. finally SABOTAGES the DB itself (garbage, no WAL) and asserts the next
#      start FAILS CLOSED — the integrity gate still aborts the deploy and
#      uvicorn never starts.
#
# All HTTP is driven from INSIDE the container over its own loopback (the image
# ships python3), so the test does not depend on host->container port publishing
# (which some local Docker backends, e.g. colima, do not forward). No cloud
# access, no secrets. Requires: docker. Everything is torn down on exit.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKEND_DIR="$REPO_ROOT/apps/backend"

IMAGE="tono-backend:backupsperm"
VOL="tono_backupsperm_vol"
C1="tono_backupsperm_c1"   # cold start — seeds a real DB
C2="tono_backupsperm_c2"   # warm restart over a sabotaged root-owned backups dir
C3="tono_backupsperm_c3"   # fail-closed proof over a corrupt DB
HELPER="alpine:3"

log()  { printf '\n=== %s ===\n' "$*"; }
fail() { printf '\nSMOKE FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
  docker rm -f "$C1" "$C2" "$C3" >/dev/null 2>&1 || true
  docker volume rm "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_backend() {
  # Start a detached backend container named $1 on the shared volume. No -p:
  # HTTP is exercised from inside the container (see http_* helpers below).
  docker run -d --name "$1" \
    -e RENDER=true \
    -e TONO_DB_PATH=/data/tono.db \
    -e TONO_PROVIDER=mock \
    -e PORT=8765 \
    -v "$VOL:/data" \
    "$IMAGE" >/dev/null
}

# --- In-container HTTP over the app's own loopback (127.0.0.1:8765). ---------
health_ok() {
  docker exec "$1" python3 -c \
    "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8765/health', timeout=3)" \
    >/dev/null 2>&1
}
http_register() {
  # Echo "<api_token> <device_id>" from a fresh device registration.
  docker exec "$1" python3 -c \
    "import urllib.request,json;req=urllib.request.Request('http://127.0.0.1:8765/v1/register',data=b'{}',headers={'Content-Type':'application/json'},method='POST');d=json.load(urllib.request.urlopen(req,timeout=5));print(d['api_token'],d['device_id'])"
}
http_me_device() {
  # Echo the device_id that token $2 resolves to via /v1/me.
  docker exec "$1" python3 -c \
    "import urllib.request,json,sys;req=urllib.request.Request('http://127.0.0.1:8765/v1/me',headers={'Authorization':'Bearer '+sys.argv[1]});print(json.load(urllib.request.urlopen(req,timeout=5))['device_id'])" \
    "$2"
}
db_users() {
  docker exec "$1" python3 -c \
    "import sqlite3;print(sqlite3.connect('/data/tono.db').execute('select count(*) from users').fetchone()[0])"
}

wait_healthy() {
  local name="$1" i
  for i in $(seq 1 60); do
    if health_ok "$name"; then return 0; fi
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

expect_fail_closed() {
  # Assert container $1 aborts boot (nonzero exit, fail-closed log) and that
  # uvicorn NEVER started. Fully hermetic: no port / no exec into the (dead)
  # container — the app process must be gone, so we read exit code + logs.
  local name="$1" i running code
  for i in $(seq 1 60); do
    running="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo missing)"
    if [ "$running" = "false" ]; then
      code="$(docker inspect -f '{{.State.ExitCode}}' "$name")"
      echo "  container $name exited with code $code"
      [ "$code" != "0" ] || fail "corrupt DB must abort boot with a nonzero exit, got 0"
      docker logs "$name" 2>&1 | grep -q "aborting deploy" \
        || fail "expected fail-closed 'aborting deploy' log; last lines: $(docker logs "$name" 2>&1 | tail -5)"
      if docker logs "$name" 2>&1 | grep -q "Application startup complete"; then
        fail "uvicorn started despite a corrupt DB — integrity gate did NOT fail closed"
      fi
      return 0
    fi
    sleep 1
  done
  echo "--- container $name logs: ---" >&2; docker logs "$name" >&2 || true
  fail "corrupt DB container did not exit within timeout (fail-closed expected)"
}

# ---------------------------------------------------------------------------
log "1/6 build image"
# Canonical image: repo-root context + the .canonical Dockerfile (via -f) so the
# image packages the committed commercial catalog at
# /packages/contracts/commercial-catalog.v1.json, which lives outside apps/backend.
# This is the image Render runs; see apps/backend/Dockerfile.canonical.
docker build \
  --build-arg TONO_CANONICAL_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)" \
  -f "$BACKEND_DIR/Dockerfile.canonical" \
  -t "$IMAGE" "$REPO_ROOT"

# ---------------------------------------------------------------------------
log "2/6 fresh ROOT-OWNED volume: cold-start + register (creates a real WAL DB)"
docker volume rm "$VOL" >/dev/null 2>&1 || true
docker volume create "$VOL" >/dev/null
# A named volume is seeded from the image's /data (tono-owned); reset it to
# root:root and empty so it faithfully simulates a freshly-provisioned Render
# disk the tono user cannot yet write to.
docker run --rm -v "$VOL:/data" "$HELPER" sh -c \
  'rm -rf /data/* /data/.[!.]* /data/..?* 2>/dev/null || true; chown 0:0 /data; chmod 700 /data'
owner_fresh="$(docker run --rm -v "$VOL:/data" "$HELPER" stat -c '%u:%g' /data)"
[ "$owner_fresh" = "0:0" ] || fail "precondition: fresh /data should be root-owned, got $owner_fresh"
echo "  fresh /data owner before cold start: $owner_fresh (root)"
run_backend "$C1"
wait_healthy "$C1"
# On a fresh root-owned volume the entrypoint must chown /data AND create+chown
# /data/backups, both to tono, before the app (or any later warm predeploy) runs.
data_owner="$(docker exec "$C1" stat -c '%U' /data)"
bdir_owner="$(docker exec "$C1" stat -c '%U' /data/backups)"
[ "$data_owner" = "tono" ] || fail "/data not chowned to tono on fresh volume: $data_owner"
[ "$bdir_owner" = "tono" ] || fail "/data/backups not created+chowned to tono on fresh volume: $bdir_owner"
echo "  after cold start: /data=$data_owner, /data/backups=$bdir_owner (both tono)"

reg="$(http_register "$C1")"
token="${reg%% *}"
device_id="${reg##* }"
[ -n "$token" ] && [ -n "$device_id" ] && [ "$token" != "$device_id" ] \
  || fail "register did not return token/device_id: '$reg'"
echo "  registered device_id=${device_id:0:8}… token=${token:0:8}…"
docker exec "$C1" sh -c 'test -f /data/tono.db' || fail "tono.db missing after register"
users_before="$(db_users "$C1")"
echo "  users rows after register: $users_before"
[ "$users_before" -ge 1 ] || fail "expected >=1 user row after register, got $users_before"
docker stop -t 15 "$C1" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$C1")" = "0" ] || fail "C1 did not stop gracefully"

# ---------------------------------------------------------------------------
log "3/6 SABOTAGE: make /data/backups root-owned + seed 11 root-owned snapshots"
# This is the exact broken production state: a warm volume whose /data/backups
# (and the snapshot files inside it) are owned by root, so the tono predeploy
# cannot write there. Distinct old mtimes make pruning deterministic; recorded
# hashes let us prove the survivors are untouched byte-for-byte.
docker run --rm -v "$VOL:/data" "$HELPER" sh -c '
  set -e
  mkdir -p /data/backups
  i=1
  while [ "$i" -le 11 ]; do
    dd=$(printf "%02d" "$i")
    f="tono-202001${dd}T000000Z.db"
    printf "seed-content-%s-with-padding-bytes-0123456789" "$dd" > "/data/backups/$f"
    touch -t "202001${dd}0000" "/data/backups/$f"
    i=$((i + 1))
  done
  chown -R 0:0 /data/backups
  chmod 700 /data/backups
  cd /data/backups && sha256sum tono-*.db > /data/seed_hashes.txt
'
owner_backups="$(docker run --rm -v "$VOL:/data" "$HELPER" stat -c '%u:%g' /data/backups)"
[ "$owner_backups" = "0:0" ] || fail "precondition: /data/backups should be root-owned, got $owner_backups"
seed_count="$(docker run --rm -v "$VOL:/data" "$HELPER" sh -c 'ls /data/backups/tono-*.db | wc -l' | tr -d ' ')"
echo "  /data/backups owner=$owner_backups (root) with $seed_count seeded root-owned snapshots"
[ "$seed_count" = "11" ] || fail "expected 11 seeded snapshots, got $seed_count"

# ---------------------------------------------------------------------------
log "4/6 warm restart over the sabotaged volume — the previously FAILING deploy"
run_backend "$C2"
wait_healthy "$C2"
echo "  /health OK (deploy that previously aborted with 'unable to open database file' now boots)"

# uvicorn must still be NON-ROOT (privilege drop intact).
pid1_uid="$(docker exec "$C2" sh -c 'awk "/^Uid:/ {print \$2}" /proc/1/status')"
tono_uid="$(docker exec "$C2" id -u tono)"
[ "$pid1_uid" != "0" ] || fail "uvicorn (PID 1) is running as root — privilege drop failed"
[ "$pid1_uid" = "$tono_uid" ] || fail "PID 1 uid ($pid1_uid) != tono uid ($tono_uid)"
echo "  PID 1 uid=$pid1_uid == tono ($tono_uid), non-root"

# The entrypoint repaired the directory ownership; the predeploy wrote a NEW
# tono-owned snapshot; pruning kept the last 10 and removed the 2 oldest seeds;
# every surviving seed is still ROOT-owned and byte-for-byte intact.
docker exec "$C2" sh -c '
  set -e
  cd /data/backups
  test "$(stat -c %U .)" = tono || { echo "FAIL: /data/backups not tono-owned: $(stat -c %U .)"; exit 1; }

  total=$(ls tono-*.db | wc -l)
  [ "$total" -eq 10 ] || { echo "FAIL: expected 10 retained snapshots (prune-to-10), got $total"; exit 1; }

  new=0
  for f in tono-*.db; do [ "$(stat -c %U "$f")" = tono ] && new=$((new + 1)); done
  [ "$new" -eq 1 ] || { echo "FAIL: expected exactly 1 NEW tono-owned snapshot, got $new"; exit 1; }

  # The two oldest seeds must have been pruned...
  for gone in tono-20200101T000000Z.db tono-20200102T000000Z.db; do
    [ ! -e "$gone" ] || { echo "FAIL: oldest seed $gone was not pruned"; exit 1; }
  done
  # ...and every surviving seed must be intact AND still root-owned (no -R chown).
  for dd in 03 04 05 06 07 08 09 10 11; do
    f="tono-202001${dd}T000000Z.db"
    [ -e "$f" ] || { echo "FAIL: surviving seed $f missing"; exit 1; }
    [ "$(stat -c %U "$f")" = root ] || { echo "FAIL: surviving seed $f no longer root-owned: $(stat -c %U "$f")"; exit 1; }
  done

  # Byte-for-byte: verify survivors against the hashes recorded before boot.
  grep -v -e tono-20200101 -e tono-20200102 /data/seed_hashes.txt > /tmp/expected.txt
  sha256sum -c /tmp/expected.txt >/dev/null || { echo "FAIL: surviving seed contents changed"; exit 1; }
  echo "  OK: dir tono-owned, 1 new snapshot, 2 oldest pruned, 9 survivors intact + root-owned"
' || fail "backups repair/prune/preservation assertions failed (see output above)"

# Account data + DB/WAL survived untouched and tono-owned.
me_device="$(http_me_device "$C2" "$token")"
[ "$me_device" = "$device_id" ] || fail "device did NOT persist across the repair ($device_id -> $me_device)"
db_owner="$(docker exec "$C2" stat -c '%U' /data/tono.db)"
[ "$db_owner" = "tono" ] || fail "/data/tono.db ownership changed: $db_owner"
users_after="$(db_users "$C2")"
[ "$users_after" = "$users_before" ] || fail "user rows changed across repair ($users_before -> $users_after)"
echo "  account intact: device persisted, users=$users_after (== $users_before), tono.db still tono-owned"
docker stop -t 15 "$C2" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$C2")" = "0" ] || fail "C2 did not stop gracefully"

# ---------------------------------------------------------------------------
log "5/6 fail-closed proof: corrupt the DB, next start must abort the deploy"
docker run --rm -v "$VOL:/data" "$HELPER" sh -c '
  rm -f /data/tono.db-wal /data/tono.db-shm
  printf "GARBAGE-NOT-A-SQLITE-DATABASE-%s" "$(seq 1 64 | tr -d "\n")" > /data/tono.db
'
run_backend "$C3"
expect_fail_closed "$C3"
echo "  fail-closed intact: corrupt DB aborted the deploy, uvicorn never started"

# ---------------------------------------------------------------------------
log "6/6 done"
printf '\nSMOKE PASS: warm root-owned /data/backups -> repaired -> new tono snapshot, root-owned survivors intact, prune worked, data preserved, integrity gate still fails closed.\n'
