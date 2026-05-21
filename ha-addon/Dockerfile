ARG BUILD_FROM=ubuntu:24.04
FROM $BUILD_FROM

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

# Download DeDRM 10.0.3 + Obok from the noDRM GitHub release.
# These are open source (GPLv3) and freely redistributable.
# RUN mkdir -p /resources \
#     && wget -q -O /tmp/dedrm.zip \
#        "https://github.com/noDRM/DeDRM_tools/releases/download/v10.0.3/DeDRM_tools_10.0.3.zip" \
#     && unzip -q /tmp/dedrm.zip "DeDRM_Plugin.zip" "Obok_plugin.zip" -d /resources/ \
#     && rm /tmp/dedrm.zip \
#     || echo "WARNING: DeDRM download failed — the addon will not work without DeDRM_Plugin.zip."

# Download 32-bit Python 3.12.7 installer (used by DeDRM to extract the ADEPT key).
RUN wget -q -O /resources/python-3.12.7.exe \
       "https://www.python.org/ftp/python/3.12.7/python-3.12.7.exe" \
    || echo "WARNING: Python download failed — place python-3.12.7.exe in /resources/ manually."

# Download ADE 4.0.3 installer from Adobe's public CDN.
# 4.0.3 is preferred over 4.5 — 4.5's rmsdk_wrapper crashes on Wine 9.x.
RUN wget -q -O /resources/ADE_4.0.3_Installer.exe \
       "https://adedownload.adobe.com/pub/adobe/digitaleditions/ADE_4.0.3_Installer.exe" \
    || echo "WARNING: ADE download failed — place ADE_4.0.3_Installer.exe in /share/calibre-dedrm/resources/."

# Pre-fetch Wine Gecko to avoid a CDN hit on every fresh prefix.
RUN mkdir -p /usr/share/wine/gecko \
    && wget -q -O /usr/share/wine/gecko/wine_gecko-2.47.4-x86.msi \
       "https://dl.winehq.org/wine/wine-gecko/2.47.4/wine_gecko-2.47.4-x86.msi" \
    || echo "Warning: Gecko pre-fetch failed; wineboot will download it on first run."

ENV WINEARCH=win32

COPY run.sh /run.sh
RUN chmod +x /run.sh

ENTRYPOINT ["/run.sh"]
