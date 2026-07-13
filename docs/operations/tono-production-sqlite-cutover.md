# Tono production SQLite preservation and durable-volume cutover

Status: snapshot and isolated restore complete; production volume cutover NOT executed.

This runbook is intentionally metadata-only. It contains no bearer tokens, secrets, or row-level data.

## Frozen production target

- Railway project ID: `132d893b-4716-431c-a8e9-1cfae5e9fa99`
- Environment: `production` (`7b5aa002-28e6-4c02-b606-026751c6d797`)
- Service: `tono-backend` (`2439a0aa-f8c1-44c6-8694-674213aaf367`)
- Pre-change deployment: `c401af7b-7d01-419e-ab10-3d533f8736c7`
- SQLite path: `/data/tono.db`
- Pre-change volume inventory: none

Do not redeploy, restart, or attach a volume until the snapshot and isolated-restore evidence below has been independently reviewed.

## Backup identity and encryption

- Backup ID: `tono-prod-20260713T205422Z-bb89fa4f`
- Encrypted artifact: `/Users/Ezra/Backups/tono-production/tono-prod-20260713T205422Z-bb89fa4f.tar.gz.enc`
- Cipher: AES-256-CBC, PBKDF2, 600,000 iterations, random salt
- Ciphertext SHA-256: `fc1a385e9b01e6327843ccf8655c0ba200826693ea6d14fa50527738792d1d29`
- Ciphertext bytes: `4432`
- Key location: macOS login Keychain service `tono-sqlite-backup-tono-prod-20260713T205422Z-bb89fa4f`, account equal to the local macOS user
- File mode verified: `0600`

The encrypted archive contains the downloaded `/data/tono.db`, `/data/tono.db-wal`, and `/data/tono.db-shm` set. Opening the isolated copy with SQLite replayed/checkpointed the downloaded WAL into the database; no production checkpoint or mutation was performed.

## Isolated restore evidence

- `PRAGMA integrity_check`: `ok`
- Schema SHA-256 before/after encrypted round-trip: `1d537e8eedfd22700aa8565b3372a783cc1026e638b342d7a3de78587aa91f60`
- Schema match: true
- Aggregate table-count match: true
- Restored aggregate counts: accounts 0; axis_events 0; coupon_redemptions 0; coupons 0; feature_flags 8; improvement_events 0; response_cache 0; slack_workspaces 0; stripe_events 1; usage_log 0; user_feature_overrides 0; users 2; webauthn_credentials 0.
- Temporary plaintext snapshot and restore files were truncated to zero bytes after verification; the encrypted artifact and Keychain item are the retained recovery materials.

## Decrypt into an isolated temporary directory

Run only on the trusted Mac that owns the Keychain item:

```bash
set -euo pipefail
BACKUP_ID=tono-prod-20260713T205422Z-bb89fa4f
RESTORE="$(mktemp -d /private/tmp/tono-restore.XXXXXX)"
umask 077
security find-generic-password -a "$USER" -s "tono-sqlite-backup-$BACKUP_ID" -w > "$RESTORE/key"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in "/Users/Ezra/Backups/tono-production/$BACKUP_ID.tar.gz.enc" -out "$RESTORE/snapshot.tar.gz" -pass file:"$RESTORE/key"
tar -C "$RESTORE" -xzf "$RESTORE/snapshot.tar.gz"
sqlite3 "$RESTORE/tono.db" 'PRAGMA integrity_check;'
```

Do not print rows. Reconcile schema and aggregate counts only.

## Production cutover (Ezra approval required)

Gary must not execute this infrastructure change or redeploy without Ezra approval. The safe sequence is pre-seed-first: create a temporary production seeder service, attach a new volume to that seeder, upload the restored database set to the volume, detach it, and only then attach the already-populated volume to `tono-backend` at `/data`. Attaching an empty volume directly to `tono-backend` would hide the ephemeral `/data` and lose the live state.

Run from the linked Railway project after decrypting the backup and rechecking integrity/counts:

```bash
set -euo pipefail
PROJECT_ID=132d893b-4716-431c-a8e9-1cfae5e9fa99
ENVIRONMENT=production
TARGET_SERVICE=2439a0aa-f8c1-44c6-8694-674213aaf367
SEEDER_JSON="$(railway add --service tono-volume-seeder --json)"
SEEDER_ID="$(printf '%s' "$SEEDER_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
VOLUME_JSON="$(railway volume -p "$PROJECT_ID" -e "$ENVIRONMENT" -s "$SEEDER_ID" add -m /data --json)"
VOLUME_ID="$(printf '%s' "$VOLUME_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
railway volume -p "$PROJECT_ID" -e "$ENVIRONMENT" files -v "$VOLUME_ID" upload "$RESTORE/tono.db" /tono.db --overwrite --json
railway volume -p "$PROJECT_ID" -e "$ENVIRONMENT" files -v "$VOLUME_ID" upload "$RESTORE/tono.db-wal" /tono.db-wal --overwrite --json
railway volume -p "$PROJECT_ID" -e "$ENVIRONMENT" files -v "$VOLUME_ID" upload "$RESTORE/tono.db-shm" /tono.db-shm --overwrite --json
railway volume -p "$PROJECT_ID" -e "$ENVIRONMENT" detach -v "$VOLUME_ID" -y --json
railway volume -p "$PROJECT_ID" -e "$ENVIRONMENT" update -v "$VOLUME_ID" -m /data --json
railway volume -p "$PROJECT_ID" -e "$ENVIRONMENT" -s "$TARGET_SERVICE" attach -v "$VOLUME_ID" -y --json
```

Before executing, confirm the exact JSON keys returned by the installed Railway CLI (`5.23.0`) in a non-production rehearsal. Record the production volume ID and deployment ID immediately after attachment. Do not delete the seeder service or backup until independent QA passes.

## Required post-cutover checks

1. `railway volume list --json` shows the new production volume in `READY` state, mounted to `tono-backend` at `/data`.
2. `/health` is 200.
3. Read-only production SQLite inspection reports `PRAGMA integrity_check = ok`, the same schema hash, and no unexplained aggregate count delta.
4. Verify representative existing auth and paid/entitlement state without placing tokens or row data in logs.
5. Restart the existing deployment, repeat checks 1–4, and record the deployment ID.
6. Redeploy the exact same image/deployment, repeat checks 1–4, and record the deployment ID.
7. Sherlock independently validates the encrypted backup, isolated restore, mount, persistence, and rollback evidence.

## Rollback

Preferred rollback is volume swap, not an empty ephemeral filesystem. Pre-seed a second rollback volume from backup ID `tono-prod-20260713T205422Z-bb89fa4f`, verify it while detached, then atomically swap attachments:

```bash
railway volume -p 132d893b-4716-431c-a8e9-1cfae5e9fa99 -e production -s 2439a0aa-f8c1-44c6-8694-674213aaf367 detach -v "$BAD_VOLUME_ID" -y --json && railway volume -p 132d893b-4716-431c-a8e9-1cfae5e9fa99 -e production -s 2439a0aa-f8c1-44c6-8694-674213aaf367 attach -v "$ROLLBACK_VOLUME_ID" -y --json
```

After the swap, require `/health`, SQLite integrity, schema hash, aggregate count, auth, paid/entitlement, and idempotency checks before declaring recovery. Preserve both volumes until Sherlock signs off.
