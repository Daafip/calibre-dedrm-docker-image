FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        cabextract \
        calibre \
        libgl1-mesa-dri \
        libgl1:i386 \
        wine \
        wine32:i386 \
        winetricks \
        wget \
        winbind \
        xdotool \
        xvfb \
    && rm -rf /var/lib/apt/lists/*

RUN userdel -r ubuntu 2>/dev/null || true; \
    useradd -m -u 1000 calibre && \
    mkdir -p /home/calibre/.cache/mesa_shader_cache && \
    chown -R calibre:calibre /home/calibre/.cache

ENV WINEARCH=win32 \
    WINEPREFIX=/home/calibre/wineprefix \
    CALIBRE_CONFIG_DIRECTORY=/home/calibre/calibre-config \
    BOOKS_DIR=/home/calibre/books

# Pre-download Wine Gecko so wineboot auto-installs it into any new prefix.
# Non-fatal: if the CDN is unreachable at build time, wineboot will fetch it
# on first run (the container has outbound network access by default).
RUN mkdir -p /usr/share/wine/gecko \
    && wget -q -O /usr/share/wine/gecko/wine_gecko-2.47.4-x86.msi \
       https://dl.winehq.org/wine/wine-gecko/2.47.4/wine_gecko-2.47.4-x86.msi \
    || echo "Warning: Gecko pre-fetch failed; wineboot will download it on first run."

COPY resources/ /resources/
RUN chown -R calibre:calibre /resources/

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER calibre
WORKDIR /home/calibre

ENTRYPOINT ["/entrypoint.sh"]
