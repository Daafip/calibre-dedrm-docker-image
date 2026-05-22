FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        calibre \
        curl \
        git \
        jq \
        libcurl4-openssl-dev \
        libpugixml-dev \
        libssl-dev \
        libzip-dev \
        python3 \
        unzip \
        wget \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /resources

# Build libgourou from source — native Linux ADEPT implementation.
# Replaces Wine + ADE + dotnet48 entirely. No 20-minute first-run setup.
# Uses Makefile. 'make' runs scripts/setup.sh which clones uPDFParser,
# then builds the library + CLI utils (BUILD_UTILS defaults to 1).
RUN git clone --depth 1 \
        https://forge.soutade.fr/soutade/libgourou.git /tmp/libgourou \
    && cd /tmp/libgourou \
    && ./scripts/setup.sh \
    && make -j"$(nproc)" \
    && make install PREFIX=/usr/local \
    && ldconfig \
    && rm -rf /tmp/libgourou

# DeDRM 10.0.3 + Obok (kept for directly-supplied encrypted EPUBs)
RUN wget -q -O /tmp/dedrm.zip \
       "https://github.com/noDRM/DeDRM_tools/releases/download/v10.0.3/DeDRM_tools_10.0.3.zip" \
    && unzip -q /tmp/dedrm.zip "DeDRM_Plugin.zip" "Obok_plugin.zip" -d /resources/ \
    && rm /tmp/dedrm.zip \
    || echo "WARNING: DeDRM download failed."
