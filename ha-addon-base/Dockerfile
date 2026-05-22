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
