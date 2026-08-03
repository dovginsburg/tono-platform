#!/bin/sh
# Minimal, auditable root entrypoint (D-B1).
#
# Render (and any container platform) mounts the persistent disk at /data
# root-owned on first provision. The application runs as the unprivileged
# `tono` user and therefore cannot create the SQLite database or its WAL/SHM
# sidecars on a fresh root-owned volume. This entrypoint runs as root ONLY to
# fix that ownership, then drops privileges to `tono` with gosu and execs the
# application so it becomes PID 1 and receives SIGTERM/SIGINT directly
# (graceful shutdown). Nothing here downloads code or touches file *contents*.
set -eu

DATA_DIR=/data

# Ensure the mount point exists and the directory itself is owned by tono, so
# SQLite can create the -wal/-shm sidecars alongside the database. On a fresh
# root-owned volume this is the one required fix; on a warm volume it is an
# idempotent no-op. chown changes ownership metadata only — it never rewrites
# file contents, so an existing tono.db/-wal/-shm is left byte-for-byte intact.
mkdir -p "$DATA_DIR"
chown tono:tono "$DATA_DIR"

# Belt-and-suspenders: if a prior run (or a manual copy) left the database or
# its sidecars root-owned, hand them back to tono WITHOUT touching contents.
# We target the known files explicitly rather than `chown -R` so we never walk
# (or accidentally rewrite metadata across) unrelated large trees on the disk.
for f in tono.db tono.db-wal tono.db-shm; do
    if [ -e "$DATA_DIR/$f" ]; then
        chown tono:tono "$DATA_DIR/$f" 2>/dev/null || true
    fi
done

# The predeploy integrity gate (below) writes timestamped rollback snapshots to
# $DATA_DIR/backups as the unprivileged `tono` user. On a fresh volume tono
# creates that directory itself, but a WARM volume provisioned by an older
# lineage can carry a pre-existing ROOT-OWNED /data/backups (the backup step
# used to run as root). tono then cannot create a snapshot inside it, and the
# gate aborts the deploy with the exact runtime error we saw:
#   "predeploy backup: aborting deploy — unable to open database file".
# Fix it here, as root, with the SAME narrow discipline used for /data above:
# ensure the single directory exists and set ITS ownership + mode directly.
# We do NOT `chown -R` — the snapshot FILES already inside are left
# byte-for-byte intact (unchanged owner, contents, and mtime). tono owning the
# directory is sufficient both to write new snapshots and to prune old ones,
# because POSIX unlink checks write permission on the *directory*, not on each
# file. chmod 0700 guarantees the owner (now tono) has write even if the
# directory arrived with an owner-write-less mode, keeps rollback snapshots
# private to tono, and clears any stray setuid/setgid/sticky bits. This is
# load-bearing, not best-effort: if it fails we fail closed HERE (set -e, no
# `|| true`) rather than drop to a predeploy that is guaranteed to fail.
BACKUPS_DIR="$DATA_DIR/backups"
mkdir -p "$BACKUPS_DIR"
chown tono:tono "$BACKUPS_DIR"
chmod 0700 "$BACKUPS_DIR"

# Drop privileges and exec. When the command is the app server, append the
# port here so ${PORT:-8765} is expanded exactly once by the shell, safely
# quoted (Render/Railway inject PORT; locally it defaults to 8765). The base
# argv lives in the exec-form CMD so signals and arg-quoting stay correct.
if [ "${1:-}" = "uvicorn" ]; then
    # Predeploy integrity gate. Before the app opens the database, take a
    # consistent, WAL-inclusive backup and run PRAGMA integrity_check on the
    # COPY (see backend/scripts/predeploy_backup.py). This is the SAME gate the
    # old runtime-bootstrap dockerCommand ran; it now travels inside the image
    # so a real prebuilt image (build-time-installed deps, no runtime pip) keeps
    # the backup/integrity guarantee instead of losing it. It runs as the
    # unprivileged `tono` user — the identity that owns /data and will open the
    # DB — so backups under /data/backups stay tono-owned, never root-owned.
    #
    # Fail closed: `set -e` (top of file) means a nonzero exit here — a corrupt
    # backup, or predeploy raising — aborts boot before uvicorn ever starts, so
    # the platform health check fails the deploy rather than promoting a
    # container over a bad database. On a fresh/empty volume it is a fast no-op.
    # Only stdlib is imported (sqlite3/os/json/time), so this does not depend on
    # the app's third-party wheels and adds no meaningful startup latency.
    gosu tono python -m backend.scripts.predeploy_backup
    exec gosu tono "$@" --port "${PORT:-8765}"
fi

exec gosu tono "$@"
