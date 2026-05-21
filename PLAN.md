# Headless ADE Authorization — Project Plan

End goal: eliminate the interactive X11 + GUI step from the Docker setup so the container can be built, deployed, and re-authorized purely from environment variables (Adobe ID + password). Keeps the existing working Wine + ADE + DeDRM pipeline intact — only the authorization step changes.

## Why this matters

- Current pipeline still needs `xhost +local:docker` + X11 forwarding + manual click-through in ADE for first-time auth.
- Home Assistant deployment is headless. No display, no clicking. Auth has to be re-doable without a human.
- Also useful for: rebuilding the volume cleanly, recovering after Adobe forces a re-auth, redeploying to a new host, sharing the setup with others.

## Two strategies (do both, in order)

### Strategy 1 — Snapshot the authorized prefix (quick win)

Auth once interactively (already done), capture the resulting state, treat it as a deployable artifact. Doesn't solve "auth from creds" but does solve "deploy to HA without X11."


## Strategy 1 — Authorized prefix snapshot

### Concept

The `volumes/wineprefix/` directory after authorization contains everything needed for DeDRM to work: ADE installation, activation files, device salt, Windows registry hive entries. It's portable across machines with the same Wine version.

### Steps

- [ ] Verify the current authorized prefix actually decrypts books end-to-end. Smoke test before snapshotting.
- [ ] Stop the container: `docker compose down`.
- [ ] Tar the prefix: `tar -czf wineprefix-authorized.tar.gz -C volumes wineprefix/`.
- [ ] Sanity check size — should be a few hundred MB. If much larger, something's leaked in (e.g. cache, downloaded books).
- [ ] Store the tarball somewhere safe (encrypted backup, private repo, NAS). **Treat as secret** — it contains the device key tied to your Adobe ID.
- [ ] Add an `entrypoint.sh` branch: if `$WINEPREFIX` is empty AND `$WINEPREFIX_SNAPSHOT_URL` (or local path) is set, extract the tarball into the volume on first run.
- [ ] Test: delete `volumes/wineprefix/`, run the container, watch it restore from snapshot, decrypt a book, confirm it works.

### What this gets you

- HA deployment is now headless: SCP the tarball, point env var at it, `docker compose up`. Done.
- No X11 ever again — until Adobe forces a re-auth (rare, but happens).
- Tarball is the only thing you need to back up.

### What this doesn't get you

- If Adobe ever invalidates the device, you're back to needing X11 to re-auth, OR you implement Strategy 2.
- Can't easily rotate Adobe ID or onboard a new one without going back to the GUI.

### Risks

- Adobe authorization tracks device fingerprints. Wine's fingerprint is fairly stable across hosts, but moving the tarball to a wildly different environment could (in theory) trigger a re-auth. Test on the actual HA host before relying on it.
- ~6-device limit per Adobe ID still applies. Keep the snapshot rather than re-authing repeatedly.

---
- DeDRM `adobekey.py` (Windows extraction): https://github.com/noDRM/DeDRM_tools/blob/master/DeDRM_plugin/adobekey.py
- ADE Windows file locations: `%APPDATA%\Adobe\Adobe Digital Editions\` and `HKCU\Software\Adobe\Adept`
