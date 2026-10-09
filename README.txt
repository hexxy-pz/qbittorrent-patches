qBittorrent / libtorrent patch series
=====================================

A drop-in replacement for the linuxserver qBittorrent image
(ghcr.io/linuxserver/qbittorrent 5.1.4) with libtorrent-rasterbar and
qbittorrent-nox rebuilt from their release tarballs plus the patches below.
Nothing else in the image changes: same s6 services, same peer ID and
User-Agent as the stock 5.1.4 release (the build fails if a patch touches them).

Contents
  Dockerfile               multi-stage build (needs BuildKit)
  .dockerignore
  patches/libtorrent/      applied to libtorrent 2.0.15 in file-name order
  patches/qbittorrent/     applied to qBittorrent 5.1.4 in file-name order
  exporter/                optional torrent-stats exporter (extra s6 service)

Build
  docker build -t qbittorrent-patched .

  Build args:
    LSIO_TAG=5.1.4-r3-ls453     linuxserver base tag (5.1.x only; 5.2+ ships a
                                static binary with no library to swap)
    LIBTORRENT_VERSION=2.0.15   libtorrent release to build (2.0.x)
    APPLY_PATCHES=0             same toolchain, no patches (comparison build)
    ALLOCATOR_PRELOAD=          build without the Scudo allocator preload

  The image lists the applied patches in /etc/libtorrent-patches and
  /etc/qbittorrent-patches.

Run
  Same as the linuxserver image (PUID, PGID, TZ, WEBUI_PORT, /config, ...).
  Scudo is preloaded for every process; disable it with -e LD_PRELOAD= .

  Optional exporter (Prometheus text format for node-exporter's textfile
  collector), off unless QBT_EXPORTER_FILE is set:
    QBT_EXPORTER_FILE      output file, e.g. /config/metrics/qbittorrent.prom
    QBT_EXPORTER_INTERVAL  seconds between collections (default 60)
    QBT_EXPORTER_URL       WebUI base URL (default http://localhost:$WEBUI_PORT)
    QBT_EXPORTER_TIMEOUT   HTTP timeout in seconds (default 30)
  It needs "Bypass authentication for clients on localhost" in the WebUI settings.

Patches without Docker
  cd libtorrent-2.0.15             && for p in /path/to/patches/libtorrent/*.patch;  do patch -p1 < "$p"; done
  cd qBittorrent-release-5.1.4     && for p in /path/to/patches/qbittorrent/*.patch; do patch -p1 < "$p"; done
  The files are git format-patch output, so "git am" works as well.

  The qBittorrent series expects the patched libtorrent: qbittorrent/0015-0016
  configure the per-tracker announce settings added by libtorrent/0002, and
  qbittorrent/0019 uses the on-demand piece hashes from libtorrent/0003.
  qbittorrent/0004-0013 are backports of the WebUI virtual list from
  qBittorrent 5.2 and keep their original upstream authors.

libtorrent
  0001  mmap_disk_io: hash a v1 piece with one storage call
  0002  trackers: per-tracker HTTP queues, down-tracker detection, pooled curl transport
  0003  torrent_info: load SHA-1 piece hashes on demand
  0004  torrent: don't keep peers a non-connecting seed would never use

qBittorrent
  0001  Compile constant path regexes once
  0002  WebAPI: write maindata and torrent list JSON directly
  0003  WebUI: gzip responses over 1 MiB at level 1
  0004  WebUI: Optimize table performance with virtual list
  0005  WebUI: fix virtual list defects
  0006  WebUI: Increase number of buffered virtual rows
  0007  WebUI: Fix row selection by Shift key with virtual list enabled
  0008  WebUI: Avoid forced reflow on virtual list rerender
  0009  WebUI: Fix column reordering with virtual rows
  0010  WebUI: Fix keyboard navigation when using virtual rendering
  0011  WebUI: Fix row collapsing with virtual list enabled
  0012  WebUI: Fix header text displayed in table in Firefox
  0013  WebUI: Enable virtual list by default
  0014  Add setting for outgoing connections of seeding torrents
  0015  Add setting to override libtorrent settings
  0016  Add settings for per-tracker announce limits
  0017  Keep tracker endpoint statuses in a list
  0018  Don't keep per-torrent piece bitfields for seeds
  0019  Load piece hashes of idle torrents from the resume data database
  0020  WebUI: Expire unconfirmed sessions early and cap sessions
  0021  Free the torrent extension's initial data once it is used
  0022  Keep pending tracker status updates in a flat list
