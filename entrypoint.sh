#!/bin/bash
set -euo pipefail

WINEPREFIX="${WINEPREFIX:-/home/calibre/wineprefix}"
BOOKS_DIR="${BOOKS_DIR:-/home/calibre/books}"
CALIBRE_CONFIG="${CALIBRE_CONFIG_DIRECTORY:-/home/calibre/calibre-config}"

PYTHON_EXE="$WINEPREFIX/drive_c/users/calibre/AppData/Local/Programs/Python/Python312-32/python.exe"
ADE_EXE="$WINEPREFIX/drive_c/Program Files/Adobe/Adobe Digital Editions 4.5/DigitalEditions.exe"
DEDRM_MARKER="$CALIBRE_CONFIG/plugins/dedrm.json"

# Use Xvfb when no real display is available (headless bootstrap)
if [ -z "${DISPLAY:-}" ]; then
    Xvfb :99 -screen 0 1024x768x24 -nolisten tcp &
    XVFB_PID=$!
    export DISPLAY=:99
    trap 'kill $XVFB_PID 2>/dev/null || true' EXIT
fi

# ── Phase 2: Wine prefix bootstrap ─────────────────────────────────────────
WINETRICKS_DONE="$WINEPREFIX/.winetricks_done"
if [ ! -f "$WINETRICKS_DONE" ]; then
    echo ">>> Initializing Wine prefix (win32) — takes a few minutes..."
    wineboot --init

    echo ">>> Installing Windows components via winetricks..."
    # dotnet40 required by ADE 4.5; corefonts + tahoma prevent ADE crash in
    # FontFamily.get_FirstFontFamily(); win7 required — ADE won't run on XP.
    # windowscodecs omitted: Wine 9 ships its own WIC implementation.
    winetricks -q dotnet40 corefonts tahoma
    winetricks -q win10
    touch "$WINETRICKS_DONE"
fi

# ── Phase 3: Python 3.12 (32-bit) + pycryptodome ───────────────────────────
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
    # Ensure python.exe is resolvable by name (PrependPath sometimes silently fails under Wine)
    PY_DIR="C:\\users\\calibre\\AppData\\Local\\Programs\\Python\\Python312-32"
    wine reg add "HKCU\\Environment" /v Path /t REG_SZ \
        /d "${PY_DIR};${PY_DIR}\\Scripts" /f
    echo ">>> Installing pycryptodome..."
    wine "$PYTHON_EXE" -m pip install --quiet pycryptodome
fi

# Phases 4+5 require a real display and user interaction — skip in bootstrap mode
CMD="${1:-gui}"
if [ "$CMD" = "bootstrap" ]; then
    echo ">>> Phase 2 + 3 complete. Wine prefix and Python are ready."
    echo "    Next: run with your display to install ADE (Phase 4):"
    echo "      xhost +local:docker && docker compose run --rm calibre"
    exit 0
fi

# ── Phase 4: Adobe Digital Editions install ─────────────────────────────────
if [ ! -f "$ADE_EXE" ]; then
    ADE_INSTALLER=$(ls /resources/ADE_*.exe 2>/dev/null | head -1)
    if [ -z "$ADE_INSTALLER" ]; then
        echo "ERROR: No ADE installer found in /resources/."
        echo "       Place ADE_4.5_Installer.exe (or ADE_4.0.3_Installer.exe) in ./resources/ and rebuild."
        echo "       Adobe's download page: https://www.adobe.com/solutions/ebook/digital-editions/download.html"
        exit 1
    fi
    echo ">>> Installing Adobe Digital Editions..."
    echo "    A GUI window will open — accept defaults and click through."
    wine "$ADE_INSTALLER"

    echo ""
    echo "┌────────────────────────────────────────────────────────────────────┐"
    echo "│  ACTION REQUIRED: authorize ADE with your Adobe ID, then open at  │"
    echo "│  least one DRM-protected ebook. Close ADE when done.              │"
    echo "│  Press Enter to continue...                                        │"
    echo "└────────────────────────────────────────────────────────────────────┘"
    read -r

    echo ""
    echo "NOTE: Each Adobe ID allows ~6 device authorizations. Use"
    echo "      Help → Erase Authorization in ADE before wiping the volume."
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

# ── Phase 6: dispatch ───────────────────────────────────────────────────────
case "$CMD" in
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
