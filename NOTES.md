# Calibre + DeDRM + ADE in Docker — Implementation Notes

Reproducible Docker setup that decrypts Adobe ADEPT-DRM'd ePubs (Kobo, library loans, Google Play, etc.) via Calibre's DeDRM plugin, with Adobe Digital Editions running under Wine inside the container. Authorized once, persisted via host volumes, reused indefinitely.

**Status: complete and working as of 2026-05-18.**

## Why this setup

- Native Wine setup is fragile and pollutes the host. Container isolates it.
- Authorization is interactive (Adobe ID login in ADE's GUI), so the image cannot be fully pre-baked. First run uses X11 forwarding to authorize; afterwards the prefix lives in a host volume and the container is headless.
- ADE installer cannot be redistributed (Adobe license), so it must be supplied locally — added to the build context, not downloaded at build time.
- This is Adobe ADEPT only. Kindle DRM is a different pipeline (Kindle for PC, different keys).

## Working pipeline

1. `xhost +local:docker && docker compose run --rm calibre ade` — open ADE, redeem an ASCM file; the downloaded epub lands in `./volumes/ade-books/`
2. `xhost +local:docker && docker compose run --rm calibre` — open Calibre, add the epub from `/home/calibre/ade-books`; DeDRM strips ADEPT on import automatically
3. `docker compose run --rm calibre decrypt /home/calibre/ade-books/book.epub` — headless CLI alternative; decrypted file goes to `./volumes/books/`

## Volume layout

```
volumes/
├── wineprefix/       # ADE authorization + Python — do not wipe without erasing ADE auth first
├── calibre-config/   # Calibre library and plugin config
├── books/            # CLI decrypt output
├── ade-books/        # ADE My Digital Editions — books downloaded via ASCM land here
└── winetricks-cache/ # speeds up rebuilds that need winetricks
```

## What actually worked vs the original plan

| Topic | Original plan | What was needed |
|---|---|---|
| Base image | ubuntu:24.04 | ubuntu:24.04 ✓ |
| Windows version | win7 | **win10** — Python 3.12 requires Win8+; win7 silently fails the installer |
| winetricks components | dotnet40 corefonts tahoma windowscodecs | **no windowscodecs** — conflicts with Wine 9's built-in WIC; breaks the prefix |
| Python PATH | `PrependPath=1` during installer | **manual `wine reg add HKCU\Environment`** — PrependPath silently fails under Wine |
| Python exe path | drive_c/Python312/python.exe | `drive_c/users/calibre/AppData/Local/Programs/Python/Python312-32/python.exe` |
| DeDRM config file | calibre/plugins/DeDRM.json | **plugins/dedrm.json** (lowercase, one level up) |
| Wine Gecko | assumed present | must pre-fetch `wine_gecko-2.47.4-x86.msi`; CDN unreliable at build time so wrapped in `|| true` |
| UID pinning | create calibre at 1000 | Ubuntu 24.04 pre-creates `ubuntu` at UID 1000 — must `userdel` it first |
| X11 / MIT-SHM crash | not anticipated | `ipc: host` in docker-compose + `libgl1:i386` in image |
| ADE books access | not anticipated | dedicated `ade-books` volume + symlink `/home/calibre/ade-books` created in entrypoint |

## Gotchas

- **Wine prefix must stay win32.** `WINEARCH=win32` everywhere. `syswow64\ntdll.dll error c0000135` = prefix went 64-bit — erase ADE auth first (`Help → Erase Authorization`), then delete `volumes/wineprefix/`.
- **Python must be 32-bit.** Installer without `-amd64` in the filename. DeDRM's `WinePythonCLI` looks for `python.exe` by name; the Windows PATH registry entry must exist.
- **`corefonts` + `tahoma` are mandatory.** ADE crashes in `FontFamily.get_FirstFontFamily()` without them.
- **win10 mode required.** ADE needs Win7+, Python 3.12 needs Win8+. win10 satisfies both.
- **`windowscodecs` must be omitted.** Wine 9 ships its own WIC; the native override breaks the prefix.
- **ADE 4.5 vs 4.0.3.** If 4.5 refuses to authorize under Wine 9.x, rebuild with `ADE_4.0.3_Installer.exe`. The plugin doesn't care which version produced the key.
- **Adobe authorization limit.** ~6 devices per Adobe ID. Use `Help → Erase Authorization` in ADE before wiping `volumes/wineprefix/`.
- **`ntlm_auth not found` warnings are noise** — silenced by the `winbind` package.
- **First Calibre import failure after setup** usually means `adobewineprefix` in `plugins/dedrm.json` is wrong. Must be the container path `/home/calibre/wineprefix`.

## Reference

- [noDRM DeDRM_tools](https://github.com/noDRM/DeDRM_tools)
- [DeDRM FAQs](https://github.com/noDRM/DeDRM_tools/blob/master/FAQs.md)
- [Winetricks](https://github.com/Winetricks/winetricks)
