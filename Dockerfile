FROM --platform=linux/amd64 ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    git curl python3 python3-pip lsb-release sudo file \
    build-essential pkg-config ccache rsync procps findutils \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git /opt/depot_tools
ENV PATH="/opt/depot_tools:${PATH}"

# Pre-warm depot_tools to avoid first-run lock races
RUN gclient --version || true

ENV CCACHE_DIR=/root/.ccache
RUN ccache -M 10G

WORKDIR /v8

# Bake the entrypoint script into the image so the container is
# self-contained (the runtime bind mount in build.ps1 overrides this
# copy when it works, but a failed/absent mount no longer breaks exec).
COPY build-inside.sh /usr/local/bin/build-inside.sh
RUN chmod +x /usr/local/bin/build-inside.sh

ENTRYPOINT ["/usr/local/bin/build-inside.sh"]
