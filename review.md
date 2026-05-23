# Repository Critical Review
_Generated 2026-05-23_

---

## Critical (will break things)

**1. `set -euo pipefail` + unguarded `calibredb` calls**
In `ha-addon/run.sh` lines 197–198, `calibredb add` and `calibredb export` have no `|| true` or conditional guard. Under `set -e`, any non-zero exit from calibredb kills the entire script — the addon dies and stops processing. Every other failure in `process_acsm` uses `return`, but these two don't. Fix: wrap in `if ! calibredb ...; then ... return; fi`.

**2. send2ereader patch regex is fragile and silent**
In `ha-addon-send2ereader/Dockerfile` line 9, the UA-check removal regex `/if\s*\(info\.agent\s*!==.*\)[^}]+\}/g` breaks silently if the upstream code ever wraps that block across multiple lines or adds a nested brace. The regex fails, the patch is skipped without error, the UA check stays in, and Kobo downloads start failing again with no indication why.

**3. `notify_service` vs `notify_services` mismatch in test-data/options.json**
The file still has `"notify_service": ""` (singular) after the rename to `notify_services`. In test mode jq silently returns empty and notifications are dead.

---

## Medium (reliability / maintenance risk)

**4. libgourou and send2ereader both float on HEAD**
Both `git clone --depth 1` with no tag or commit SHA. A breaking upstream commit silently ships in the next image build. libgourou especially — it's a small project that doesn't follow semver carefully.

**5. `find_plugin` calls `exit 1` on download failure**
`ha-addon/run.sh` line 82 — if the DeDRM download fails and no local zip is available, the function does `exit 1`, killing the entire addon on startup rather than logging a warning and continuing. The addon can still activate and be ready to process books; it just won't have DeDRM installed yet.

**6. No file size limit on upload_server.py**
The server reads `Content-Length` bytes with no upper bound. A client can send a multi-gigabyte payload and exhaust `/share` disk space. Simple fix: check `length > MAX_SIZE` before reading.

**7. Email only supports STARTTLS (port 587)**
`ha-addon/send_email.py` hardcodes `smtplib.SMTP` + STARTTLS. Providers using implicit SSL on port 465 (`smtplib.SMTP_SSL`) are unsupported and will time out with no clear error. Gmail works; self-hosted or office SMTP servers often use 465.

**8. Email attachment size — no check**
ePubs can be 20–50 MB. Gmail's limit is 25 MB; many providers reject larger. The script attempts the send and fails with a cryptic SMTP error. A pre-flight size check with a clear log message would be much friendlier.

**9. Dead code: standalone Wine/ADE stack**
The root `Dockerfile`, `entrypoint.sh`, `docker-compose.yml`, and `bin/launch_book_manager.sh` are the old Wine/ADE stack, never referenced by the HA addon build. They'll quietly bit-rot and confuse anyone reading the repo. Either delete them or move to a clearly marked `legacy/` directory.

---

## Low (cosmetic / minor)

**10. SMTP password visible in container environment**
`SMTP_PASS="$SMTP_PASS" python3 /send_email.py` — env vars are readable from `/proc/<pid>/environ` by root inside the container. Not a significant threat in a home HA install.

**11. `dedrm.json` marker contains stale Wine fields**
The local `volumes/calibre-config/plugins/dedrm.json` has `"adobewineprefix": "/home/calibre/wineprefix"` from the old stack. File is gitignored so it doesn't ship; the marker written by run.sh is clean. No action needed.

**12. Poll interval is hardcoded at 30 seconds**
Not a real problem for home use, but making it a config option would cost two lines.

**13. PLAN.md is stale**
Describes the send2ereader integration as a future plan — it's been done. Either delete it or update it.

---

## Summary

| # | Issue | Severity | Fix effort |
|---|---|---|---|
| 1 | `calibredb` unguarded under `set -e` | Critical | 5 min |
| 2 | send2ereader patch regex silent failure | Critical | 10 min |
| 3 | `notify_service` typo in test fixture | Critical | 1 min |
| 4 | No version pinning (libgourou, send2ereader) | Medium | 10 min |
| 5 | `find_plugin` exits addon on download fail | Medium | 5 min |
| 6 | No upload size limit | Medium | 5 min |
| 7 | SMTP: no SSL/465 support | Medium | 15 min |
| 8 | No email size check | Medium | 5 min |
| 9 | Dead Wine/ADE code in repo root | Medium | 5 min |
| 10 | SMTP password in process environment | Low | — |
| 11 | Stale `adobewineprefix` in local dedrm.json | Low | — |
| 12 | Poll interval hardcoded | Low | 2 min |
| 13 | PLAN.md stale | Low | 1 min |
