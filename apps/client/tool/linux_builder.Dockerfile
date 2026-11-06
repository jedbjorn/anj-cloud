# Generic Debian startup objects and libraries: never link against the host CRT.
FROM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3
RUN apt-get update && apt-get install -y --no-install-recommends \
    binutils ca-certificates clang cmake curl git libgtk-3-dev libsecret-1-dev \
    libglu1-mesa ninja-build pkg-config python3 unzip xz-utils zip \
    qemu-user xvfb xauth dbus-x11 \
    && rm -rf /var/lib/apt/lists/*
ENV FLUTTER_SDK=/opt/flutter FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true \
    PUB_CACHE=/opt/pub-cache CFLAGS="-march=x86-64 -mtune=generic" \
    CXXFLAGS="-march=x86-64 -mtune=generic" LC_ALL=C.UTF-8
