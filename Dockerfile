FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        calibre \
        wine \
        wine32:i386 \
        winetricks \
        winbind \
        xvfb \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m calibre

ENV WINEARCH=win32 \
    WINEPREFIX=/home/calibre/wineprefix \
    CALIBRE_CONFIG_DIRECTORY=/home/calibre/calibre-config \
    BOOKS_DIR=/home/calibre/books

COPY resources/ /resources/
RUN chown -R calibre:calibre /resources/

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER calibre
WORKDIR /home/calibre

ENTRYPOINT ["/entrypoint.sh"]
