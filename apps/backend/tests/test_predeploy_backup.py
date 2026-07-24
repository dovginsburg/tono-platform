"""Tests for the safe, idempotent predeploy backup module.

Covers the guarantees that make it a safe replacement for the old unsafe
base64 dockerCommand:

  * Fresh volume (no DB) is a no-op that exits 0.
  * Happy path writes a consistent backup, integrity is ``ok``, and the logged
    counts match the real rows.
  * A corrupt DB fails CLOSED — ``run()`` raises and ``main()`` exits nonzero.
  * No rows are deleted: live counts are identical before and after a run
    (and no test users are purged).
"""

from __future__ import annotations

import os
import sqlite3

import pytest

from backend.scripts import predeploy_backup as pb


def _make_db(path: str, *, users: int, usage: int) -> None:
    """Build a tiny WAL-mode sqlite DB with users/usage_log rows."""
    conn = sqlite3.connect(path)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, device_id TEXT)")
        conn.execute(
            "CREATE TABLE usage_log (id INTEGER PRIMARY KEY, user_id INTEGER)"
        )
        conn.executemany(
            "INSERT INTO users (device_id) VALUES (?)",
            [(f"dev-{i}",) for i in range(users)],
        )
        conn.executemany(
            "INSERT INTO usage_log (user_id) VALUES (?)",
            [(i,) for i in range(usage)],
        )
        conn.commit()
    finally:
        conn.close()


def _live_counts(path: str) -> dict[str, int]:
    conn = sqlite3.connect(path)
    try:
        return {
            "users": conn.execute("SELECT COUNT(*) FROM users").fetchone()[0],
            "usage_log": conn.execute("SELECT COUNT(*) FROM usage_log").fetchone()[0],
        }
    finally:
        conn.close()


def test_fresh_volume_is_noop(tmp_path, capsys):
    """No DB file yet -> no-op, no backup written, exit 0 via main()."""
    db_path = str(tmp_path / "tono.db")

    result = pb.run(db_path)

    assert result == {"backup_path": None, "integrity": "skipped", "counts": {}}
    out = capsys.readouterr().out
    assert "fresh volume" in out
    assert not (tmp_path / "backups").exists()

    # main() reads env and exits 0 on a fresh volume.
    os.environ["TONO_DB_PATH"] = db_path
    with pytest.raises(SystemExit) as exc:
        pb.main()
    assert exc.value.code == 0


def test_happy_path_backup_integrity_and_counts(tmp_path, capsys):
    """An existing DB is backed up consistently, integrity is ok, counts match."""
    db_path = str(tmp_path / "tono.db")
    _make_db(db_path, users=5, usage=9)

    result = pb.run(db_path, now_epoch=1_700_000_000.0)

    # Backup landed under backups/ with the expected timestamp shape.
    assert result["backup_path"] is not None
    assert os.path.exists(result["backup_path"])
    assert os.path.dirname(result["backup_path"]) == str(tmp_path / "backups")
    assert os.path.basename(result["backup_path"]).startswith("tono-")
    assert os.path.basename(result["backup_path"]).endswith(".db")

    assert result["integrity"] == "ok"
    assert result["counts"] == {"users": 5, "usage_log": 9}

    # Evidence is logged for Render to capture.
    out = capsys.readouterr().out
    assert "integrity_check=ok" in out
    assert '"users": 5' in out
    assert '"usage_log": 9' in out

    # The backup is a real, queryable copy of the data (WAL folded in).
    bconn = sqlite3.connect(result["backup_path"])
    try:
        assert bconn.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 5
        assert bconn.execute("SELECT COUNT(*) FROM usage_log").fetchone()[0] == 9
    finally:
        bconn.close()


def test_no_rows_deleted(tmp_path):
    """The run must never delete rows or purge test users."""
    db_path = str(tmp_path / "tono.db")
    _make_db(db_path, users=7, usage=13)

    before = _live_counts(db_path)
    pb.run(db_path, now_epoch=1_700_000_000.0)
    after = _live_counts(db_path)

    assert before == after == {"users": 7, "usage_log": 13}


def test_corrupt_db_fails_closed(tmp_path):
    """A corrupt DB must fail closed: run() raises, main() exits nonzero."""
    db_path = str(tmp_path / "tono.db")
    # Garbage bytes are not a valid sqlite file — opening/backing up will error,
    # which run() surfaces as an exception (fail closed, never a silent pass).
    with open(db_path, "wb") as fh:
        fh.write(b"this is not a sqlite database, it is garbage" * 32)

    with pytest.raises(Exception):
        pb.run(db_path)

    os.environ["TONO_DB_PATH"] = db_path
    with pytest.raises(SystemExit) as exc:
        pb.main()
    assert exc.value.code == 1


def test_corrupt_backup_integrity_fails_closed(tmp_path, monkeypatch):
    """If the backup copy fails integrity_check, run() raises (fail closed).

    We simulate a non-'ok' integrity result so the fail-closed branch is
    exercised even though sqlite's own backup API normally produces a clean
    copy of a valid source.
    """
    db_path = str(tmp_path / "tono.db")
    _make_db(db_path, users=2, usage=2)

    real_connect = sqlite3.connect

    class _BadCheckConn:
        """Wraps the integrity read-back connection to report a non-'ok'
        integrity_check. Not used as a backup target, so it need not be a real
        sqlite3.Connection."""

        def __init__(self, conn):
            self._conn = conn

        def execute(self, sql, *a, **k):
            if "integrity_check" in sql:
                class _Cur:
                    def fetchone(self_inner):
                        return ("*** in database main ***\nmalformed",)

                return _Cur()
            return self._conn.execute(sql, *a, **k)

        def close(self):
            self._conn.close()

    # Only the SEPARATE integrity read-back connection (the 2nd connect to a
    # backups/ path) is wrapped. The backup destination (1st connect) stays a
    # real sqlite3.Connection so conn.backup(dest) still works.
    state = {"backup_path_connects": 0}

    def fake_connect(path, *a, **k):
        conn = real_connect(path, *a, **k)
        if "backups" in str(path) and str(path).endswith(".db"):
            state["backup_path_connects"] += 1
            if state["backup_path_connects"] >= 2:
                return _BadCheckConn(conn)
        return conn

    monkeypatch.setattr(pb.sqlite3, "connect", fake_connect)

    with pytest.raises(RuntimeError):
        pb.run(db_path, now_epoch=1_700_000_000.0)


def test_prune_keeps_last_ten(tmp_path):
    """Retention keeps only the newest 10 backups by mtime."""
    backups_dir = tmp_path / "backups"
    backups_dir.mkdir()
    for i in range(15):
        f = backups_dir / f"tono-2026010{i:02d}T000000Z.db"
        f.write_bytes(b"x")
        os.utime(f, (1_700_000_000 + i, 1_700_000_000 + i))

    pb._prune_backups(str(backups_dir), keep=10)

    remaining = sorted(p.name for p in backups_dir.iterdir())
    assert len(remaining) == 10
