# Implementation Notes

**Status: working as of 2026-05-22.**

## Architecture decision: libgourou instead of Wine + ADE

The original implementation ran Adobe Digital Editions 4.0.3 under Wine with dotnet48. It worked but was fragile:

- First run took 10–20 minutes (winetricks + Python + ADE install)
- dotnet48 bakes absolute CLR paths into the prefix at install time — the prefix cannot be copied to a different path, making pre-built snapshots useless
- ADE headless authorization via xdotool broke every time Wine's .NET initialization diverged slightly
- Root cause: Wine's .NET CLR initialization is non-deterministic when used headlessly

**libgourou** is a native Linux C++ implementation of the Adobe ADEPT protocol. It replaces the entire Wine stack:

| Old | New |
| --- | --- |
| Wine + dotnet48 + ADE | libgourou (C++, no Wine) |
| xdotool GUI automation | `adept_activate -u email -p password` |
| ADE ACSM download | `acsmdownloader -f book.acsm` |
| ADE + DeDRM plugin | `adept_remove -f enc.epub -o clean.epub` |
| 10–20 min first run | ~5 second activation |

## Building libgourou

libgourou uses a plain Makefile (not CMake). `scripts/setup.sh` clones the uPDFParser dependency. Two gotchas:

1. **Run `setup.sh` before parallel make.** `make -j$(nproc)` starts compiling `libgourou.cpp` in parallel with `setup.sh` cloning uPDFParser. The header `uPDFParser.h` isn't ready yet → build fails. Fix: run `./scripts/setup.sh` explicitly first, then `make -j$(nproc)`.

2. **Alpine BusyBox sed does not support `,+N` relative addresses.** `sed '/pattern/,+3d'` silently breaks on Alpine. Use `node -e` to patch JS files instead.

## Activation persistence

libgourou stores activation data in `~/.config/adept/`. The addon symlinks `/root/.config/adept` → `/data/adept/` so the data survives container restarts.

A failed activation (wrong credentials) writes a partial `activation.xml` containing only service URLs — no `<adept:user>` element. Checking for file existence is not sufficient; the correct check is:

```bash
grep -q 'adept:user' "$ADEPT_DIR/activation.xml" 2>/dev/null
```

If this check fails on startup, activation runs again regardless of whether the file exists.

## send2ereader integration

send2ereader is designed for the receiving device (Kobo) to generate a code and display it, then a sender uploads to that code. Our flow is the reverse: the addon generates the code and uploads the book, then the user enters the code on the Kobo.

Three patches applied to `index.js` at build time via the Dockerfile:

| Patch | Why |
| --- | --- |
| `expireDelay: 30 → 600` | 30 seconds is not enough time to open a Kobo browser and type a code |
| Remove UA check in `downloadFile` | The download UA (Kobo browser) will never match the generator UA (curl from the addon) |
| Remove UA check in `/status/:key` | Same reason — Kobo polls status but the key was created by curl |

The UA check in the original code is a security measure for the public send.djazz.se instance to prevent hotlinking. For a self-hosted local server it is unnecessary.

A fourth patch adds a code-entry form to `static/download.html`. Without it the Kobo page only shows the code it generated for itself (waiting for someone to send to it); there is no way to enter an incoming code from the addon. The patch adds an input field + "Get book" button below the existing display. Entered code is validated against `/status/` and if a file is found, the download link appears.

## send2ereader upload API

The `/upload` endpoint returns plain text (the success message), not JSON. Checking HTTP status `200` is the correct success signal. The upload response does not include the download URL — it must be constructed from the epub filename and the key:

```
http://<server>:<port>/<URL-encoded filename>?key=<CODE>
```

The `/status/:key` response includes `urls: []` (empty) because the server has no configured base URL. The download.html JavaScript falls back to constructing the URL from `window.location.origin` — but for the Kobo this is irrelevant since we send the pre-constructed URL in the addon logs and the user types the 4-char code on the Kobo manually.

## DeDRM marker check

The marker file `$CALIBRE_CONFIG_DIRECTORY/plugins/dedrm.json` is created after installing the DeDRM and Obok plugins so installation only runs once. The marker contains a minimal valid DeDRM config (no Wine-specific `adobewineprefix` field needed since libgourou handles decryption directly).

## Docker Compose test stack

`docker-compose.test.yml` provides three services:

- `base` — builds the base image (compiles libgourou), exits immediately
- `addon` — mounts `test-data/` directories in place of HA's `/data/` and `/share/`
- `send2ereader` — runs the patched send2ereader server on port 3001

`test-data/` contents (all gitignored):

| Path | Purpose |
| --- | --- |
| `options.json` | Adobe ID credentials |
| `adept/` | Persisted activation data |
| `calibre-config/` | Calibre plugin state |
| `input/` | Drop `.acsm` files here |
| `books/` | Decrypted output |
| `resources/` | `DeDRM_Plugin.zip`, `Obok_plugin.zip` |

## Path layout inside the addon container

| Path | Contents |
| --- | --- |
| `/data/options.json` | HA-injected addon config |
| `/data/adept/` | libgourou activation (symlinked from `/root/.config/adept/`) |
| `/data/calibre-config/` | Calibre plugin config and DeDRM marker |
| `/resources/` | DeDRM/Obok plugin zips (built into base image) |
| `/share/calibre-dedrm/input/` | ACSM input watch directory |
| `/share/calibre-dedrm/books/` | Decrypted ePub output |
| `/share/calibre-dedrm/resources/` | User-supplied plugin zips (fallback if `/resources/` is empty) |
