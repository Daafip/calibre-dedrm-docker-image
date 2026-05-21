#!/bin/bash
set -euo pipefail

WINEPREFIX="${WINEPREFIX:-/home/calibre/wineprefix}"
BOOKS_DIR="${BOOKS_DIR:-/home/calibre/books}"
CALIBRE_CONFIG="${CALIBRE_CONFIG_DIRECTORY:-/home/calibre/calibre-config}"

PYTHON_EXE="$WINEPREFIX/drive_c/users/calibre/AppData/Local/Programs/Python/Python312-32/python.exe"
# Prefer 4.0.3 — 4.5's rmsdk_wrapper crashes on Wine 9.x before it can do anything
ADE_EXE="$WINEPREFIX/drive_c/Program Files/Adobe/Adobe Digital Editions 4.0/DigitalEditions.exe"
if [ ! -f "$ADE_EXE" ]; then
    ADE_EXE="$WINEPREFIX/drive_c/Program Files/Adobe/Adobe Digital Editions 4.5/DigitalEditions.exe"
fi
ADE_BOOKS_DIR="$WINEPREFIX/drive_c/users/calibre/Documents/My Digital Editions"
DEDRM_MARKER="$CALIBRE_CONFIG/plugins/dedrm.json"

# Expose ADE's book library as a stable short path for Calibre to browse
mkdir -p "$ADE_BOOKS_DIR" "$ADE_BOOKS_DIR/Manifest" "$ADE_BOOKS_DIR/Tags"
ln -sfn "$ADE_BOOKS_DIR" /home/calibre/ade-books

mkdir -p /home/calibre/.cache/mesa_shader_cache 2>/dev/null || true

# Use Xvfb when no real display is available (headless bootstrap)
if [ -z "${DISPLAY:-}" ]; then
    Xvfb :99 -screen 0 1024x768x24 -nolisten tcp &
    XVFB_PID=$!
    export DISPLAY=:99
    trap 'kill $XVFB_PID 2>/dev/null || true' EXIT
fi

# Disable WPF hardware compositing — prevents rmsdk_wrapper null-deref crash
# under Wine 9.x where CLSID_MILCore ({35440327-...}) is never registered.
# This is idempotent and safe to run on every container start.
wine reg add "HKCU\\SOFTWARE\\Microsoft\\Avalon.Graphics" \
    /v DisableHWAcceleration /t REG_DWORD /d 1 /f 2>/dev/null || true

# ── Strategy 1: Restore wineprefix from snapshot ────────────────────────────
# Set WINEPREFIX_SNAPSHOT to a local container path or https:// URL.
# Only runs when the prefix is not yet initialised (no .winetricks_done marker).
WINETRICKS_DONE="$WINEPREFIX/.winetricks_done"
WINEPREFIX_SNAPSHOT="${WINEPREFIX_SNAPSHOT:-}"
if [ -n "$WINEPREFIX_SNAPSHOT" ] && [ ! -f "$WINETRICKS_DONE" ]; then
    echo ">>> Restoring wineprefix from snapshot: $(basename "$WINEPREFIX_SNAPSHOT")"
    case "$WINEPREFIX_SNAPSHOT" in
        http://*|https://*)
            wget -q --show-progress -O /tmp/wineprefix-snapshot.tar.gz "$WINEPREFIX_SNAPSHOT"
            tar -xzf /tmp/wineprefix-snapshot.tar.gz -C "$(dirname "$WINEPREFIX")"
            rm -f /tmp/wineprefix-snapshot.tar.gz
            ;;
        *)
            tar -xzf "$WINEPREFIX_SNAPSHOT" -C "$(dirname "$WINEPREFIX")"
            ;;
    esac
    echo ">>> Snapshot restored."
fi

# ── Phase 2: Wine prefix bootstrap ─────────────────────────────────────────
if [ ! -f "$WINETRICKS_DONE" ]; then
    echo ">>> Initializing Wine prefix (win32) — takes a few minutes..."
    wineboot --init

    echo ">>> Installing Windows components via winetricks..."
    # dotnet40 required by ADE 4.5; corefonts + tahoma prevent ADE crash in
    # FontFamily.get_FirstFontFamily(); win7 required — ADE won't run on XP.
    # windowscodecs omitted: Wine 9 ships its own WIC implementation.
    winetricks -q dotnet48 corefonts tahoma
    winetricks -q win10
    touch "$WINETRICKS_DONE"
fi

# ── Phase 3: Python 3.12 (32-bit) + pycryptodome ───────────────────────────
PY_DIR="C:\\users\\calibre\\AppData\\Local\\Programs\\Python\\Python312-32"

if [ ! -f "$PYTHON_EXE" ]; then
    PY_INSTALLER=$(ls /resources/python-3.12*.exe 2>/dev/null | grep -v amd64 | head -1)
    if [ -z "$PY_INSTALLER" ]; then
        echo "ERROR: No 32-bit Python 3.12 installer found in /resources/."
        echo "       Download python-3.12.x.exe (NOT -amd64) from python.org,"
        echo "       place it in ./resources/, and rebuild the image."
        exit 1
    fi
    echo ">>> Installing Python 3.12 (32-bit)..."
    wine "$PY_INSTALLER" /quiet PrependPath=1 Include_doc=0
    echo ">>> Installing pycryptodome..."
    wine "$PYTHON_EXE" -m pip install --quiet pycryptodome
fi

# Ensure python.exe is findable by name for Wine subprocesses spawned by Calibre.
# HKCU\Environment alone is not picked up by Wine when subprocess spawns wine directly —
# HKLM system PATH is used instead. Run on every startup so it survives wineprefix reuse.
wine reg add "HKCU\\Environment" /v Path /t REG_SZ \
    /d "${PY_DIR};${PY_DIR}\\Scripts" /f 2>/dev/null || true
wine reg add "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment" \
    /v Path /t REG_EXPAND_SZ \
    /d "%SystemRoot%\\system32;%SystemRoot%;${PY_DIR};${PY_DIR}\\Scripts" /f 2>/dev/null || true

# Phases 4+5 require a real display and user interaction — skip in bootstrap mode
CMD="${1:-gui}"
if [ "$CMD" = "bootstrap" ]; then
    echo ">>> Phase 2 + 3 complete. Wine prefix and Python are ready."
    echo "    Next: run with your display to install ADE (Phase 4):"
    echo "      xhost +local:docker && docker compose run --rm calibre"
    exit 0
fi

# ── Helpers ──────────────────────────────────────────────────────────────────

# Returns 0 if ADE has ADEPT activation data in the Wine registry.
ade_is_authorized() {
    grep -q 'Adept\\\\Activation' "$WINEPREFIX/user.reg" 2>/dev/null
}

# Automate ADE's Help → Authorize Computer dialog via xdotool under Xvfb.
# Strategy 2: headless auth when ADOBE_EMAIL + ADOBE_PASSWORD are set.
ade_headless_auth() {
    local EMAIL="$1" PASSWORD="$2"

    echo ">>> Starting ADE for headless authorization..."
    WINEDEBUG=-all wine "$ADE_EXE" &
    local ADE_AUTH_PID=$!

    # Wait up to 30 s for the ADE main window
    local ADE_WID="" i=0
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
    xdotool windowfocus --sync "$ADE_WID"
    xdotool windowraise "$ADE_WID"
    sleep 0.5

    # Help menu → Authorize Computer...
    # Alt+H opens Help; 'a' jumps to the first item starting with A = "Authorize Computer..."
    xdotool key "alt+h" || true
    sleep 0.8
    xdotool key "a" || true
    sleep 2

    # Dialog layout: ID Type dropdown (Adobe ID, default) → Email → Password → Authorize
    xdotool key "Tab" || true                                  # skip ID type dropdown
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
        echo "    Tip: run 'docker compose run --rm calibre ade' to authorize interactively."
        echo "    Or create a snapshot of an already-authorized prefix (see README)."
    fi
}

# ── Phase 4: Adobe Digital Editions install ─────────────────────────────────
if [ ! -f "$ADE_EXE" ]; then
    ADE_INSTALLER=$(ls /resources/ADE_4*.exe 2>/dev/null | head -1)
    if [ -z "$ADE_INSTALLER" ]; then
        echo "ERROR: No ADE installer found in /resources/."
        echo "       Place ADE_4.5_Installer.exe (or ADE_4.0.3_Installer.exe) in ./resources/ and rebuild."
        echo "       Adobe's download page: https://www.adobe.com/solutions/ebook/digital-editions/download.html"
        exit 1
    fi
    echo ">>> Installing Adobe Digital Editions (silent)..."
    WINEDEBUG=-all wine "$ADE_INSTALLER" /S 2>/dev/null
    sleep 10
    # Re-resolve the exe path now that the installer has run
    ADE_EXE="$WINEPREFIX/drive_c/Program Files/Adobe/Adobe Digital Editions 4.0/DigitalEditions.exe"
    if [ ! -f "$ADE_EXE" ]; then
        ADE_EXE="$WINEPREFIX/drive_c/Program Files/Adobe/Adobe Digital Editions 4.5/DigitalEditions.exe"
    fi
fi

# Authorize if needed
if ! ade_is_authorized; then
    if [ -n "${ADOBE_EMAIL:-}" ] && [ -n "${ADOBE_PASSWORD:-}" ]; then
        ade_headless_auth "$ADOBE_EMAIL" "$ADOBE_PASSWORD" || true
    elif [ "$CMD" != "bootstrap" ]; then
        echo ""
        echo "┌────────────────────────────────────────────────────────────────────┐"
        echo "│  ADE is not yet authorized. Options:                              │"
        echo "│                                                                    │"
        echo "│  A — headless (preferred for HA / servers):                       │"
        echo "│      Set ADOBE_EMAIL + ADOBE_PASSWORD, re-run the container.      │"
        echo "│                                                                    │"
        echo "│  B — interactive (requires a display):                            │"
        echo "│      xhost +local:docker                                          │"
        echo "│      docker compose run --rm calibre ade                         │"
        echo "│      Help → Authorize Computer → sign in with Adobe ID            │"
        echo "│                                                                    │"
        echo "│  C — snapshot (for re-deploy from an already-authorized setup):   │"
        echo "│      Set WINEPREFIX_SNAPSHOT to a tarball path or URL.            │"
        echo "└────────────────────────────────────────────────────────────────────┘"
        echo ""
        echo "NOTE: Each Adobe ID allows ~6 device authorizations."
        echo "      Use Help → Erase Authorization in ADE before wiping the volume."
    fi
else
    echo ">>> ADE is already authorized."
fi

# ── Phase 5: Calibre + DeDRM plugin ────────────────────────────────────────
mkdir -p "$CALIBRE_CONFIG/calibre"

if [ ! -f "$DEDRM_MARKER" ]; then
    echo ">>> Installing DeDRM plugin into Calibre..."
    calibre-customize --add-plugin=/resources/DeDRM_Plugin.zip

    echo ">>> Installing Obok plugin into Calibre..."
    calibre-customize --add-plugin=/resources/Obok_plugin.zip

    echo ">>> Writing DeDRM plugin config (Adobe Wine Prefix: $WINEPREFIX)..."
    mkdir -p "$CALIBRE_CONFIG/plugins"
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

# Patch DeDRM wineutils.py to use the full Python path. WinePythonCLI searches
# by name via ShellExecute, which Wine can't use for console apps — full path
# forces CreateProcess which works. Idempotent: checks for a marker in the zip.
calibre-debug -e /dev/stdin <<'PYEOF'
import zipfile, os, sys

config = os.environ.get('CALIBRE_CONFIG_DIRECTORY', '/home/calibre/calibre-config')
zip_path = config + '/plugins/DeDRM.zip'
marker = '# patched-by-docker-image'

try:
    with zipfile.ZipFile(zip_path, 'r') as zf:
        content = zf.read('wineutils.py').decode('utf-8')
except Exception as e:
    print(f'DeDRM.zip not found or unreadable: {e}')
    sys.exit(0)

if marker in content:
    sys.exit(0)  # already patched

# File text has literal \\ chars; Python \\\\ = \\ as string = \\ in file.
old = '            ["wine", "C:\\\\Python27\\\\python.exe"], # Should likely be removed'
new = ('            ["wine", "C:\\\\users\\\\calibre\\\\AppData\\\\Local\\\\Programs'
       '\\\\Python\\\\Python312-32\\\\python.exe"], ' + marker + '\n' + old)

if old not in content:
    print('WARNING: DeDRM wineutils.py patch target not found — plugin updated?')
    sys.exit(0)

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
    if os.path.exists(tmp):
        os.remove(tmp)
    print(f'>>> WARNING: DeDRM patch failed: {e}')
PYEOF

# ── Phase 5b: Pre-extract ADEPT key ─────────────────────────────────────────
# WinePythonCLI (used by DeDRM at decrypt time) searches for python.exe by name
# and is unreliable when Wine's PATH doesn't match expectations. Pre-extracting
# the key here — using the known full path to python.exe — bypasses that entirely.
# DeDRM checks adeptkeys first and skips WinePythonCLI if keys are present.
ADOBEKEY_SCRIPT="$CALIBRE_CONFIG/plugins/DeDRM/libraryfiles/adobekey.py"
ADEPT_KEY_COUNT=$(python3 -c "
import json, sys
try:
    d = json.load(open('$DEDRM_MARKER'))
    print(len(d.get('adeptkeys', {})))
except Exception:
    print(0)
" 2>/dev/null || echo 0)

if [ "$ADEPT_KEY_COUNT" = "0" ] && [ -f "$PYTHON_EXE" ] && [ -f "$ADOBEKEY_SCRIPT" ]; then
    echo ">>> Extracting ADEPT key from Wine prefix..."
    KEYDIR=$(mktemp -d)
    KEYDIR_WIN=$(winepath -w "$KEYDIR" 2>/dev/null || echo "Z:${KEYDIR}")
    WINEDEBUG=-all wine "$PYTHON_EXE" "$ADOBEKEY_SCRIPT" "$KEYDIR_WIN" || true
    KEY_FILE=$(ls "$KEYDIR"/*.der 2>/dev/null | head -1)
    if [ -n "$KEY_FILE" ]; then
        export KEY_FILE DEDRM_MARKER
        export KEY_NAME
        KEY_NAME=$(basename "$KEY_FILE" .der)
        python3 -c "
import json, os
key_file = os.environ['KEY_FILE']
key_name = os.environ['KEY_NAME']
marker   = os.environ['DEDRM_MARKER']
with open(key_file, 'rb') as f:
    key_hex = f.read().hex()
with open(marker) as f:
    d = json.load(f)
d.setdefault('adeptkeys', {})[key_name] = key_hex
with open(marker, 'w') as f:
    json.dump(d, f, indent=2)
print('>>> ADEPT key cached — DeDRM will use it directly without Wine Python lookup.')
"
    else
        echo ">>> No ADEPT key found — ADE may not be authorized yet. Authorize via 'ade' command first."
    fi
    rm -rf "$KEYDIR"
fi

# ── Phase 6: dispatch ───────────────────────────────────────────────────────
case "$CMD" in
    dedrm)
        # Full pipeline: ASCM → ADE download → DeDRM → decrypted epub
        # Usage: dedrm <input.acsm> [output_dir]
        ACSM="${2:?Usage: dedrm <input.acsm> [output_dir]}"
        OUTPUT_DIR="${3:-$BOOKS_DIR}"

        [ -f "$ACSM" ] || { echo "ERROR: File not found: $ACSM"; exit 1; }

        # Resolve symlinks so winepath maps to the C: drive, not Z:
        ACSM_WIN=$(winepath -w "$(realpath "$ACSM")")

        # Marker file — we find epubs/pdfs newer than this timestamp
        MARKER=$(mktemp)

        echo ">>> Opening ADE with: $(basename "$ACSM")"
        WINEDEBUG=-all wine "$ADE_EXE" "$ACSM_WIN" >/dev/null 2>&1 &
        ADE_PID=$!

        echo ">>> Waiting for download to complete..."
        NEW_FILE=""
        for i in $(seq 1 60); do
            sleep 5
            CANDIDATE=$(find "$ADE_BOOKS_DIR" \( -name "*.epub" -o -name "*.pdf" \) -newer "$MARKER" 2>/dev/null | head -1)
            if [ -n "$CANDIDATE" ]; then
                SIZE1=$(stat -c%s "$CANDIDATE" 2>/dev/null || echo 0)
                sleep 3
                SIZE2=$(stat -c%s "$CANDIDATE" 2>/dev/null || echo 0)
                if [ "$SIZE1" = "$SIZE2" ] && [ "$SIZE1" -gt 1000 ]; then
                    NEW_FILE="$CANDIDATE"
                    echo ">>> Download complete: $(basename "$NEW_FILE")"
                    break
                fi
            fi
            # ADE crashed or exited — stop waiting
            if ! kill -0 "$ADE_PID" 2>/dev/null; then
                break
            fi
        done

        rm -f "$MARKER"
        kill "$ADE_PID" 2>/dev/null || true
        pkill -f "DigitalEditions" 2>/dev/null || true

        # Fallback: epub was downloaded but is older than the marker
        # (e.g. ADE crashed after download, or file existed from a prior run)
        if [ -z "$NEW_FILE" ]; then
            NEW_FILE=$(find "$ADE_BOOKS_DIR" \( -name "*.epub" -o -name "*.pdf" \) 2>/dev/null \
                | xargs ls -t 2>/dev/null | head -1)
            [ -n "$NEW_FILE" ] && echo ">>> Using most recent file: $(basename "$NEW_FILE")"
        fi

        if [ -z "$NEW_FILE" ]; then
            echo "ERROR: No ebook found in $ADE_BOOKS_DIR. Check that ADE can reach Adobe's servers."
            exit 1
        fi

        TMPLIB=$(mktemp -d)
        trap 'rm -rf "$TMPLIB"' EXIT
        echo ">>> Decrypting: $(basename "$NEW_FILE")"
        calibredb add "$NEW_FILE" --with-library "$TMPLIB"
        calibredb export --all --to-dir "$OUTPUT_DIR" --single-dir --with-library "$TMPLIB"
        echo ">>> Done. Decrypted output in: $OUTPUT_DIR"
        ;;
    decrypt)
        # Usage: decrypt <input.epub> [output_dir]
        INPUT="${2:?Usage: decrypt <input.epub> [output_dir]}"
        OUTPUT_DIR="${3:-$BOOKS_DIR}"
        TMPLIB=$(mktemp -d)
        trap 'rm -rf "$TMPLIB"' EXIT
        echo ">>> Adding to temporary library: $INPUT"
        calibredb add "$INPUT" --with-library "$TMPLIB"
        echo ">>> Exporting decrypted file(s) to: $OUTPUT_DIR"
        calibredb export --all --to-dir "$OUTPUT_DIR" --single-dir --with-library "$TMPLIB"
        echo ">>> Done."
        ;;
    ade)
        exec wine "$ADE_EXE"
        ;;
    gui)
        exec calibre
        ;;
    shell)
        exec /bin/bash
        ;;
    *)
        exec "$@"
        ;;
esac
