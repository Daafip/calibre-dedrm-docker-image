ARG BUILD_FROM=ghcr.io/daafip/calibre-dedrm-docker-image/calibre-dedrm-base:latest
FROM $BUILD_FROM

COPY run.sh /run.sh
COPY upload_server.py /upload_server.py
COPY send_email.py /send_email.py
COPY library_sensor.py /library_sensor.py
COPY kb_login.py /kb_login.py
RUN chmod +x /run.sh

ARG BUILD_VERSION=dev
RUN echo "$BUILD_VERSION" > /build-info.txt

ENTRYPOINT ["/run.sh"]
