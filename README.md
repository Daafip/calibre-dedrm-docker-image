# Calibre + DeDRM + Adobe Digital Editions in Docker

Decrypts Adobe ADEPT-DRM'd ePubs (Kobo, library loans, Google Play Books, etc.) using Calibre's DeDRM plugin with Adobe Digital Editions running under Wine inside the container.

**What this does not cover:** Kindle DRM is a separate pipeline (Kindle for PC, different keys). This image is ADEPT only.

## Prerequisites

Before building the image, place the following files in `./resources/`:

| File | Where to get it |
| --- | --- |
| `ADE_4.5_Installer.exe` | Adobe's [Digital Editions download page](https://www.adobe.com/solutions/ebook/digital-editions/download.html). Use 4.0.3 if 4.5 refuses to authorize under Wine 9.x. |
| `python-3.12.x.exe` | [python.org](https://www.python.org/downloads/windows/) — **must be the 32-bit installer** (no `-amd64` in the filename) |

`DeDRM_Plugin.zip` and `Obok_plugin.zip` are already included in the repo.

You also need:

- Docker and Docker Compose installed on the host
- An Adobe ID (free). Note: Adobe limits each ID to ~6 device authorizations. Use **Help → Erase Authorization** in ADE before wiping the volume if you iterate.

## First-time setup

```bash
docker compose build
```

Then authorize ADE using whichever method fits your environment:

### Option A — headless (servers, Home Assistant, no display)

Set credentials in a `.env` file (keep this file out of version control):

```ini
ADOBE_EMAIL=you@example.com
ADOBE_PASSWORD=yourpassword
```

Then run:

```bash
docker compose run --rm calibre
```

The entrypoint installs ADE silently, opens it under a virtual framebuffer, navigates to **Help → Authorize Computer**, fills in your credentials automatically, and waits for Adobe's servers to confirm. If it works, the prefix is authorized and you never need a display again.

> **Note:** The xdotool automation depends on ADE's menu layout. If it fails, fall back to Option B or C.

### Option B — interactive (desktop, first time only)

```bash
xhost +local:docker
docker compose run --rm calibre ade
# ADE opens — go to Help → Authorize Computer, sign in with Adobe ID
```

### Option C — snapshot restore (re-deploy from an already-authorized setup)

If you've already authorized on one machine, snapshot the prefix and deploy it anywhere without credentials or a display:

```bash
# 1. On the authorized machine — create the snapshot
docker compose down
tar -czf wineprefix-authorized.tar.gz -C volumes wineprefix/
# Store the tarball somewhere safe — it contains your device key.
# Treat it as a secret (equivalent to having your Adobe ID authorized).
```

```bash
# 2. On the target machine — restore from snapshot
# Mount the tarball or use a URL:
WINEPREFIX_SNAPSHOT=/path/to/wineprefix-authorized.tar.gz docker compose run --rm calibre dedrm ...
# or set it in .env / docker-compose.yml environment
```

The snapshot is extracted on the first run when `./volumes/wineprefix/` is empty, then all subsequent runs skip the restore. The tarball is ~300 MB.

---

Regardless of which option you use, the entrypoint automatically:

1. Initializes a 32-bit Wine prefix
2. Installs `dotnet48`, `corefonts`, `tahoma`, sets Windows 10 mode
3. Installs Python 3.12 (32-bit) and `pycryptodome`
4. Installs Adobe Digital Editions silently
5. Installs and configures the DeDRM and Obok plugins into Calibre

After setup completes, the Wine prefix and Calibre config are persisted in `./volumes/` and reused on every subsequent run.

## Usage

### Full pipeline: ASCM → decrypted epub (one command)

Drop the `.acsm` file into `./volumes/ade-books/`, then:

```bash
docker compose run --rm calibre dedrm /home/calibre/ade-books-input/book.acsm
```

This opens ADE in the background, waits for the download to complete, kills ADE, then decrypts the epub via DeDRM. The decrypted file lands in `./volumes/books/`.

Optional second argument to change the output directory:

```bash
docker compose run --rm calibre dedrm /home/calibre/ade-books-input/book.acsm /home/calibre/ade-books-input
```

### Open ADE manually (e.g. to authorize or browse your library)

```bash
xhost +local:docker
docker compose run --rm calibre ade
```

### Launch Calibre GUI

```bash
xhost +local:docker
docker compose run --rm calibre
```

### Decrypt an already-downloaded epub

```bash
docker compose run --rm calibre decrypt /home/calibre/ade-books-input/input.epub
```

### Open a shell inside the container

```bash
docker compose run --rm calibre shell
```

## Volume layout

```text
volumes/
├── wineprefix/       # ADE authorization + Python — do not wipe without erasing ADE auth first
├── calibre-config/   # Calibre library and plugin config
├── books/            # Decrypted output
├── ade-books/        # Drop .acsm files here; ADE downloads epubs here too
└── winetricks-cache/ # Speeds up rebuilds
```

## Known gotchas

- **Wine prefix must stay win32.** `WINEARCH=win32` everywhere. If you see `syswow64\ntdll.dll error c0000135`, the prefix went 64-bit — erase ADE auth first (`Help → Erase Authorization`), then delete `volumes/wineprefix/` and start over.
- **Python must be 32-bit.** The `-amd64` filename is wrong. DeDRM probes for `python.exe` and rejects non-3.x; the Windows PATH registry entry must be set correctly.
- **`corefonts` + `tahoma` are mandatory.** Without them ADE crashes in `FontFamily.get_FirstFontFamily()`.
- **Windows 10 mode is required.** ADE needs Win7+, Python 3.12 needs Win8+. Win10 satisfies both.
- **`windowscodecs` must not be installed.** Wine 9 ships its own WIC; the native override breaks the prefix.
- **ADE 4.5 vs 4.0.3.** If 4.5 refuses to authorize under Wine 9.x, rebuild with `ADE_4.0.3_Installer.exe`. The plugin doesn't care which version produced the key.
- **`ntlm_auth not found` warnings are noise** — silenced by the `winbind` package in the image.
- **First Calibre import failure after setup** usually means the plugin's Wine Prefix path is wrong. It must be the container path `/home/calibre/wineprefix`, not the host path.

## Home Assistant addon

The `ha-addon/` directory contains a Home Assistant addon that runs as a persistent service, watching `/share/calibre-dedrm/input` for `.acsm` files and decrypting them automatically.

**Architecture note:** Wine only runs on `amd64`. The addon will not install on Raspberry Pi or other ARM devices.

### Install

1. In HA → **Settings → Add-ons → Add-on Store** → three-dot menu → **Repositories**, add the URL of this GitHub repo.
2. Find "Calibre DeDRM" in the store and install it.
3. Before starting, place `ADE_4.0.3_Installer.exe` (from Adobe's website) in `/share/calibre-dedrm/resources/` on the HA host.
4. Configure the addon (see below), then start it.

First start takes 10-20 minutes: winetricks, Python, and ADE all install from scratch. Subsequent starts are instant (data persists in the addon's `/data/` volume).

### Configuration

In the addon's **Configuration** tab:

| Option | Description |
| --- | --- |
| `adobe_email` | Adobe ID email — used for headless ADE authorization |
| `adobe_password` | Adobe ID password — leave empty if using a snapshot |
| `wineprefix_snapshot` | Path or URL to a pre-authorized wineprefix tarball (see snapshot instructions above) |

The snapshot path must be accessible inside the container, e.g. `/share/calibre-dedrm/wineprefix-authorized.tar.gz` if you placed the file in `/share/calibre-dedrm/` on the HA host.

### Usage

Drop `.acsm` files into `/share/calibre-dedrm/input/` (accessible from the HA host at `/share/calibre-dedrm/input/` or via the Samba/SSH addon). The addon processes each file within 30 seconds and writes the decrypted ePub to `/share/calibre-dedrm/books/`. Failed files are renamed to `.failed`.

## Links

- [noDRM DeDRM_tools](https://github.com/noDRM/DeDRM_tools)
- [DeDRM FAQs](https://github.com/noDRM/DeDRM_tools/blob/master/FAQs.md)
- [Winetricks](https://github.com/Winetricks/winetricks)
