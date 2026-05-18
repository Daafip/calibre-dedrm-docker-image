# Calibre + DeDRM + ADE in Docker — Project Plan

End goal: a reproducible Docker setup that decrypts Adobe ADEPT-DRM'd ePubs (Kobo, library loans, Google Play, etc.) via Calibre's DeDRM plugin, with Adobe Digital Editions running under Wine inside the container. Authorized once, persisted via a host volume, then reused indefinitely.

## Why this setup

- Native Wine setup is fragile and pollutes the host. Container isolates it.
- Authorization is interactive (Adobe ID login in ADE's GUI), so the image cannot be fully pre-baked. First run uses X11 forwarding to authorize; afterwards the prefix lives in a host volume and the container is headless.
- ADE installer cannot be redistributed (Adobe license), so it must be supplied locally — added to the build context, not downloaded at build time.
- This is Adobe ADEPT only. Kindle DRM is a different pipeline (Kindle for PC, different keys). Don't try to do both in one image.

## Prerequisites before starting

- [ ] Native Wine prefix at `~/.wine-ade` has ADE successfully authorized and can open at least one DRM'd book. **Do not skip this.** Proves the recipe works before committing it to a Dockerfile.
- [ ] Docker and Docker Compose installed on the host.
- [ ] `ADE_4.5_Installer.exe` (or `ADE_4.0_Installer.exe` if 4.5 keeps misbehaving) saved locally. Place in `./resources/` of the project.
- [ ] 32-bit Python 3.12 Windows installer (`python-3.12.x.exe`, NOT `-amd64`). Place in `./resources/`.
- [ ] DeDRM plugin zip from https://github.com/noDRM/DeDRM_tools/releases. Place in `./resources/`.
- [ ] Adobe ID credentials ready (or a throwaway Adobe ID — note that Adobe limits ~6 authorizations per ID).

## Recipe being containerized (validated on host first)

This is the chain that worked natively. The Dockerfile must reproduce it exactly:

1. Ubuntu base (use `ubuntu:24.04` — not `eoan`, which is EOL).
2. Enable i386 multilib: `dpkg --add-architecture i386 && apt update`.
3. Install: `calibre`, `wine`, `wine32:i386`, `winetricks`, `winbind` (silences ntlm noise), `xvfb` (for optional headless auth attempts).
4. Create user `calibre`, set `WINEARCH=win32` and `WINEPREFIX=/home/calibre/wineprefix`.
5. First-run setup (entrypoint script, only if prefix empty):
   - `winecfg` to create the 32-bit prefix (or `wineboot --init`).
   - `winetricks -q dotnet40 corefonts tahoma windowscodecs`.
   - Set Windows version to 7: `winetricks -q win7`.
   - Install 32-bit Python: `wine /resources/python-3.12.x.exe /quiet PrependPath=1 Include_doc=0`.
   - Install pycryptodome: `wine python -m pip install pycryptodome`.
   - Install ADE: `wine /resources/ADE_4.5_Installer.exe` (interactive, needs X11).
   - Pause for user to authorize ADE in the GUI and open one DRM'd book.
6. Calibre + DeDRM:
   - Drop DeDRM zip into Calibre's plugins folder, or use `calibre-customize -a /resources/DeDRM_plugin.zip`.
   - Configure plugin's Adobe Wine Prefix setting to `/home/calibre/wineprefix`.

## File layout to scaffold tomorrow

```
calibre-adept-docker/
├── Dockerfile
├── docker-compose.yml
├── README.md
├── entrypoint.sh
├── resources/
│   ├── ADE_4.5_Installer.exe
│   ├── python-3.12.7.exe
│   └── DeDRM_plugin.zip
└── volumes/                  # gitignored
    ├── wineprefix/           # persistent ADE auth + Python
    ├── calibre-config/       # Calibre library + plugin config
    └── books/                # drop DRM'd files here, decrypted ones come out
```

`.gitignore`: `volumes/`, `resources/*.exe`, `resources/*.zip` (don't commit Adobe's installer).

## Build approach — phased

Don't try to write a perfect Dockerfile day one. Each phase is a working stopping point.

### Phase 1 — base image boots and Wine works

- [ ] Dockerfile that installs Calibre + Wine + wine32:i386 + winetricks.
- [ ] Entrypoint just runs `wine --version` and `calibre --version` and exits.
- [ ] `docker build` succeeds, `docker run` prints both versions.

### Phase 2 — prefix bootstrap via entrypoint

- [ ] Entrypoint detects empty `$WINEPREFIX` and runs `wineboot --init`, then `winetricks -q dotnet40 corefonts tahoma windowscodecs win7`.
- [ ] Mount `./volumes/wineprefix` to `/home/calibre/wineprefix`.
- [ ] Run container, watch the dotnet40 install finish. Re-run container — should be instant the second time (prefix already initialized).

### Phase 3 — Python in the prefix

- [ ] Entrypoint installs Python 3.12 32-bit from `/resources/`, then pycryptodome.
- [ ] Add an idempotent check (skip if `wine python --version` already returns 3.x).
- [ ] Verify: `docker exec` into container, run `wine python --version`.

### Phase 4 — ADE install + interactive authorization

- [ ] Entrypoint installs ADE if not already present.
- [ ] Add X11 forwarding to `docker-compose.yml`:
  ```yaml
  environment:
    - DISPLAY=${DISPLAY}
  volumes:
    - /tmp/.X11-unix:/tmp/.X11-unix:ro
  ```
  Plus `xhost +local:docker` on the host before launching (or use `xhost +SI:localuser:$(id -un)` for less permissive).
- [ ] First run: ADE opens, you authorize with Adobe ID, open one DRM'd book, close ADE.
- [ ] Subsequent runs: skip ADE install, prefix already authorized.

### Phase 5 — Calibre + DeDRM wired up

- [ ] Entrypoint installs DeDRM plugin into Calibre if not present.
- [ ] Plugin config (Adobe Wine Prefix path) set programmatically or via README instruction.
- [ ] Launch Calibre via X11 forwarding, import a DRM'd ePub, confirm decryption.

### Phase 6 — polish

- [ ] CLI mode: `docker run ... decrypt /books/foo.epub` that doesn't open the Calibre GUI, just runs `calibre-debug` or `ebook-convert` style commands.
- [ ] README with quickstart, Adobe ID warning, authorization limit note.
- [ ] Healthcheck or smoke test that decrypts a known file on build.

## Known gotchas (already paid for in pain)

- **Wine version on disk must match prefix arch.** `WINEARCH=win32` everywhere. If you ever see `syswow64\ntdll.dll error c0000135`, the prefix accidentally went 64-bit — nuke `volumes/wineprefix/` and start over.
- **Python must be 32-bit.** The filename without `-amd64` is the right one. The DeDRM plugin probes for `python.exe` and rejects non-3.x; PATH must be set during install (`PrependPath=1` flag on silent install).
- **ADE 4.5 has font issues out of the box.** `corefonts` + `tahoma` is mandatory, not optional. Without them ADE crashes in `FontFamily.get_FirstFontFamily()`.
- **Windows version must be 7 or later in the prefix.** Default is XP — ADE 4.5 won't run on XP.
- **ADE 4.5 vs 4.0.3.** If 4.5 refuses to authorize under Wine 9.x, fall back to 4.0.3. Plugin doesn't care which produced the key.
- **`ntlm_auth not found` warnings are noise.** Optional `winbind` install silences them.
- **First Calibre-import failure after setup usually means the plugin's Wine Prefix path is wrong** — must be the absolute container path (`/home/calibre/wineprefix`), not the host path.
- **Adobe authorization limit.** Each Adobe ID can be authorized on ~6 devices. Each fresh container build counts as one if you wipe the volume. Use `Help → Erase Authorization` in ADE before nuking the prefix if iterating.

## Open decisions to make tomorrow

- Run Calibre headless (CLI only) or expose its GUI via X11 / VNC / web (e.g. linuxserver/calibre-style)?
- Single-shot decrypt CLI or persistent Calibre instance?
- Compose vs plain `docker run`? Compose is friendlier given the volume + X11 + env setup.
- Where to keep the ADE installer? Build context (committed `.gitignore`'d) vs host mount only at first run?

## Reference

- DeDRM tools: https://github.com/noDRM/DeDRM_tools
- DeDRM FAQs: https://github.com/noDRM/DeDRM_tools/blob/master/FAQs.md
- vace117 Dockerfile (Kindle, but useful scaffold): https://github.com/vace117/calibre-dedrm-docker-image
- Winetricks docs: https://github.com/Winetricks/winetricks
