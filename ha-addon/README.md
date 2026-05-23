# Calibre DeDRM — Home Assistant Add-on

Watches `/share/calibre-dedrm/input/` for `.acsm` files, decrypts them to DRM-free ePubs using **libgourou** (native Linux ADEPT — no Wine) + Calibre DeDRM, and writes the output to `/share/calibre-dedrm/books/`.

Optionally pushes each decrypted book to a [send2ereader](../ha-addon-send2ereader/README.md) instance and sends an HA notification with the download code.

> **Architecture note:** `amd64` only (libgourou build). Will not run on Raspberry Pi (aarch64/armv7).

---

## First-run setup

First start activates the device with Adobe's servers (~5 seconds). Subsequent starts are instant — activation data is persisted in `/data/adept/`.

Set `adobe_email` and `adobe_password` in the **Configuration** tab before starting. After successful activation the credentials are no longer needed for day-to-day processing; they are only used again if `/data/adept/` is deleted.

---

## Configuration options

| Option | Description |
| --- | --- |
| `adobe_email` | Adobe ID email — required for first-time device activation |
| `adobe_password` | Adobe ID password (masked in UI) |
| `send2ereader_url` | URL of the send2ereader add-on, e.g. `http://homeassistant.local:3001` — leave empty to disable |
| `notify_services` | List of HA notification service names to ping when a book is ready, e.g. `mobile_app_phone` (omit the `notify.` prefix) — leave empty to disable |
| `email_to` | List of email addresses to send the decrypted ePub to as an attachment — leave empty to disable |
| `smtp_host` | SMTP server hostname, e.g. `smtp.gmail.com` — required to enable email delivery |
| `smtp_port` | SMTP port (default `587`, STARTTLS) |
| `smtp_user` | SMTP login username (usually your email address) |
| `smtp_password` | SMTP password or app password (masked in UI) |

---

## Usage

**Browser upload:** Open the add-on's web UI via the sidebar. Drag and drop (or select) an `.acsm` file and click **Upload** — it is queued immediately.

**Manual drop:** Place `.acsm` files in `/share/calibre-dedrm/input/` via SSH, Samba, or the HA File Editor add-on.

The add-on polls every 30 seconds, processes each file, and writes the decrypted ePub to `/share/calibre-dedrm/books/`. Files that fail are renamed to `.failed`.

If `send2ereader_url` is configured, the ePub is also pushed there automatically. A 4-character code is logged and optionally sent as an HA notification — enter it on your Kobo browser to download the book.

---

## Volume layout

| Path in container | Purpose |
| --- | --- |
| `/data/adept/` | libgourou activation data — persisted across restarts |
| `/data/calibre-config/` | Calibre plugin state and DeDRM marker |
| `/share/calibre-dedrm/input/` | Drop `.acsm` files here |
| `/share/calibre-dedrm/books/` | Decrypted ePub output |
| `/share/calibre-dedrm/resources/` | Optional: place `DeDRM_Plugin.zip` / `Obok_plugin.zip` here if the build-time download fails |

---

## Troubleshooting

**`.failed` files in input folder**
Check the add-on log. Common causes: device not activated (wrong credentials), ACSM file has expired (Adobe ACSM files are valid ~60 days), or no internet access to Adobe's fulfillment servers.

**`Invalid activation file` in the log**
A previous activation attempt failed and left a partial `activation.xml`. Delete `/data/adept/` via SSH or the File Editor and restart the add-on with correct credentials.

**Notifications not arriving**
Ensure `homeassistant_api: true` is in the add-on config (it is, from v1.6.0 onward). Check that the service name in `notify_services` matches what HA shows under **Developer Tools → Services** (e.g. `mobile_app_davids_phone`, without the `notify.` prefix).
