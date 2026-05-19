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
# Allow Docker to use the host display
xhost +local:docker

# Build the image
docker compose build

# Run first-time setup (Wine prefix initialization + ADE install)
docker compose run --rm calibre
```

The entrypoint will automatically:
1. Initialize a 32-bit Wine prefix
2. Install `dotnet48`, `corefonts`, `tahoma` and set Windows 10 mode via winetricks
3. Install Python 3.12 (32-bit) and `pycryptodome`
4. Install Adobe Digital Editions (a GUI window will open)
5. Pause and ask you to authorize ADE with your Adobe ID and open one DRM'd ebook
6. Install and configure the DeDRM and Obok plugins into Calibre

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
docker compose run --rm calibre dedrm /home/calibre/ade-books/book.acsm /home/calibre/ade-books
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
docker compose run --rm calibre decrypt /home/calibre/ade-books/input.epub
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

## References

- [noDRM DeDRM_tools](https://github.com/noDRM/DeDRM_tools)
- [DeDRM FAQs](https://github.com/noDRM/DeDRM_tools/blob/master/FAQs.md)
- [Winetricks](https://github.com/Winetricks/winetricks)


## example 

```bash
docker compose run --rm calibre dedrm /home/calibre/ade-books-input/de_machtscode.acsm
``` 