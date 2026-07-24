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

# Drop privileges and exec. When the command is the app server, append the
# port here so ${PORT:-8765} is expanded exactly once by the shell, safely
# quoted (Render/Railway inject PORT; locally it defaults to 8765). The base
# argv lives in the exec-form CMD so signals and arg-quoting stay correct.
if [ "${1:-}" = "uvicorn" ]; then
    exec gosu tono "$@" --port "${PORT:-8765}"
fi

exec gosu tono "$@"
