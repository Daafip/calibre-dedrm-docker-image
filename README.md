# Calibre DeDRM — Home Assistant Addon

Automatically converts `.acsm` files to DRM-free ePubs using **libgourou** (native Linux ADEPT implementation) and Calibre DeDRM. No Wine, no Adobe Digital Editions, no 20-minute first-run setup.

> [!CAUTION]
> Removal of DRM is not in line with the license agreement when loaning ebooks.
> For personal use this is condoned, but still NOT legal.
> Sharing of loaned books with DRM  removed is NOT legal.
> This repo merely combines existing open source code into a flow where the books remain fully local and in personal use.
> Without the cumbersome process of using Adobe Digital Editions to transfer to an eReader.
> The books are downloaded on the homeassitant server and remain within the home network of the user, unlike [other alternatives](https://send.djazz.se/).


> [!WARNING]
> Although extensively tested and used personally, this project was fully generated with AI.

## How it works

```
.acsm file
    │
    ▼
adept_activate      ← one-time device registration with Adobe ID
    │
    ▼
acsmdownloader      ← downloads the DRM-protected ePub from Adobe's servers
    │
    ▼
adept_remove        ← strips ADEPT DRM using the device's private key
    │
    ▼
calibredb           ← imports and exports the clean ePub
    │
    ▼
DRM-free ePub → /share/calibre-dedrm/books/
                → (optional) send2ereader for Kobo delivery
```

Activation data is stored in `/data/adept/` and persists across restarts. The device only needs to be activated once.

## Repository layout

```
ha-addon-base/          Base Docker image — builds libgourou, downloads DeDRM plugins
ha-addon/               Main addon — run.sh, upload UI, ACSM watch loop
ha-addon-send2ereader/  Optional Kobo delivery server
test/                   Integration tests for the send2ereader flow
docker-compose.test.yml Local test stack (no HA required)
```

## Home Assistant installation

1. In HA → **Settings → Add-ons → Add-on Store** → ⋮ → **Repositories** — add this repo's URL.
2. Install **Calibre DeDRM** from the store.
3. Configure the addon (see below) and start it.

First start activates the device with Adobe's servers (~5 seconds). Subsequent starts are instant.

> **Architecture:** `amd64` only (libgourou build). Will not run on Raspberry Pi or other ARM hosts.

## Configuration

| Option | Description |
|---|---|
| `adobe_email` | Adobe ID email — required for first-time activation |
| `adobe_password` | Adobe ID password — required for first-time activation |
| `send2ereader_url` | URL of the send2ereader addon, e.g. `http://homeassistant.local:3001` — leave empty to disable |
| `notify_service` | HA notification service name, e.g. `mobile_app_phone` — leave empty to disable |

After successful activation, credentials are no longer needed for processing books. They are only used if the activation data in `/data/adept/` is deleted.

## Usage

### Drop a file

Copy an `.acsm` file to `/share/calibre-dedrm/input/` on the HA host (e.g. via Samba or SSH). The addon polls every 30 seconds and processes any `.acsm` files it finds. The decrypted ePub lands in `/share/calibre-dedrm/books/`.

Failed files are renamed to `.failed`.

### Upload via browser

The addon exposes a file upload page via HA ingress. Open the addon in the HA sidebar, drag and drop your `.acsm` file, and click Upload. The file is queued immediately.

### Kobo delivery via send2ereader

Install the **send2ereader** addon from this same repository. Set `send2ereader_url` to `http://<HA-IP>:3001` in the Calibre DeDRM addon config.

After each successful decryption the addon:
1. Uploads the ePub to send2ereader and logs a 4-character code, e.g. `G5VN`
2. On your Kobo, open the browser and navigate to `http://<HA-IP>:3001`
3. Enter the code in the "Or enter a code from the addon logs" field
4. Tap **Get book** — the download link appears; tap it to download to the Kobo

The code is valid for 10 minutes.

## Local testing (no HA required)

```bash
# 1. Edit test-data/options.json with your Adobe ID
#    (created automatically; gitignored)

# 2. Copy DeDRM plugins into test-data/resources/
cp resources/DeDRM_Plugin.zip resources/Obok_plugin.zip test-data/resources/

# 3. Build the base image (compiles libgourou — a few minutes)
docker compose -f docker-compose.test.yml build base

# 4. Build the addon image
docker compose -f docker-compose.test.yml build addon

# 5. Run
docker compose -f docker-compose.test.yml up addon
```

Drop `.acsm` files into `test-data/input/`. Output appears in `test-data/books/`.

The upload UI is at [http://localhost:8099](http://localhost:8099).

### Running send2ereader locally

```bash
docker compose -f docker-compose.test.yml build send2ereader
docker compose -f docker-compose.test.yml up send2ereader
```

### Running the integration tests

```bash
# Requires send2ereader running at localhost:3001
python3 test/test_send2ereader.py
```

## Links

- [libgourou](https://forge.soutade.fr/soutade/libgourou) — native Linux ADEPT implementation
- [noDRM DeDRM_tools](https://github.com/noDRM/DeDRM_tools) — Calibre DeDRM plugin
- [send2ereader](https://github.com/daniel-j/send2ereader) — Kobo/Kindle ebook delivery
