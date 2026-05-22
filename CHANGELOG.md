# Changelog

## [1.1.0] - 2026-05-22

### Added
- Browser-based ACSM upload UI via HA ingress (no more manual file drops)
- send2ereader integration: auto-push decrypted ePub and show short code in logs
- HA notification support (`notify_service`) — book ready alert with download URL
- Headless ADE authorization via `adobe_email` / `adobe_password` config options
- Wineprefix snapshot restore from local path or HTTPS URL (`wineprefix_snapshot`)
- Timestamps on all addon log lines
- Version printed at startup (`>>> Addon version: 1.1.0`)

### Fixed
- DeDRM `find_plugin` now uses `find` instead of `ls` glob — reliably finds installers on `/share/` even when `/resources/` is empty
- Wine installers copied to `/tmp` before execution — fixes `ShellExecuteEx failed` on network/FUSE mounts
- Wineprefix snapshot `tar` extraction uses `--no-same-owner` + `chown -R root` — fixes `wine: not owned by you` when snapshot was made from a non-root user
- send2ereader upload uses `POST /generate` cookie session — fixes `Unknown key` rejection
- Xvfb keysym warnings suppressed from addon logs

### Changed
- Base image (`calibre-dedrm-base`) pre-downloads all installers at build time — first run no longer needs internet access for DeDRM, Python, or ADE
- Wine prefix built from scratch on first run (dotnet48 pre-baking was removed — it broke .NET CLR initialization after copying to a different path)
- ADE startup window detection timeout increased from 30 s to 60 s; prints all visible window titles if timeout expires

## [1.0.0] - initial release

- ACSM → DRM-free ePub pipeline via ADE 4.0.3 + Calibre DeDRM under Wine
- Watches `/share/calibre-dedrm/input/` every 30 s
- Output to `/share/calibre-dedrm/books/`
- send2ereader addon: self-hosted short-code ePub delivery to Kobo
