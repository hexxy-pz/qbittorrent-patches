# syntax=docker/dockerfile:1
#
# qBittorrent: linuxserver image with qbittorrent-nox rebuilt from the image's release and libtorrent-rasterbar
# from release ARG LIBTORRENT_VERSION (2.0.x; the image packages 2.0.11), plus ./patches/libtorrent and
# ./patches/qbittorrent. Drop-in replacement for lscr.io/linuxserver/qbittorrent.
#
# Only /usr/lib/libtorrent-rasterbar.so.* and /usr/bin/qbittorrent-nox are replaced (and Qt is lined up with
# the Qt they were compiled against, see the final stage), and Scudo (Alpine's scudo-malloc) is preloaded as
# the allocator. The s6 services stay exactly as linuxserver ships them, plus one add-on: an optional
# torrent-stats exporter (./exporter, an extra s6 service that does nothing unless QBT_EXPORTER_FILE is set). Both are rebuilt the way Alpine's APKBUILDs build them
# (community/libtorrent-rasterbar: CMake/Ninja, C++17; community/qbittorrent: CMake/Ninja, GUI=OFF; abuild's
# CFLAGS plus -O2 -DNDEBUG -flto=auto), against boost 1.84 - the same boost the image's packages were built
# with, so the ABI between them is unchanged.
#
# The version is the release tarball's: qbittorrent-nox --version, the peer ID (-qB5140-) and the
# User-Agent (qBittorrent/5.1.4) come from src/base/version.h.in, which no patch may touch (checked below),
# and the final stage fails if --version differs from the packaged binary it replaces.
#
# APPLY_PATCHES=0 builds both unpatched with the same toolchain (benchmark control).
#
# Renovate bumps LSIO_TAG within 5.1.x only: from 5.2 on linuxserver ships a static qbittorrent-nox
# (/app/qbittorrent-nox, libtorrent compiled in), which has no library to swap. The base stage fails
# loudly if the image has no libtorrent-rasterbar package.
# ghcr.io is where linuxserver publishes; lscr.io is only a rate-limited redirector to it.
ARG LSIO_IMAGE=ghcr.io/linuxserver/qbittorrent
ARG LSIO_TAG=5.1.4-r3-ls453
# libtorrent built for the image (2.0.x; the packaged 2.0.11 is four releases behind, see README); Renovate
# bumps it within 2.0.x, and the build fails if a patch no longer applies
ARG LIBTORRENT_VERSION=2.0.15

# ---------------------------------------------------------------------------
# 0. Base: the linuxserver image we ship (its libtorrent package is the library swapped out).
# ---------------------------------------------------------------------------
FROM ${LSIO_IMAGE}:${LSIO_TAG} AS base
RUN apk info -e libtorrent-rasterbar \
 && apk list --installed libtorrent-rasterbar | sed -E 's/^libtorrent-rasterbar-([0-9.]+)-r.*/\1/' > /libtorrent-version \
 && apk list --installed qbittorrent-nox | sed -E 's/^qbittorrent-nox-([0-9.]+)-r.*/\1/' > /qbittorrent-version \
 && test -s /qbittorrent-version \
 && echo "libtorrent-rasterbar in image: $(cat /libtorrent-version), qbittorrent-nox: $(cat /qbittorrent-version)"

# ---------------------------------------------------------------------------
# 1. Build: same Alpine as the image (edge), release tarball, patches, APKBUILD flags.
# ---------------------------------------------------------------------------
FROM base AS build
ARG APPLY_PATCHES=1
ARG LIBTORRENT_VERSION
RUN apk add --no-cache abuild build-base cmake samurai linux-headers boost-dev openssl-dev curl-dev patch \
 && apk list --installed 'boost*-dev' gcc openssl-dev
WORKDIR /src
RUN v="${LIBTORRENT_VERSION}" \
 && echo "==> fetching libtorrent-rasterbar ${v} (image has $(cat /libtorrent-version))" \
 && curl -fsSL "https://github.com/arvidn/libtorrent/releases/download/v${v}/libtorrent-rasterbar-${v}.tar.gz" | tar -xz --strip-components=1 \
 && test -f src/mmap_disk_io.cpp
COPY patches/libtorrent/ /patches/
RUN set -e; \
    if [ "$APPLY_PATCHES" = 1 ]; then \
      for p in /patches/*.patch; do \
        echo "==> applying $(basename "$p")"; \
        patch -p1 --dry-run -s < "$p"; \
        patch -p1 < "$p"; \
      done; \
    else echo "==> APPLY_PATCHES=0: building unpatched"; fi
RUN set -e; . /etc/abuild.conf; \
    export CFLAGS CXXFLAGS LDFLAGS; \
    CXXFLAGS="$CXXFLAGS -O2 -DNDEBUG -flto=auto" \
    cmake -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=None \
      -DCMAKE_CXX_STANDARD=17 \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -Dbuild_tests=OFF \
      -Dpython-bindings=OFF \
      -Dcurl-trackers=ON \
 && cmake --build build \
 && cmake --install build \
 && mkdir -p /out \
 && cp -a build/libtorrent-rasterbar.so.* /out/ \
 && ls -la /out

# ---------------------------------------------------------------------------
# 2. qbittorrent-nox: the image's release, patches, APKBUILD flags, linked against the library above.
# ---------------------------------------------------------------------------
FROM build AS qbt
ARG APPLY_PATCHES=1
RUN apk add --no-cache qt6-qtbase-dev qt6-qtbase-private-dev qt6-qttools-dev zlib-dev sqlite-dev \
 && apk list --installed qt6-qtbase | sed -E 's/^qt6-qtbase-([^ ]+) .*/\1/' > /qt-version \
 && echo "building against qt6-qtbase $(cat /qt-version)"
WORKDIR /src-qbt
RUN v="$(cat /qbittorrent-version)" \
 && echo "==> fetching qBittorrent ${v}" \
 && curl -fsSL "https://github.com/qbittorrent/qBittorrent/archive/refs/tags/release-${v}.tar.gz" | tar -xz --strip-components=1 \
 && grep -q "QBT_VERSION_MAJOR $(echo "$v" | cut -d. -f1)$" src/base/version.h.in
COPY patches/qbittorrent/ /patches-qbt/
# The client identity trackers whitelist (peer ID, User-Agent, version) must stay the release's.
RUN set -e; \
    if grep -lE '^(\+\+\+|---) [ab]/src/base/version\.h\.in' /patches-qbt/*.patch; then \
      echo "a qBittorrent patch touches src/base/version.h.in"; exit 1; fi; \
    if grep -nE '^[+-][^+-].*(PEER_ID|USER_AGENT|QBT_VERSION|generate_fingerprint)' /patches-qbt/*.patch; then \
      echo "a qBittorrent patch touches the client identity"; exit 1; fi; \
    if [ "$APPLY_PATCHES" = 1 ]; then \
      for p in /patches-qbt/*.patch; do \
        echo "==> applying $(basename "$p")"; \
        patch -p1 --dry-run -s < "$p"; \
        patch -p1 < "$p"; \
      done; \
    else echo "==> APPLY_PATCHES=0: building unpatched"; fi
# cmake --install above put the rebuilt library in /usr/lib64, which the musl loader does not search: run the
# check against it (/out), not the image's packaged library in /usr/lib.
RUN set -e; . /etc/abuild.conf; \
    export CFLAGS="$CFLAGS -DNDEBUG -O2 -flto=auto" CXXFLAGS="$CXXFLAGS -DNDEBUG -O2 -flto=auto" LDFLAGS; \
    cmake -B build-nox -G Ninja \
      -DCMAKE_BUILD_TYPE=None \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -DGUI=OFF \
      -DWEBUI=ON \
      -DSTACKTRACE=OFF \
      -DTESTING=OFF \
 && cmake --build build-nox \
 && mkdir -p /out-qbt \
 && cp build-nox/qbittorrent-nox /out-qbt/ \
 && LD_LIBRARY_PATH=/out /out-qbt/qbittorrent-nox --version

# ---------------------------------------------------------------------------
# 3. Final: the linuxserver image with the library and qbittorrent-nox swapped.
# ---------------------------------------------------------------------------
FROM base
ARG APPLY_PATCHES=1
# The linuxserver image froze Alpine edge's Qt when it was built; the build stage compiled against edge's
# current Qt. Patch releases are binary compatible both ways, but run on exactly the Qt we compiled against
# anyway (a no-op while they are the same).
COPY --from=qbt /qt-version /tmp/qt-version
RUN qt="$(cat /tmp/qt-version)" \
 && if [ "$(apk list --installed qt6-qtbase | sed -E 's/^qt6-qtbase-([^ ]+) .*/\1/')" != "$qt" ]; then \
      apk add --no-cache --upgrade "qt6-qtbase=$qt" "qt6-qtbase-sqlite=$qt"; fi \
 && apk list --installed 'qt6-qtbase*' \
 && qbittorrent-nox --version > /tmp/stock-version \
 && rm /tmp/qt-version
COPY --from=build /out/ /usr/lib/
ARG LIBTORRENT_VERSION
# the packaged library (other version) is no longer linked: libtorrent-rasterbar.so.2.0 points at ours
RUN for f in /usr/lib/libtorrent-rasterbar.so.2.0.*; do \
      [ "$f" = "/usr/lib/libtorrent-rasterbar.so.${LIBTORRENT_VERSION}" ] || rm -f "$f"; done \
 && test -e "/usr/lib/libtorrent-rasterbar.so.${LIBTORRENT_VERSION}"
COPY --from=qbt /out-qbt/qbittorrent-nox /usr/bin/qbittorrent-nox
COPY patches/libtorrent/ /tmp/patches/
COPY patches/qbittorrent/ /tmp/patches-qbt/
RUN if [ "$APPLY_PATCHES" = 1 ]; then ls /tmp/patches > /etc/libtorrent-patches; else : > /etc/libtorrent-patches; fi \
 && if [ "$APPLY_PATCHES" = 1 ]; then ls /tmp/patches-qbt > /etc/qbittorrent-patches; else : > /etc/qbittorrent-patches; fi \
 && rm -rf /tmp/patches /tmp/patches-qbt \
 && ls -la /usr/lib/libtorrent-rasterbar.so* /usr/bin/qbittorrent-nox \
 && ldd /usr/bin/qbittorrent-nox | grep -q 'libtorrent-rasterbar.so.2.0 => /usr/lib/libtorrent-rasterbar.so.2.0' \
 && qbittorrent-nox --version \
 && { [ "$(qbittorrent-nox --version)" = "$(cat /tmp/stock-version)" ] \
      || { echo "version differs from the packaged binary: $(cat /tmp/stock-version)"; exit 1; }; } \
 && rm /tmp/stock-version

# Scudo (LLVM's hardened allocator, Alpine's signed scudo-malloc package) for every process of the container,
# qbittorrent-nox above all: checksummed chunk headers, quarantine before reuse, randomization, abort on any
# inconsistency; 10 % less memory than musl's allocator at about its speed (README "Memory allocator").
# Off for a container: -e LD_PRELOAD= ; off for a build: --build-arg ALLOCATOR_PRELOAD=
ARG ALLOCATOR_PRELOAD=/usr/lib/libscudo.so
RUN apk add --no-cache scudo-malloc \
 && LD_PRELOAD=/usr/lib/libscudo.so qbittorrent-nox --version
ENV LD_PRELOAD=${ALLOCATOR_PRELOAD}

# Optional torrent-stats exporter for node-exporter's textfile collector (see README). Python stdlib only.
COPY --chmod=755 exporter/qbittorrent-exporter.py /usr/local/bin/qbittorrent-exporter
COPY exporter/s6-rc.d/ /etc/s6-overlay/s6-rc.d/
RUN chmod 755 /etc/s6-overlay/s6-rc.d/svc-qbittorrent-exporter/run /etc/s6-overlay/s6-rc.d/svc-qbittorrent-exporter/finish \
 && python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' /usr/local/bin/qbittorrent-exporter
