#!/usr/bin/env python3
"""Safe, idempotent predeploy backup of the Tono SQLite database.

This runs BEFORE any migration or app import during deploy bootstrap. Its job
is to take a consistent, rollback-quality snapshot of the live database and
prove — with evidence in the deploy logs — that the DB is intact before we let
it proceed to migrate. It is the safe replacement for the old base64
``dockerCommand`` that downloaded code from an obsolete repo, pulled a
"recovery" DB over a real one, DELETEd rows for a hardcoded test device, and
asserted hardcoded row counts (``users == 46`` / ``usage_log == 76``).

This module does none of that. It:

  * Resolves the DB path from ``TONO_DB_PATH`` (default ``./tono.db``).
  * If the DB file does not exist (fresh volume), it is a no-op — the app will
    create the schema on first boot.
  * Otherwise, BEFORE any migration/app import, it makes a timestamped copy at
    ``${dir}/backups/tono-YYYYMMDDTHHMMSSZ.db`` using the sqlite3 backup API
    (``conn.backup``) for a consistent copy that folds in the WAL — NOT a raw
    file copy.
  * Runs ``PRAGMA integrity_check`` on the BACKUP copy; if the result is not
    ``ok`` it fails CLOSED (nonzero exit) so a corrupt DB never proceeds to
    migrate.
  * Records and logs row counts for each user-data table (introspected from
    ``sqlite_master``) as JSON. It asserts NO specific numbers, deletes NO
    rows, and deletes NO test users.
  * Retains backups for rollback (pruned to the last 10 by mtime).

Run as::

    python -m backend.scripts.predeploy_backup

Exit code 0 on success; 1 on integrity failure (or any error).
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys
import time
from typing import Optional

# How many timestamped backups to retain for rollback.
_KEEP_BACKUPS = 10


def _utc_stamp(now_epoch: float) -> str:
    """Return a filesystem-safe UTC timestamp: YYYYMMDDTHHMMSSZ."""
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(now_epoch))


def _user_data_tables(conn: sqlite3.Connection) -> list[str]:
    """Introspect real user-data tables from sqlite_master.

    Excludes SQLite internal tables (``sqlite_*``); those are not user data
    and some cannot be selected from directly.
    """
    rows = conn.execute(
        "SELECT name FROM sqlite_master "
        "WHERE type = 'table' AND name NOT LIKE 'sqlite_%' "
        "ORDER BY name"
    ).fetchall()
    return [r[0] for r in rows]


def _row_counts(conn: sqlite3.Connection) -> dict[str, int]:
    """Return {table: row_count} for every user-data table. No assertions."""
    counts: dict[str, int] = {}
    for table in _user_data_tables(conn):
        # Table names come from sqlite_master (not user input) and are
        # quoted defensively; parameter binding is not available for
        # identifiers in SQLite.
        quoted = '"' + table.replace('"', '""') + '"'
        counts[table] = conn.execute(f"SELECT COUNT(*) FROM {quoted}").fetchone()[0]
    return counts


def _prune_backups(backups_dir: str, keep: int = _KEEP_BACKUPS) -> None:
    """Keep only the newest ``keep`` backups (by mtime); delete older ones."""
    try:
        entries = [
            os.path.join(backups_dir, name)
            for name in os.listdir(backups_dir)
            if name.startswith("tono-") and name.endswith(".db")
        ]
    except FileNotFoundError:
        return
    entries.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    for stale in entries[keep:]:
        try:
            os.remove(stale)
        except OSError:
            # Pruning is best-effort; never fail the deploy over a stale file.
            pass


def run(db_path: str, now_epoch: Optional[float] = None) -> dict:
    """Back up the DB at ``db_path`` and verify its integrity.

    Returns a dict ``{backup_path, integrity, counts}``.

    * Fresh volume (DB file missing): returns
      ``{"backup_path": None, "integrity": "skipped", "counts": {}}`` and logs a
      no-op — the app will create the schema on first boot.
    * Existing DB: makes a consistent timestamped backup (WAL-inclusive) via the
      sqlite3 backup API, runs ``PRAGMA integrity_check`` on the BACKUP, records
      row counts from the LIVE DB, and prunes to the last 10 backups.

    Raises ``RuntimeError`` if the backup's integrity_check is not ``ok`` — the
    caller must treat this as fail-closed and not proceed to migrate.
    """
    if now_epoch is None:
        now_epoch = time.time()

    if not os.path.exists(db_path):
        print("no existing database — fresh volume, nothing to back up")
        return {"backup_path": None, "integrity": "skipped", "counts": {}}

    db_dir = os.path.dirname(os.path.abspath(db_path))
    backups_dir = os.path.join(db_dir, "backups")
    os.makedirs(backups_dir, exist_ok=True)

    stamp = _utc_stamp(now_epoch)
    backup_path = os.path.join(backups_dir, f"tono-{stamp}.db")

    # --- Consistent, WAL-inclusive copy via the sqlite3 backup API. ---
    # conn.backup() reads a transactionally-consistent snapshot of the live DB
    # (folding in any WAL frames) into the destination — unlike a raw file copy
    # which can miss un-checkpointed WAL data or capture a torn page.
    src = sqlite3.connect(db_path)
    try:
        dest = sqlite3.connect(backup_path)
        try:
            src.backup(dest)
        finally:
            dest.close()
    finally:
        src.close()

    # --- Fail closed on a corrupt backup. ---
    check_conn = sqlite3.connect(backup_path)
    try:
        integrity = check_conn.execute("PRAGMA integrity_check").fetchone()[0]
    finally:
        check_conn.close()

    if integrity != "ok":
        print(
            "PREDEPLOY BACKUP FAILED: integrity_check on "
            f"{backup_path} returned {integrity!r} (expected 'ok') — "
            "refusing to proceed to migrate (fail closed)."
        )
        raise RuntimeError(f"integrity_check failed: {integrity!r}")

    # --- Row counts from the LIVE DB (evidence only; no assertions). ---
    live = sqlite3.connect(db_path)
    try:
        counts = _row_counts(live)
    finally:
        live.close()

    _prune_backups(backups_dir)

    print(f"predeploy backup: wrote {backup_path}")
    print(f"predeploy backup: integrity_check={integrity}")
    print(f"predeploy backup: row_counts={json.dumps(counts, sort_keys=True)}")

    return {"backup_path": backup_path, "integrity": integrity, "counts": counts}


def main() -> None:
    """Entry point for ``python -m backend.scripts.predeploy_backup``."""
    db_path = os.environ.get("TONO_DB_PATH", "./tono.db")
    try:
        run(db_path)
    except Exception as exc:  # noqa: BLE001 — fail closed on any error.
        print(f"predeploy backup: aborting deploy — {exc}")
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
