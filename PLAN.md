# send2ereader Output Integration — Project Plan

End goal: after the ADE Decrypt add-on decrypts an ePub, automatically push it to a self-hosted send2ereader instance and display the short code in the HA UI (and optionally send it as a notification). User opens the Kobo's built-in browser, navigates to the send2ereader URL, types the code, book downloads straight to the device.

Builds on top of the HA Add-on plan. Adds one more output destination to the pipeline.

## Why send2ereader

- Kobo doesn't support send-to-email like Kindle.
- USB sync requires plugging in and Calibre. Tedious.
- send2ereader is genuinely the cleanest wireless path: upload to a small self-hosted service, type a 4–6 character code on the Kobo, file downloads via HTTP through the device's built-in browser.
- Kobo-aware: converts ePub → kepub on the fly via kepubify, which gives better reading experience (correct page counts, dictionary, etc.) than vanilla ePub on Kobo firmware.
- MIT-licensed, actively maintained, ships with Dockerfile + docker-compose. Easy to host.

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│  Home Assistant                                            │
│  ├─ Sidebar: "ADE Decrypt"                                 │
│  ├─ Sidebar: "send2ereader" (optional, add-on)             │
│  └─ Notification → mobile: "Code: ABC123"                  │
└────────────────────────────────────────────────────────────┘
        │                              ▲
        │ (ingress UI)                 │ (webhook on success)
        ▼                              │
┌──────────────────────┐         ┌────────────────────────┐
│  ADE Decrypt add-on  │  HTTP   │  send2ereader add-on   │
│  (existing)          │ ──POST─▶│  (Node.js, port 3001)  │
│  ├─ FastAPI UI       │         │  ├─ Web upload UI      │
│  ├─ Pipeline:        │         │  ├─ kepubify converter │
│  │  acsm → epub      │         │  ├─ Returns short code │
│  │  → decrypt        │         │  └─ Serves on /<code>  │
│  └─ Pushes result    │         └────────────────────────┘
│     to send2ereader  │                  │
└──────────────────────┘                  │
                                          ▼
                          ┌───────────────────────────┐
                          │  Kobo built-in browser    │
                          │  → http://ha.local:3001   │
                          │  → enter code ABC123      │
                          │  → book downloads         │
                          └───────────────────────────┘
```

Two HA add-ons living side by side:
- **ade-decrypt**: existing. Builds on the previous plan.
- **send2ereader**: new. Mostly just packaging the upstream Dockerfile as an HA add-on.

Inter-add-on communication: both run under HA Supervisor's Docker network. ade-decrypt can reach send2ereader at `http://addon_local_send2ereader:3001` (or whatever the hostname resolves to — Supervisor exposes add-ons to each other by slug).

## Integration mechanism — known unknown

send2ereader doesn't document a JSON API. It has a web form that POSTs a multipart upload to `/` and returns HTML containing the generated code. The endpoint is stable but not officially an API.

**Before writing the integration code, read `index.js` from the send2ereader repo** and confirm:
- The exact upload endpoint and method.
- What multipart field name the file goes in (`file`? `book`? `epub`?).
- What the response looks like (HTML body, redirect to `/<code>`, JSON?).
- Whether there's any kepubify trigger flag in the upload (might convert automatically server-side).
- Whether file expiration time is configurable per-upload.

This is 10 minutes of reading and prevents an afternoon of curl-fumbling.

## Phased build

### Phase 1 — Stand up send2ereader independently

Get send2ereader running and verify the Kobo flow works end-to-end with manual uploads. Don't touch the existing add-on yet.

- [ ] Clone send2ereader, build with `docker compose build`, run with `docker compose up`.
- [ ] Hit `http://<host>:3001` from a browser, upload a test ePub manually, get a code.
- [ ] On the Kobo: Beta Features → Web Browser → navigate to `http://<host>:3001` (use the HA host's LAN IP) → enter code → confirm the book downloads and opens. **This is the critical end-to-end test.** If this doesn't work, nothing else matters — could be network reachability, Kobo browser quirks, or kepub conversion issues.

**Stopping point**: a working send2ereader instance that your Kobo can reach.

### Phase 2 — Package send2ereader as an HA Add-on

- [ ] Create `addon-send2ereader/` directory with:
  - `config.yaml`: ingress on port 3001, panel icon, slug `send2ereader`, no options needed initially.
  - `Dockerfile`: extends `daniel-j/send2ereader`'s Dockerfile or copies the npm install + start command. Use `node:20-alpine` base.
  - `run.sh`: just `node /app/index.js` (or whatever the start command is).
- [ ] Important: send2ereader stores uploaded files in memory or on disk briefly. Decide whether to mount `/data` for persistence (probably not — uploads are ephemeral by design, files expire).
- [ ] Local install: copy `addon-send2ereader/` to HA's `addons/` directory, refresh, install.
- [ ] Sidebar entry should appear. Test upload flow via ingress.

**Note**: there may already be a third-party HA add-on repository for send2ereader. Check the HA community add-ons repo and HACS before building your own — saves work if it exists.

**Stopping point**: send2ereader runs as an HA add-on, accessible via HA sidebar.

### Phase 3 — Wire ADE Decrypt to push to send2ereader

- [ ] Add a `send2ereader_url` option to ade-decrypt's `config.yaml` (default: `http://addon_local_send2ereader:3001`, or empty to disable).
- [ ] In `pipeline.py` or a new `sinks.py` module, add a function `push_to_send2ereader(epub_path, base_url) -> code: str`:
  ```python
  with open(epub_path, "rb") as f:
      r = httpx.post(f"{base_url}/", files={"<FIELDNAME>": f})
  # parse code from response — confirmed during the recon step above
  return code
  ```
- [ ] On successful decrypt, call `push_to_send2ereader` if URL is configured. Store the returned code in the job record.
- [ ] Update the UI to show the code prominently after job completion. Big and copyable — user will hand-type it on the Kobo.

**Stopping point**: drop ACSM in UI, decrypted ePub gets pushed to send2ereader automatically, code appears in UI.

### Phase 4 — HA notification with code

- [ ] In the ade-decrypt add-on, add an HA webhook call on successful push.
- [ ] Add-on options: `ha_webhook_id` (HA-side webhook ID) and/or `ha_token` (long-lived access token) and `notify_service` (e.g. `notify.mobile_app_phone`).
- [ ] On success, POST to HA's REST API:
  ```
  POST /api/services/notify/mobile_app_phone
  { "title": "Book ready", "message": "Code: ABC123 — http://ha.local:3001" }
  ```
- [ ] Test: ACSM in, phone buzzes with code, type on Kobo, book lands.

### Phase 5 — Polish

- [ ] Toggle in ADE Decrypt UI per-upload: "push to send2ereader" checkbox (default on if configured).
- [ ] History page shows past codes (even after they expire from send2ereader). Useful for debugging.
- [ ] Optional: shortcut on the Kobo browser — set a bookmark to `http://ha.local:3001` to skip the URL typing.
- [ ] Optional: have ADE Decrypt also output to `/media/books` regardless, so the file is preserved even if send2ereader auto-deletes it after download.

## Design decisions to think through

- **Local-only vs Internet-exposed.** send2ereader is designed to be public-facing (the canonical instance is `send.djazz.se`). For a home setup, keeping it on your LAN means the Kobo has to be on home Wi-Fi to download. That's fine for personal use — and avoids exposing your books to the internet. Don't put it on a public domain unless you really want to.
- **Kepub conversion.** send2ereader will offer the user a choice (epub vs kepub) on the download page. If you want to force kepub for the Kobo, you may need to pre-convert with kepubify before pushing, or look at whether send2ereader supports a "prefer kepub" upload flag.
- **Code longevity.** send2ereader codes typically expire after a few hours or after first download. If you want a "persistent library on Kobo" workflow, this is the wrong tool — it's for transient delivery. Pair with a regular `/media/books` output for permanent storage.
- **Naming.** send2ereader uses the original filename by default. Make sure decrypted ePubs have decent names (title + author from epub metadata) before pushing. Calibre can help here, or a small `ebook-meta` call.
- **Kobo browser quirks.** The Kobo's built-in browser is barely a browser — it's an old WebKit fork that struggles with modern JS, HTTPS in some cases, and certain redirects. send2ereader is specifically designed around these limits, but if you ever fork or modify it, test on the actual device. Don't trust desktop browser testing.

## Open questions for tomorrow

- Does the upstream send2ereader Dockerfile work as-is under HA Supervisor, or does it need adaptation? (Probably just config.yaml + a thin wrapper.)
- Does the existing ADE Decrypt sidebar UI have room for a "Kobo code" panel, or does it need a redesign? Mockup the UI before building.
- One add-on for both pipeline + Kobo delivery, or two add-ons? Two is cleaner separation but more install steps for whoever uses this later (you, in six months, when something breaks).
- What's the URL the Kobo browser actually has to type? `http://homeassistant.local:3001/` won't work if ingress is enabled (HA ingress only works through HA's 8123 port with auth). Two options:
  1. Expose send2ereader on a host port (config.yaml: `ports: 3001/tcp: 3001`). Simpler for Kobo.
  2. Keep it ingress-only and have the Kobo access via `http://homeassistant.local:8123/api/hassio_ingress/<token>/` — fragile, token-based URL is ugly to type.
  **Option 1 wins for this use case.** Ingress is for human-friendly UIs reached from HA; the Kobo needs a stable, simple URL.

## End-state user flow

1. Library emails you an ACSM file.
2. HA mail integration saves the attachment to `/media/inbox` (existing automation).
3. ADE Decrypt add-on's folder watcher picks it up.
4. Pipeline runs: fulfill ASCM → strip DRM → save to `/media/books`.
5. Add-on pushes ePub to send2ereader, gets code back.
6. HA pushes notification to phone: "Book ready. Code: ABC123."
7. Open Kobo browser bookmark → type ABC123 → book downloads.
8. Read.

Total human input after setup: tap the notification, type 6 characters on the Kobo. That's the win.

## Reference

- send2ereader: <https://github.com/daniel-j/send2ereader>
- kepubify (Kobo-optimized ePub converter, used inside send2ereader): <https://github.com/pgaskin/kepubify>
- HA Ingress docs: <https://developers.home-assistant.io/docs/add-ons/presentation#ingress>
- HA notification service docs: <https://www.home-assistant.io/integrations/notify/>
