#!/bin/bash
set -euo pipefail

# Prefix every line of output with a timestamp
exec > >(while IFS= read -r _line; do printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$_line"; done) 2>&1

[ -f /build-info.txt ] && echo ">>> Addon version: $(cat /build-info.txt)"

# ── Home Assistant addon options ─────────────────────────────────────────────
OPTIONS=/data/options.json
ADOBE_EMAIL=$(jq --raw-output '.adobe_email // empty' "$OPTIONS" 2>/dev/null || true)
ADOBE_PASSWORD=$(jq --raw-output '.adobe_password // empty' "$OPTIONS" 2>/dev/null || true)
SEND2EREADER_URL=$(jq --raw-output '.send2ereader_url // empty' "$OPTIONS" 2>/dev/null || true)
NOTIFY_SERVICES=$(jq --raw-output '.notify_services // [] | .[]' "$OPTIONS" 2>/dev/null || true)
EMAIL_TO=$(jq --raw-output '.email_to // [] | .[]' "$OPTIONS" 2>/dev/null || true)
EMAIL_TO_JSON=$(jq --compact-output '.email_to // []' "$OPTIONS" 2>/dev/null || echo '[]')
SMTP_HOST=$(jq --raw-output '.smtp_host // empty' "$OPTIONS" 2>/dev/null || true)
SMTP_PORT=$(jq --raw-output '.smtp_port // 587' "$OPTIONS" 2>/dev/null || true)
SMTP_USER=$(jq --raw-output '.smtp_user // empty' "$OPTIONS" 2>/dev/null || true)
SMTP_PASS=$(jq --raw-output '.smtp_password // empty' "$OPTIONS" 2>/dev/null || true)

INPUT_DIR="/share/calibre-dedrm/input"
OUTPUT_DIR="/share/calibre-dedrm/books"
RESOURCES_DIR="/share/calibre-dedrm/resources"

export CALIBRE_CONFIG_DIRECTORY=/data/calibre-config
export HOME=/root

DEDRM_MARKER="$CALIBRE_CONFIG_DIRECTORY/plugins/dedrm.json"
ADEPT_DIR=/data/adept

# ── Directories ──────────────────────────────────────────────────────────────
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR" "$RESOURCES_DIR"
mkdir -p "$ADEPT_DIR"

# Persist libgourou activation data across container restarts
mkdir -p /root/.config
if [ ! -L /root/.config/adept ] || [ "$(readlink /root/.config/adept)" != "$ADEPT_DIR" ]; then
    rm -rf /root/.config/adept
    ln -sf "$ADEPT_DIR" /root/.config/adept
fi

# ── libgourou: device activation ─────────────────────────────────────────────
ADEPT_ACTIVATION="$ADEPT_DIR/activation.xml"

# A complete activation contains <adept:user>; a partial file (from a failed
# first run) only has service-info/certificate elements.
adept_is_complete() {
    grep -q 'adept:user' "$ADEPT_ACTIVATION" 2>/dev/null
}

if ! adept_is_complete; then
    if [ -n "${ADOBE_EMAIL:-}" ] && [ -n "${ADOBE_PASSWORD:-}" ]; then
        echo ">>> Activating device with Adobe ID: $ADOBE_EMAIL"
        if echo "y" | adept_activate -u "$ADOBE_EMAIL" -p "$ADOBE_PASSWORD"; then
            echo ">>> Activation succeeded."
        else
            echo ">>> WARNING: Activation failed — check credentials."
            echo "    ACSM processing will fail until the device is activated."
        fi
    else
        echo ">>> WARNING: Device not activated and no credentials configured."
        echo "    Set adobe_email + adobe_password in the addon configuration."
        echo "    ACSM files will fail until the device is activated."
    fi
else
    echo ">>> Device already activated (activation.xml OK)."
fi

# ── Calibre + DeDRM plugin ────────────────────────────────────────────────────
mkdir -p "$CALIBRE_CONFIG_DIRECTORY/calibre"

find_plugin() {
    local name="$1"
    local found
    found=$(ls "/resources/$name" "$RESOURCES_DIR/$name" 2>/dev/null \
        | while IFS= read -r f; do [ -s "$f" ] && echo "$f"; done \
        | head -1 || true)
    if [ -z "$found" ]; then
        echo ">>> $name not found locally — downloading from noDRM GitHub..." >&2
        mkdir -p /resources
        if wget -q -O "/resources/$name" \
                "https://github.com/noDRM/DeDRM_tools/releases/download/v10.0.3/$name" \
           && [ -s "/resources/$name" ]; then
            found="/resources/$name"
        else
            rm -f "/resources/$name"
            echo "ERROR: Could not download $name." >&2
            exit 1
        fi
    fi
    echo "$found"
}

if [ ! -f "$DEDRM_MARKER" ]; then
    DEDRM_ZIP=$(find_plugin DeDRM_Plugin.zip)
    OBOK_ZIP=$(find_plugin Obok_plugin.zip)
    echo ">>> Installing DeDRM plugin..."
    calibre-customize --add-plugin="$DEDRM_ZIP"
    echo ">>> Installing Obok plugin..."
    calibre-customize --add-plugin="$OBOK_ZIP"
    mkdir -p "$CALIBRE_CONFIG_DIRECTORY/plugins"
    cat > "$DEDRM_MARKER" <<JSON
{
  "adeptkeys": {},
  "configured": true,
  "kindlekeys": {},
  "pids": [],
  "serials": []
}
JSON
fi

# ── send2ereader helpers ──────────────────────────────────────────────────────

push_to_send2ereader() {
    local epub="$1" base_url="${2%/}"
    local COOKIEJAR CODE UPLOAD_RESP SUCCESS EPUBNAME
    COOKIEJAR=$(mktemp)

    CODE=$(curl -sf -c "$COOKIEJAR" -X POST "$base_url/generate" 2>/dev/null || true)
    if [ -z "$CODE" ]; then
        rm -f "$COOKIEJAR"; echo ""; return
    fi

    local STATUS
    STATUS=$(curl -sf -b "$COOKIEJAR" -o /dev/null -w "%{http_code}" \
        -F "key=$CODE" -F "file=@$epub;type=application/epub+zip" \
        "$base_url/upload" 2>/dev/null || echo "000")
    rm -f "$COOKIEJAR"
    [ "$STATUS" != "200" ] && echo "" && return

    # Download route is GET /:filename?key=CODE — URL-encode the epub basename
    EPUBNAME=$(python3 -c "
import sys, urllib.parse, os
print(urllib.parse.quote(os.path.basename(sys.argv[1]), safe=''))
" "$epub")
    echo "$base_url/$EPUBNAME?key=$CODE"
}

notify_ha() {
    local title="$1" message="$2" service="${3:-}"
    [ -z "$service" ] && return 0
    [ -z "${SUPERVISOR_TOKEN:-}" ] && return 0
    curl -sf \
        -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"title\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$title"), \"message\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$message")}" \
        "http://supervisor/core/api/services/notify/$service" >/dev/null || true
}

send_book_email() {
    local epub="$1"
    local recipients="${2:-$EMAIL_TO}"
    [ -z "$SMTP_HOST" ] && return 0
    [ -z "${recipients:-}" ] && return 0
    while IFS= read -r _to; do
        [ -z "$_to" ] && continue
        echo ">>> Emailing $(basename "$epub") to $_to..."
        if SMTP_HOST="$SMTP_HOST" SMTP_PORT="$SMTP_PORT" \
           SMTP_USER="$SMTP_USER" SMTP_PASS="$SMTP_PASS" \
           python3 /send_email.py "$_to" "$epub"; then
            echo ">>> Email sent to $_to."
        else
            echo ">>> WARNING: Email to $_to failed."
        fi
    done <<< "$recipients"
}

# ── Upload server (HA ingress) ────────────────────────────────────────────────
INPUT_DIR="$INPUT_DIR" INGRESS_PORT="${INGRESS_PORT:-8099}" \
    SMTP_HOST="${SMTP_HOST:-}" \
    EMAIL_TO_JSON="${EMAIL_TO_JSON:-[]}" \
    python3 /upload_server.py &

# ── Service loop ──────────────────────────────────────────────────────────────
echo ">>> Setup complete. Watching $INPUT_DIR for .acsm files (every 30 s)..."
echo "    Output: $OUTPUT_DIR"
[ -n "${SEND2EREADER_URL:-}" ] && echo "    send2ereader: $SEND2EREADER_URL"

process_acsm() {
    local ACSM_FILE="$1"
    local BASENAME RECIPIENTS_FILE USE_SIDECAR SIDECAR_RECIPS
    BASENAME=$(basename "$ACSM_FILE")
    RECIPIENTS_FILE="${ACSM_FILE}.email_recipients"
    USE_SIDECAR=false
    SIDECAR_RECIPS=""
    if [ -f "$RECIPIENTS_FILE" ]; then
        SIDECAR_RECIPS=$(cat "$RECIPIENTS_FILE")
        USE_SIDECAR=true
    fi
    echo ">>> Processing: $BASENAME"

    # Step 1: Download the DRM-protected ePub/PDF from Adobe's fulfillment servers
    local DOWNLOAD_DIR
    DOWNLOAD_DIR=$(mktemp -d)

    if ! (cd "$DOWNLOAD_DIR" && acsmdownloader -f "$(realpath "$ACSM_FILE")"); then
        echo ">>> ERROR: Download failed for $BASENAME."
        echo "    Is the device activated? Can it reach Adobe's fulfillment servers?"
        mv "$ACSM_FILE" "${ACSM_FILE%.acsm}.failed" 2>/dev/null || true
        rm -f "$RECIPIENTS_FILE"
        rm -rf "$DOWNLOAD_DIR"
        return
    fi

    local ENCRYPTED_FILE
    ENCRYPTED_FILE=$(find "$DOWNLOAD_DIR" \( -name "*.epub" -o -name "*.pdf" \) | head -1 || true)
    if [ -z "${ENCRYPTED_FILE:-}" ]; then
        echo ">>> ERROR: acsmdownloader produced no output file for $BASENAME."
        mv "$ACSM_FILE" "${ACSM_FILE%.acsm}.failed" 2>/dev/null || true
        rm -f "$RECIPIENTS_FILE"
        rm -rf "$DOWNLOAD_DIR"
        return
    fi

    # Step 2: Remove ADEPT DRM
    local EXT="${ENCRYPTED_FILE##*.}"
    local DRM_FREE_FILE="${ENCRYPTED_FILE%.*}_drm_free.$EXT"
    if ! adept_remove -f "$ENCRYPTED_FILE" -o "$DRM_FREE_FILE"; then
        echo ">>> ERROR: DRM removal failed for $(basename "$ENCRYPTED_FILE")."
        mv "$ACSM_FILE" "${ACSM_FILE%.acsm}.failed" 2>/dev/null || true
        rm -f "$RECIPIENTS_FILE"
        rm -rf "$DOWNLOAD_DIR"
        return
    fi

    # Step 3: Import into Calibre and export to output directory
    local TMPLIB EXPORT_MARKER EXPORTED_EPUB
    TMPLIB=$(mktemp -d)
    EXPORT_MARKER=$(mktemp)

    calibredb add "$DRM_FREE_FILE" --with-library "$TMPLIB"
    calibredb export --all --to-dir "$OUTPUT_DIR" --single-dir --with-library "$TMPLIB"

    EXPORTED_EPUB=$(find "$OUTPUT_DIR" -name "*.epub" -newer "$EXPORT_MARKER" 2>/dev/null | head -1 || true)

    rm -f "$EXPORT_MARKER" "$NO_EMAIL_MARKER"
    rm -rf "$TMPLIB" "$DOWNLOAD_DIR"
    rm -f "$ACSM_FILE"
    echo ">>> Done: $BASENAME → $OUTPUT_DIR"

    if [ -n "${SEND2EREADER_URL:-}" ] && [ -n "${EXPORTED_EPUB:-}" ]; then
        echo ">>> Uploading to send2ereader..."
        local DOWNLOAD_URL
        DOWNLOAD_URL=$(push_to_send2ereader "$EXPORTED_EPUB" "$SEND2EREADER_URL")
        if [ -n "$DOWNLOAD_URL" ]; then
            echo "┌──────────────────────────────────────────┐"
            echo "│  Book ready on Kobo                      │"
            echo "│  URL  : $DOWNLOAD_URL"
            echo "└──────────────────────────────────────────┘"
            while IFS= read -r _svc; do
                [ -n "$_svc" ] && notify_ha "Book ready" "$DOWNLOAD_URL" "$_svc"
            done <<< "$NOTIFY_SERVICES"
        else
            echo ">>> WARNING: send2ereader upload failed (is it running at $SEND2EREADER_URL?)"
        fi
    fi

    if [ -n "${EXPORTED_EPUB:-}" ]; then
        if [ "$USE_SIDECAR" = true ]; then
            [ -n "${SIDECAR_RECIPS:-}" ] && send_book_email "$EXPORTED_EPUB" "$SIDECAR_RECIPS"
        else
            send_book_email "$EXPORTED_EPUB"
        fi
    fi
}

while true; do
    for ACSM_FILE in "$INPUT_DIR"/*.acsm; do
        [ -f "$ACSM_FILE" ] || continue
        process_acsm "$ACSM_FILE"
    done
    sleep 30
done
