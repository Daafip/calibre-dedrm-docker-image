#!/bin/bash
set -euo pipefail

# ── Home Assistant addon options ─────────────────────────────────────────────
OPTIONS=/data/options.json
ADOBE_EMAIL=$(jq --raw-output '.adobe_email // empty' "$OPTIONS" 2>/dev/null || true)
ADOBE_PASSWORD=$(jq --raw-output '.adobe_password // empty' "$OPTIONS" 2>/dev/null || true)
WINEPREFIX_SNAPSHOT=$(jq --raw-output '.wineprefix_snapshot // empty' "$OPTIONS" 2>/dev/null || true)

INPUT_DIR="/share/calibre-dedrm/input"
OUTPUT_DIR="/share/calibre-dedrm/books"
RESOURCES_DIR="/share/calibre-dedrm/resources"

# ── Environment ──────────────────────────────────────────────────────────────
export WINEARCH=win32
export WINEPREFIX=/data/wineprefix
export CALIBRE_CONFIG_DIRECTORY=/data/calibre-config
export HOME=/root

# Running as root under Wine: user-specific paths use "root" not "calibre"
PYTHON_EXE="$WINEPREFIX/drive_c/users/root/AppData/Local/Programs/Python/Python312-32/python.exe"
PY_DIR="C:\\users\\root\\AppData\\Local\\Programs\\Python\\Python312-32"
ADE_EXE="$WINEPREFIX/drive_c/Program Files/Adobe/Adobe Digital Editions 4.0/DigitalEditions.exe"
[ ! -f "$ADE_EXE" ] && ADE_EXE="$WINEPREFIX/drive_c/Program Files/Adobe/Adobe Digital Editions 4.5/DigitalEditions.exe"
ADE_BOOKS_DIR="$WINEPREFIX/drive_c/users/root/Documents/My Digital Editions"
DEDRM_MARKER="$CALIBRE_CONFIG_DIRECTORY/plugins/dedrm.json"
WINETRICKS_DONE="$WINEPREFIX/.winetricks_done"

# ── Directories ──────────────────────────────────────────────────────────────
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR" "$RESOURCES_DIR"
mkdir -p "$ADE_BOOKS_DIR" "$ADE_BOOKS_DIR/Manifest" "$ADE_BOOKS_DIR/Tags"
mkdir -p /root/.cache/mesa_shader_cache 2>/dev/null || true

# ── Xvfb (always headless in HA) ─────────────────────────────────────────────
Xvfb :99 -screen 0 1024x768x24 -nolisten tcp &
XVFB_PID=$!
export DISPLAY=:99
trap 'kill $XVFB_PID 2>/dev/null || true' EXIT

# Disable WPF hardware compositing (prevents rmsdk_wrapper crash under Wine 9.x)
wine reg add "HKCU\\SOFTWARE\\Microsoft\\Avalon.Graphics" \
    /v DisableHWAcceleration /t REG_DWORD /d 1 /f 2>/dev/null || true

# ── Strategy 1: Restore wineprefix from snapshot ─────────────────────────────
if [ -n "${WINEPREFIX_SNAPSHOT:-}" ] && [ ! -f "$WINETRICKS_DONE" ]; then
    echo ">>> Restoring wineprefix from snapshot: $(basename "$WINEPREFIX_SNAPSHOT")"
    case "$WINEPREFIX_SNAPSHOT" in
        http://*|https://*)
            wget -q --show-progress -O /tmp/snapshot.tar.gz "$WINEPREFIX_SNAPSHOT"
            tar -xzf /tmp/snapshot.tar.gz -C "$(dirname "$WINEPREFIX")"
            rm -f /tmp/snapshot.tar.gz
            ;;
        *)
            tar -xzf "$WINEPREFIX_SNAPSHOT" -C "$(dirname "$WINEPREFIX")"
            ;;
    esac
    echo ">>> Snapshot restored."
fi

# ── Phase 2: Wine prefix bootstrap ───────────────────────────────────────────
if [ ! -f "$WINETRICKS_DONE" ]; then
    echo ">>> Initializing Wine prefix (win32) — this takes several minutes on first run..."
    wineboot --init
    echo ">>> Installing Windows components via winetricks..."
    winetricks -q dotnet48 corefonts tahoma
    winetricks -q win10
    touch "$WINETRICKS_DONE"
fi

# ── Phase 3: Python 3.12 (32-bit) + pycryptodome ─────────────────────────────
if [ ! -f "$PYTHON_EXE" ]; then
    # Look in /resources (bundled at build time), then /share/calibre-dedrm/resources
    PY_INSTALLER=$(ls /resources/python-3.12*.exe "$RESOURCES_DIR"/python-3.12*.exe 2>/dev/null \
        | grep -v amd64 | head -1 || true)
    if [ -z "$PY_INSTALLER" ]; then
        echo "ERROR: Python 3.12 (32-bit) installer not found."
        echo "       Place python-3.12.x.exe (not -amd64) in $RESOURCES_DIR."
        exit 1
    fi
    echo ">>> Installing Python 3.12 (32-bit)..."
    wine "$PY_INSTALLER" /quiet PrependPath=1 Include_doc=0
    echo ">>> Installing pycryptodome..."
    wine "$PYTHON_EXE" -m pip install --quiet pycryptodome
fi

# Ensure python.exe is on the Wine PATH (run every startup)
wine reg add "HKCU\\Environment" /v Path /t REG_SZ \
    /d "${PY_DIR};${PY_DIR}\\Scripts" /f 2>/dev/null || true
wine reg add "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment" \
    /v Path /t REG_EXPAND_SZ \
    /d "%SystemRoot%\\system32;%SystemRoot%;${PY_DIR};${PY_DIR}\\Scripts" /f 2>/dev/null || true

# ── Helpers ───────────────────────────────────────────────────────────────────

ade_is_authorized() {
    grep -q 'Adept\\\\Activation' "$WINEPREFIX/user.reg" 2>/dev/null
}

ade_headless_auth() {
    local EMAIL="$1" PASSWORD="$2"
    echo ">>> Starting ADE for headless authorization under Xvfb..."
    WINEDEBUG=-all wine "$ADE_EXE" &
    local ADE_AUTH_PID=$! ADE_WID="" i=0
    while [ $i -lt 30 ]; do
        sleep 1
        ADE_WID=$(xdotool search --name "Adobe Digital Editions" 2>/dev/null | tail -1)
        [ -n "$ADE_WID" ] && break
        i=$((i+1))
    done
    if [ -z "$ADE_WID" ]; then
        echo ">>> WARNING: ADE window did not appear — headless auth skipped"
        kill "$ADE_AUTH_PID" 2>/dev/null || true
        return 1
    fi
    echo ">>> ADE window ready, navigating to Authorize Computer..."
    sleep 2
    xdotool windowfocus --sync "$ADE_WID" || true
    xdotool windowraise "$ADE_WID" || true
    sleep 0.5
    xdotool key "alt+h" || true
    sleep 0.8
    xdotool key "a" || true
    sleep 2
    xdotool key "Tab" || true
    sleep 0.3
    xdotool type --clearmodifiers --delay 30 "$EMAIL" || true
    xdotool key "Tab" || true
    sleep 0.3
    xdotool type --clearmodifiers --delay 30 "$PASSWORD" || true
    xdotool key "Tab" || true
    sleep 0.3
    xdotool key "Return" || true
    echo ">>> Credentials submitted, waiting up to 60 s for Adobe servers..."
    local j=0
    while [ $j -lt 12 ]; do
        sleep 5
        ade_is_authorized && break || true
        j=$((j+1))
    done
    kill "$ADE_AUTH_PID" 2>/dev/null || true
    pkill -f "DigitalEditions" 2>/dev/null || true
    sleep 2
    if ade_is_authorized; then
        echo ">>> ADE authorization succeeded."
    else
        echo ">>> WARNING: Headless auth did not complete — check credentials."
        echo "    Alternative: place a wineprefix snapshot tarball in $RESOURCES_DIR"
        echo "    and set wineprefix_snapshot in the addon configuration."
    fi
}

# ── Phase 4: ADE install + authorization ─────────────────────────────────────
# Re-resolve after any snapshot restore
ADE_EXE="$WINEPREFIX/drive_c/Program Files/Adobe/Adobe Digital Editions 4.0/DigitalEditions.exe"
[ ! -f "$ADE_EXE" ] && ADE_EXE="$WINEPREFIX/drive_c/Program Files/Adobe/Adobe Digital Editions 4.5/DigitalEditions.exe"

if [ ! -f "$ADE_EXE" ]; then
    ADE_INSTALLER=$(ls /resources/ADE_4*.exe "$RESOURCES_DIR"/ADE_4*.exe 2>/dev/null | head -1 || true)
    if [ -z "$ADE_INSTALLER" ]; then
        echo "ERROR: No ADE installer found."
        echo "       It should have been downloaded at image build time."
        echo "       As a fallback, place ADE_4.0.3_Installer.exe in: $RESOURCES_DIR"
        exit 1
    fi
    echo ">>> Installing Adobe Digital Editions (silent)..."
    WINEDEBUG=-all wine "$ADE_INSTALLER" /S 2>/dev/null
    sleep 10
    ADE_EXE="$WINEPREFIX/drive_c/Program Files/Adobe/Adobe Digital Editions 4.0/DigitalEditions.exe"
    [ ! -f "$ADE_EXE" ] && ADE_EXE="$WINEPREFIX/drive_c/Program Files/Adobe/Adobe Digital Editions 4.5/DigitalEditions.exe"
fi

if ! ade_is_authorized; then
    if [ -n "${ADOBE_EMAIL:-}" ] && [ -n "${ADOBE_PASSWORD:-}" ]; then
        ade_headless_auth "$ADOBE_EMAIL" "$ADOBE_PASSWORD" || true
    else
        echo ">>> WARNING: ADE is not authorized. Set adobe_email + adobe_password in the addon"
        echo "    configuration, or place a wineprefix snapshot at:"
        echo "    $RESOURCES_DIR/wineprefix-authorized.tar.gz"
        echo "    and set wineprefix_snapshot in the addon configuration."
        echo "    ACSM files will fail to download until ADE is authorized."
    fi
else
    echo ">>> ADE is already authorized."
fi

# ── Phase 5: Calibre + DeDRM plugin ──────────────────────────────────────────
mkdir -p "$CALIBRE_CONFIG_DIRECTORY/calibre"

find_plugin() {
    local name="$1"
    # Prefer build-time bundle in /resources/, fall back to user-supplied share dir,
    # then download from noDRM GitHub releases.
    local found
    found=$(ls "/resources/$name" "$RESOURCES_DIR/$name" 2>/dev/null | head -1 || true)
    if [ -z "$found" ]; then
        echo ">>> $name not found locally — downloading from noDRM GitHub..."
        mkdir -p /resources
        wget -q -O "/resources/$name" \
            "https://github.com/noDRM/DeDRM_tools/releases/download/v10.0.3/$name" \
            && found="/resources/$name" \
            || { echo "ERROR: Could not download $name."; exit 1; }
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
  "adobe_pdf_passphrases": [],
  "androidkeys": {},
  "adobewineprefix": "${WINEPREFIX}",
  "bandnkeys": {},
  "configured": true,
  "ereaderkeys": {},
  "kindlekeys": {},
  "kindlewineprefix": "",
  "lcp_passphrases": [],
  "pids": [],
  "serials": []
}
JSON
fi

# Patch DeDRM wineutils.py: replace C:\Python27 name lookup with the full path,
# forcing Wine to use CreateProcess (which works) instead of ShellExecute (which fails
# for console apps when called by name).
calibre-debug -e /dev/stdin <<'PYEOF'
import zipfile, os, sys
config = os.environ.get('CALIBRE_CONFIG_DIRECTORY', '/data/calibre-config')
zip_path = config + '/plugins/DeDRM.zip'
marker = '# patched-by-docker-image'
try:
    with zipfile.ZipFile(zip_path, 'r') as zf:
        content = zf.read('wineutils.py').decode('utf-8')
except Exception as e:
    print(f'DeDRM.zip not found: {e}'); sys.exit(0)
if marker in content:
    sys.exit(0)
old = '            ["wine", "C:\\\\Python27\\\\python.exe"], # Should likely be removed'
new = ('            ["wine", "C:\\\\users\\\\root\\\\AppData\\\\Local\\\\Programs'
       '\\\\Python\\\\Python312-32\\\\python.exe"], ' + marker + '\n' + old)
if old not in content:
    print('WARNING: DeDRM wineutils.py patch target not found — plugin updated?'); sys.exit(0)
patched = content.replace(old, new)
tmp = zip_path + '.tmp'
try:
    with zipfile.ZipFile(zip_path, 'r') as zin, \
         zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            data = zin.read(item.filename)
            if item.filename == 'wineutils.py':
                data = patched.encode('utf-8')
            zout.writestr(item, data)
    os.replace(tmp, zip_path)
    print('>>> Patched DeDRM: full Python path added to WinePythonCLI candidates.')
except Exception as e:
    if os.path.exists(tmp): os.remove(tmp)
    print(f'>>> WARNING: DeDRM patch failed: {e}')
PYEOF

# Pre-extract ADEPT key so DeDRM can decrypt without needing the Wine Python lookup
ADOBEKEY_SCRIPT="$CALIBRE_CONFIG_DIRECTORY/plugins/DeDRM/libraryfiles/adobekey.py"
ADEPT_KEY_COUNT=$(python3 -c "
import json, sys
try:
    d = json.load(open('$DEDRM_MARKER'))
    print(len(d.get('adeptkeys', {})))
except Exception: print(0)
" 2>/dev/null || echo 0)

if [ "$ADEPT_KEY_COUNT" = "0" ] && [ -f "$PYTHON_EXE" ] && [ -f "$ADOBEKEY_SCRIPT" ]; then
    echo ">>> Extracting ADEPT key from Wine prefix..."
    KEYDIR=$(mktemp -d)
    KEYDIR_WIN=$(winepath -w "$KEYDIR" 2>/dev/null || echo "Z:${KEYDIR}")
    WINEDEBUG=-all wine "$PYTHON_EXE" "$ADOBEKEY_SCRIPT" "$KEYDIR_WIN" || true
    KEY_FILE=$(ls "$KEYDIR"/*.der 2>/dev/null | head -1 || true)
    if [ -n "${KEY_FILE:-}" ]; then
        export KEY_FILE DEDRM_MARKER KEY_NAME
        KEY_NAME=$(basename "$KEY_FILE" .der)
        python3 -c "
import json, os
key_file = os.environ['KEY_FILE']
key_name = os.environ['KEY_NAME']
marker   = os.environ['DEDRM_MARKER']
with open(key_file, 'rb') as f: key_hex = f.read().hex()
with open(marker) as f: d = json.load(f)
d.setdefault('adeptkeys', {})[key_name] = key_hex
with open(marker, 'w') as f: json.dump(d, f, indent=2)
print('>>> ADEPT key cached — DeDRM will use it directly.')
"
    else
        echo ">>> No ADEPT key found — ADE may not be authorized yet."
    fi
    rm -rf "$KEYDIR"
fi

# ── Service loop ──────────────────────────────────────────────────────────────
echo ">>> Setup complete. Watching $INPUT_DIR for .acsm files (every 30 s)..."
echo "    Output: $OUTPUT_DIR"

process_acsm() {
    local ACSM_FILE="$1"
    local BASENAME
    BASENAME=$(basename "$ACSM_FILE")
    echo ">>> Processing: $BASENAME"

    local ACSM_WIN MARKER NEW_FILE ADE_PID
    ACSM_WIN=$(winepath -w "$(realpath "$ACSM_FILE")")
    MARKER=$(mktemp)

    WINEDEBUG=-all wine "$ADE_EXE" "$ACSM_WIN" >/dev/null 2>&1 &
    ADE_PID=$!

    NEW_FILE=""
    for i in $(seq 1 60); do
        sleep 5
        local CANDIDATE
        CANDIDATE=$(find "$ADE_BOOKS_DIR" \( -name "*.epub" -o -name "*.pdf" \) -newer "$MARKER" \
            2>/dev/null | head -1 || true)
        if [ -n "${CANDIDATE:-}" ]; then
            local SIZE1 SIZE2
            SIZE1=$(stat -c%s "$CANDIDATE" 2>/dev/null || echo 0)
            sleep 3
            SIZE2=$(stat -c%s "$CANDIDATE" 2>/dev/null || echo 0)
            if [ "$SIZE1" = "$SIZE2" ] && [ "$SIZE1" -gt 1000 ]; then
                NEW_FILE="$CANDIDATE"
                echo ">>> Download complete: $(basename "$NEW_FILE")"
                break
            fi
        fi
        kill -0 "$ADE_PID" 2>/dev/null || break
    done

    rm -f "$MARKER"
    kill "$ADE_PID" 2>/dev/null || true
    pkill -f "DigitalEditions" 2>/dev/null || true

    # Fallback: most-recently-modified file (covers cases where ADE exited early)
    if [ -z "${NEW_FILE:-}" ]; then
        NEW_FILE=$(find "$ADE_BOOKS_DIR" \( -name "*.epub" -o -name "*.pdf" \) 2>/dev/null \
            | xargs ls -t 2>/dev/null | head -1 || true)
        [ -n "${NEW_FILE:-}" ] && echo ">>> Using most recent file: $(basename "$NEW_FILE")"
    fi

    if [ -n "${NEW_FILE:-}" ]; then
        local TMPLIB
        TMPLIB=$(mktemp -d)
        calibredb add "$NEW_FILE" --with-library "$TMPLIB"
        calibredb export --all --to-dir "$OUTPUT_DIR" --single-dir --with-library "$TMPLIB"
        rm -rf "$TMPLIB"
        rm -f "$ACSM_FILE"
        echo ">>> Done: $BASENAME → $OUTPUT_DIR"
    else
        echo ">>> ERROR: Download failed for $BASENAME. Is ADE authorized? Can it reach Adobe's servers?"
        mv "$ACSM_FILE" "${ACSM_FILE%.acsm}.failed" 2>/dev/null || true
    fi
}

while true; do
    for ACSM_FILE in "$INPUT_DIR"/*.acsm; do
        [ -f "$ACSM_FILE" ] || continue
        process_acsm "$ACSM_FILE"
    done
    sleep 30
done
