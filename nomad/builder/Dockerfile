# Termux aarch64 builder — builds Python/Node.js artifacts with native extensions
# compatible with Termux on Android phones (Bionic libc, not glibc).
#
# Build:
#   cd android-nomad-termux-setup/nomad/builder
#   bash build-image.sh
#
# The image includes: Python 3.12, pip, Node.js, npm, Rust (for native extensions
# like pydantic-core), and all necessary libraries.
#
# DNS note: The Termux Docker image has broken internal DNS (dnsmasq fails).
# We inject /system/etc/hosts at build time via --add-host flags passed by
# build-image.sh, and bake resolved IPs into the image for runtime use.

FROM termux/termux-docker:aarch64

# Bake DNS entries into the Android hosts file so apt/pip/npm work at runtime.
# These are Cloudflare/Fastly anycast IPs — stable across regions.
# If they ever go stale, rebuild the image (build-image.sh re-resolves them).
COPY system-hosts /tmp/system-hosts

# Copy hosts file as root (only root can write to /system/etc)
RUN cp /tmp/system-hosts /system/etc/hosts && rm /tmp/system-hosts

# Switch to the container's non-root user (Termux's apt refuses to run as root)
USER system

# Upgrade base packages first (fixes OpenSSL version mismatch with Python),
# then install the full toolchain.
RUN apt update -qq && \
    yes | apt upgrade && \
    apt install -yq \
        python python-pip \
        nodejs \
        libexpat \
        rust \
        git \
        libjpeg-turbo \
        libpng \
        freetype \
    && apt clean && \
    rm -rf /data/data/com.termux/files/usr/var/cache/apt/* && \
    python3 --version && pip --version && node --version && npm --version && rustc --version

# Pre-install build tools so --no-build-isolation works, and maturin so
# Rust-based packages (pydantic-core) don't rebuild it every time.
RUN pip install --break-system-packages setuptools wheel maturin 2>&1 | tail -5

# Set up working directories used by nomad-deploy.sh
USER root
RUN mkdir -p /src /build /out && chown system:system /src /build /out
USER system

WORKDIR /build
