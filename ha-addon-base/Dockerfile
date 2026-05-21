FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        cabextract \
        calibre \
        jq \
        libgl1-mesa-dri \
        libgl1:i386 \
        unzip \
        wine \
        wine32:i386 \
        winetricks \
        wget \
        winbind \
        xdotool \
        xvfb \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /resources

# DeDRM 10.0.3 + Obok
RUN wget -q -O /tmp/dedrm.zip \
       "https://github.com/noDRM/DeDRM_tools/releases/download/v10.0.3/DeDRM_tools_10.0.3.zip" \
    && unzip -q /tmp/dedrm.zip "DeDRM_Plugin.zip" "Obok_plugin.zip" -d /resources/ \
    && rm /tmp/dedrm.zip \
    || echo "WARNING: DeDRM download failed."

# 32-bit Python 3.12.7
RUN wget -q -O /resources/python-3.12.7.exe \
       "https://www.python.org/ftp/python/3.12.7/python-3.12.7.exe" \
    || echo "WARNING: Python download failed."

# ADE 4.0.3 (preferred over 4.5 — 4.5 crashes on Wine 9.x)
RUN wget -q -O /resources/ADE_4.0.3_Installer.exe \
       "https://adedownload.adobe.com/pub/adobe/digitaleditions/ADE_4.0.3_Installer.exe" \
    || echo "WARNING: ADE download failed."

# Wine Gecko (avoids CDN hit on first wineboot)
RUN mkdir -p /usr/share/wine/gecko \
    && wget -q -O /usr/share/wine/gecko/wine_gecko-2.47.4-x86.msi \
       "https://dl.winehq.org/wine/wine-gecko/2.47.4/wine_gecko-2.47.4-x86.msi" \
    || echo "WARNING: Gecko pre-fetch failed."

ENV WINEARCH=win32

# Build the Wine prefix with .NET 4.8, Python 3.12, and ADE already installed.
# This is the slow step (~20 min). The result lives at /wineprefix-base and is
# copied to /data/wineprefix on the addon's first start (seconds, not minutes).
RUN /bin/bash -c '\
    export WINEPREFIX=/wineprefix-base WINEARCH=win32 HOME=/root; \
    Xvfb :99 -screen 0 1024x768x24 -nolisten tcp & XVFB_PID=$!; \
    export DISPLAY=:99; \
    sleep 2; \
    WINEDEBUG=-all wine reg add "HKCU\\SOFTWARE\\Microsoft\\Avalon.Graphics" \
        /v DisableHWAcceleration /t REG_DWORD /d 1 /f 2>/dev/null || true; \
    WINEDEBUG=-all wineboot --init 2>/dev/null || true; \
    winetricks -q dotnet48 corefonts tahoma || { echo "ERROR: winetricks dotnet48 failed"; exit 1; }; \
    winetricks -q win10 || true; \
    WINEDEBUG=-all wine /resources/python-3.12.7.exe /quiet PrependPath=1 Include_doc=0 2>/dev/null \
        || echo "WARNING: Python installer exited non-zero — will install at addon start if needed."; \
    PYEXE="/wineprefix-base/drive_c/users/root/AppData/Local/Programs/Python/Python312-32/python.exe"; \
    [ -f "$PYEXE" ] && WINEDEBUG=-all wine "$PYEXE" -m pip install --quiet pycryptodome 2>/dev/null \
        || echo "WARNING: pycryptodome install skipped or failed."; \
    WINEDEBUG=-all wine /resources/ADE_4.0.3_Installer.exe /S 2>/dev/null \
        || echo "WARNING: ADE installer exited non-zero — will install at addon start if needed."; \
    sleep 10; \
    touch /wineprefix-base/.winetricks_done; \
    kill $XVFB_PID 2>/dev/null || true'
