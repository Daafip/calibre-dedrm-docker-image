# Calibre DeDRM — Home Assistant Add-on

Watches `/share/calibre-dedrm/input/` for `.acsm` files, decrypts them to DRM-free ePubs using Adobe Digital Editions + Calibre DeDRM under Wine, and writes the output to `/share/calibre-dedrm/books/`.

Optionally pushes each decrypted book to a [send2ereader](../ha-addon-send2ereader/README.md) instance and sends an HA notification with the download code.

> **Architecture note:** Wine only runs on `amd64`. This add-on will not install on Raspberry Pi (aarch64/armv7).

---

## Required files

The add-on image downloads some dependencies at build time. If a download fails (no internet during HA build, CDN unreachable), you must place the files manually in `/share/calibre-dedrm/resources/` on the HA host **before starting the add-on for the first time**.

| File | Where to get it | Build-time auto-download? |
| --- | --- | --- |
| `ADE_4.0.3_Installer.exe` | [Adobe Digital Editions download page](https://www.adobe.com/solutions/ebook/digital-editions/download.html) — use 4.0.3, not 4.5 | Yes (from Adobe CDN) |
| `python-3.12.7.exe` | [python.org/ftp/python/3.12.7](https://www.python.org/ftp/python/3.12.7/python-3.12.7.exe) — **32-bit only**, no `-amd64` in filename | Yes (from python.org) |

Place fallback files here on the HA host:

```
/share/calibre-dedrm/resources/ADE_4.0.3_Installer.exe
/share/calibre-dedrm/resources/python-3.12.7.exe
```

Accessible via SSH, Samba, or the HA File Editor add-on under `/share/calibre-dedrm/resources/`.

---

## First-run setup

First start takes **10–20 minutes**: Wine prefix initialisation, .NET 4.8 (winetricks), Python, and ADE all install from scratch. Subsequent starts are instant — everything is persisted in the add-on's `/data/` volume.

### Authorization

Pick one method:

**A — Headless (recommended for servers/HA):**
Set `adobe_email` and `adobe_password` in the add-on **Configuration** tab. The add-on installs ADE silently, opens it under a virtual display, and automates the Help → Authorize Computer dialog.

**B — Snapshot (most reliable — no credentials needed after first auth):**
Authorize once on any machine using the standalone Docker setup, create a tarball:
```bash
docker compose down
tar -czf wineprefix-authorized.tar.gz -C volumes wineprefix/
```
Copy the tarball to `/share/calibre-dedrm/` on the HA host, then set `wineprefix_snapshot` in the Configuration tab to `/share/calibre-dedrm/wineprefix-authorized.tar.gz`.

**C — Interactive (requires a display, one-time only):**
Not available via the HA add-on. Use the standalone `docker-compose.yml` on a desktop machine instead, then switch to method B.

---

## Configuration options

| Option | Description |
| --- | --- |
| `adobe_email` | Adobe ID email for headless authorization |
| `adobe_password` | Adobe ID password (masked in UI) |
| `wineprefix_snapshot` | Path or `https://` URL to a pre-authorized wineprefix tarball |
| `send2ereader_url` | URL of the send2ereader add-on, e.g. `http://homeassistant.local:3001` |
| `notify_service` | HA notification service name, e.g. `mobile_app_phone` (omit the `notify.` prefix) |

---

## Usage

Drop `.acsm` files into `/share/calibre-dedrm/input/`. The add-on checks every 30 seconds, processes each file, and writes the decrypted ePub to `/share/calibre-dedrm/books/`. Files that fail are renamed to `.failed`.

If `send2ereader_url` is set, the ePub is also pushed there automatically and the short code is logged and optionally sent as an HA notification.

---

## Volume layout

| Path in container | Purpose |
| --- | --- |
| `/data/wineprefix` | Wine prefix — ADE, Python, activation keys. Persisted across restarts. |
| `/data/calibre-config` | Calibre library and DeDRM plugin config |
| `/share/calibre-dedrm/input` | Drop `.acsm` files here |
| `/share/calibre-dedrm/books` | Decrypted ePub output |
| `/share/calibre-dedrm/resources` | Fallback location for ADE and Python installers |

---

## Troubleshooting

**`ERROR: Python 3.12 (32-bit) installer not found`**
The build-time download from python.org failed. Place `python-3.12.7.exe` (not `-amd64`) in `/share/calibre-dedrm/resources/` and restart the add-on.

**`ERROR: No ADE installer found`**
The build-time download from Adobe's CDN failed. Place `ADE_4.0.3_Installer.exe` in `/share/calibre-dedrm/resources/` and restart the add-on.

**`.failed` files in input folder**
ADE could not download the book. Most common causes: ADE is not authorized, or the ACSM has expired (Adobe ACSM files expire after ~60 days). Check the add-on log for details.

**BindImageEx / VCRUNTIME errors in the log during first start**
These are expected Wine noise from the .NET 4.8 post-install optimizer. They do not indicate failure — the installation completes successfully despite them.
