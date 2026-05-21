# HA Add-on with Web Upload UI — Project Plan

End goal: a Home Assistant Add-on that exposes a web interface where ACSM files can be dropped (drag-drop or file picker), the existing Wine + ADE + DeDRM pipeline runs headlessly, and decrypted ePubs land in a folder HA can see. Shows up as a sidebar tab in HA, no separate auth, no separate URL to remember.

Builds on top of the working Docker container and the headless-auth plan.

## What "HA app" means here

"HA Add-on" specifically — a Docker container managed by the HA Supervisor, with these benefits over a standalone container:

- Lives in HA's sidebar (ingress UI), accessed at `http://homeassistant.local:8123` like everything else
- Inherits HA auth — no separate login
- Read/write access to HA's `/media`, `/share`, `/config`, `/addons` volumes
- Managed lifecycle: install/start/stop/update via HA UI
- Logs visible in HA UI
- Config via HA UI (env vars, options)

Distinct from an HA *Integration* (Python module inside HA core that talks to a device/service) and an HA *Custom Component* (same, distributed via HACS). Add-on is the right shape for "a service with a web UI."

## Architecture

```
┌──────────────────────────────────────────────┐
│  Home Assistant                              │
│  ├─ Sidebar: "ADE Decrypt"                   │
│  └─ Ingress → port 8000 in add-on            │
└──────────────────────────────────────────────┘
                    │
                    ▼
┌──────────────────────────────────────────────┐
│  ADE Decrypt Add-on (Docker container)       │
│  ├─ FastAPI web server (port 8000)           │
│  │   ├─ GET  /          → upload page        │
│  │   ├─ POST /upload    → accept ACSM        │
│  │   ├─ GET  /jobs/{id} → status / result    │
│  │   └─ GET  /history   → past jobs          │
│  ├─ Job runner (subprocess / background)     │
│  │   └─ Calls existing CLI:                  │
│  │       acsm → fulfill → decrypt → output   │
│  ├─ Wine prefix (authorized) — volume        │
│  └─ Calibre + DeDRM plugin                   │
│                                              │
│  Reads:  /media/inbox (optional drop folder) │
│  Writes: /media/books (decrypted output)     │
└──────────────────────────────────────────────┘
```

Two ingestion paths, both supported:
- **Web UI**: user drops file in browser, gets immediate feedback.
- **Folder watcher**: drop ACSM into `/media/inbox` via HA's Samba/file editor, add-on picks it up via inotify. Useful for HA automations (e.g. "when email arrives with .acsm attachment, save to inbox").

## Tech choices

- **Web framework**: FastAPI. Async, swagger UI free, modern. Flask is fine too — pick whichever you're faster in. For a single-form-and-some-routes app, the difference is negligible.
- **Frontend**: Server-rendered HTML + a tiny bit of JS for drag-drop and progress. No React/Vue — not justified at this scale. Maybe HTMX if you want partial updates without writing JS.
- **Job state**: SQLite file in the persistent volume. Tracks: id, filename, status, started_at, finished_at, output_path, error. Lets you show history and survive container restarts.
- **Background execution**: FastAPI `BackgroundTasks` for short jobs; if jobs ever run >30s reliably, switch to a proper task queue (Arq, RQ, or just a `asyncio.Queue` worker). Start simple.
- **Notifications back to HA**: webhook to HA on completion. HA-side automation listens and sends mobile notification.

## File layout to add to the existing project

```
calibre-adept-docker/
├── Dockerfile                  # existing — gets minor additions
├── docker-compose.yml          # existing — for standalone testing
├── addon/                      # NEW — HA Add-on packaging
│   ├── config.yaml             # add-on manifest
│   ├── Dockerfile              # add-on-specific Dockerfile (extends existing image)
│   ├── run.sh                  # add-on entrypoint (s6 or simple bash)
│   ├── icon.png
│   └── logo.png
├── app/                        # NEW — the web service
│   ├── main.py                 # FastAPI app
│   ├── jobs.py                 # job runner + SQLite
│   ├── pipeline.py             # wraps existing acsm→decrypt CLI
│   ├── templates/
│   │   ├── index.html          # upload page
│   │   └── history.html
│   └── static/
│       ├── style.css
│       └── app.js              # drag-drop handler
└── (existing volumes/, resources/, etc.)
```

## Phased build

### Phase 1 — Web service standalone

Get the UI working against the existing container before touching HA.

- [ ] FastAPI app with three routes: `GET /` (upload form), `POST /upload` (accept multipart, kick off job), `GET /jobs/{id}` (status JSON).
- [ ] HTML page with drag-drop area + file input fallback. Vanilla JS posts to `/upload`, polls `/jobs/{id}` for status.
- [ ] `pipeline.py` wraps the existing CLI: takes ACSM path, returns decrypted ePub path or error.
- [ ] SQLite-backed job log.
- [ ] Run inside the existing container alongside the CLI. `docker compose up`, hit `http://localhost:8000`, upload a real ACSM, see it decrypt.

**Stopping point**: a working web UI on the host, callable via curl too.

### Phase 2 — Folder watcher (optional but worth it)

- [ ] Background task on startup: watch `/media/inbox` for new `.acsm` files (use `watchfiles` or `inotify_simple`).
- [ ] New file → create job → process → move ACSM to processed/ subfolder, output to `/media/books/`.
- [ ] Same job table as web uploads, so history shows both.

**Stopping point**: drop file in folder via SMB/HA File Editor, decrypted file appears in books folder.

### Phase 3 — Package as HA Add-on

This is the structural work. Reference: <https://developers.home-assistant.io/docs/add-ons/tutorial>.

- [ ] Write `addon/config.yaml`:
  ```yaml
  name: ADE Decrypt
  version: "0.1.0"
  slug: ade_decrypt
  description: Decrypt Adobe ADEPT-DRM ePubs via Wine + ADE + DeDRM
  arch:
    - amd64
  startup: application
  boot: auto
  ingress: true
  ingress_port: 8000
  panel_icon: mdi:book-lock-open
  panel_title: ADE Decrypt
  map:
    - media:rw
    - share:rw
  options:
    adobe_user: ""
    inbox_path: "/media/inbox"
    output_path: "/media/books"
  schema:
    adobe_user: str?
    inbox_path: str
    output_path: str
  ```
- [ ] Adapt the Dockerfile for add-on layout. May need to base on `ghcr.io/home-assistant/{arch}-base:latest` or keep `ubuntu:24.04` (HA Add-ons support arbitrary base images — `ubuntu:24.04` is fine).
- [ ] Write `run.sh`: reads add-on options from `/data/options.json`, exports as env vars, starts FastAPI via uvicorn.
- [ ] Add the add-on icon (1:1 PNG, ~256px) and logo (rectangular).
- [ ] Local install: copy the `addon/` folder into HA's `addons/` directory (via Samba or SSH), refresh Add-on Store in HA, install "ADE Decrypt" from the Local section.
- [ ] Test ingress: sidebar entry should appear after install, click → upload UI loads inside HA.

**Stopping point**: add-on installs, runs, UI accessible from HA sidebar, decrypts a book end-to-end.

### Phase 4 — Configuration via HA UI

- [ ] Move secrets/config to add-on options: Adobe ID, output paths, optional Calibre library path.
- [ ] **Don't put Adobe password in options.yaml** — use HA's secret storage. Options can reference `!secret adobe_password`.
- [ ] Validate options on startup, fail fast with a clear message in HA logs if misconfigured.

### Phase 5 — HA integration touches (nice-to-haves)

- [ ] Webhook to HA on job completion. Add a Long-Lived Access Token to options, POST to `/api/services/notify/mobile_app_xxx` when done.
- [ ] Expose a sensor: `sensor.ade_decrypt_pending` showing queue depth. HA dashboards can show it.
- [ ] Optional: integrate with Calibre Library — drop the decrypted ePub straight into the Calibre library folder so it's auto-imported. (Requires Calibre's CLI `calibredb add`.)

## Things to figure out before/during

- **Single-arch or multi-arch?** Add-on can declare multiple arches. If HA host is x86 (most common, including Intel NUC, generic PC), `amd64` is enough. For RPi (`aarch64`), Wine + 32-bit support is harder. Start `amd64`-only.
- **Image size.** Current image is big due to Wine + Calibre + ADE. HA Supervisor will handle it, but expect a slow first install. Worth a single-stage cleanup pass: combine apt installs, remove caches, delete winetricks downloads after they're applied.
- **Ingress vs direct port.** Ingress is cleaner (no port exposure, inherits HA auth, sidebar tab). Skip "host network" mode — not needed here.
- **Persistence.** Add-on data lives in `/data` (a managed volume). Put SQLite there. Wine prefix can also live in `/data/wineprefix` — survives add-on updates. Critical: don't put the prefix in `/tmp` or the container, you'll lose authorization on every restart.
- **Adobe password handling.** If using Strategy 2 from the headless-auth plan, password needs to reach the add-on. HA secrets work; alternatively, set it once via the UI, store hashed/encrypted in `/data`, never log it. Until Strategy 2 is solved, this whole question is moot — the prefix is already authorized via the snapshot.

## Open questions for tomorrow

- Should decrypted books go to `/media/books` (HA-visible, browsable via Media tab) or to a Calibre library? Or both?
- Folder watcher: drop folder on HA host (`/media/inbox`), or have the add-on poll an IMAP mailbox / Nextcloud folder / Dropbox? Email-attachment pickup would be slick — many libraries email .acsm files directly.
- Multi-user? Probably not — personal HA, single Adobe ID. Skip auth complexity inside the add-on; HA Ingress handles user auth.
- Does the existing CLI exit with useful status codes and structured errors, or does it print and exit 0 even on failure? May need to tighten that up before wrapping in a web layer.

## What this gets you

After Phase 3 you have an HA tile that does the whole job from a phone browser. After Phase 4 it's properly configured via HA UI like a real add-on. After Phase 5 you can fully automate: library emails .acsm → HA mail integration saves to inbox folder → add-on watches folder → decrypts → notifies you on your phone with a link to the book in HA Media.

## Reference

- HA Add-on tutorial: <https://developers.home-assistant.io/docs/add-ons/tutorial>
- HA Add-on config reference: <https://developers.home-assistant.io/docs/add-ons/configuration>
- HA Ingress docs: <https://developers.home-assistant.io/docs/add-ons/presentation#ingress>
- FastAPI: <https://fastapi.tiangolo.com>
- HTMX (if you want progressive enhancement without a JS framework): <https://htmx.org>
