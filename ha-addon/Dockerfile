ARG BUILD_FROM=ghcr.io/daafip/calibre-dedrm-docker-image/calibre-dedrm-base:latest
FROM $BUILD_FROM

COPY run.sh /run.sh
COPY upload_server.py /upload_server.py
RUN chmod +x /run.sh

ENTRYPOINT ["/run.sh"]
