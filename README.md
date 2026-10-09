# qBittorrent 5.1.4 + libtorrent 2.0.15: performance, memory and tracker patches

A drop-in rebuild of the linuxserver qBittorrent image (`ghcr.io/linuxserver/qbittorrent` 5.1.4): qbittorrent-nox
is rebuilt from the image's release and libtorrent-rasterbar from release 2.0.15 (the image packages 2.0.11, four
releases behind, missing fixes in HTTP response parsing, tracker URL checks, SOCKS5, the UPnP XML parser, an mmap
storage corruption bug and DNS leaks of tracker-supplied peer hostnames), both with the patches below, and Scudo
is preloaded as the allocator. The client identity (peer ID, User-Agent, `--version`) stays the stock release's;
the build fails if a patch touches it.

Benchmarks ran on 7,800 to 8,900 seeding torrents. Each comparison is against the same version built unpatched
with the same toolchain, unless noted.

## Summary

| Area | Patches | Result |
|---|---|---|
| Piece hashing (rechecks) | libtorrent 0001 | **+202 % throughput, -76 % CPU per GB** (32 hashing threads); +126 % / -61 % at 8 threads |
| Opening the WebUI (`sync/maindata`) | qBittorrent 0001-0003 | **-65 % main-thread time** (1,267 to 444 ms); reload -77 %; `torrents/info` -56 % |
| WebUI torrent table | qBittorrent 0004-0013 | **-81 % time to a usable table** (Chromium), -78 % (Firefox); -99 % DOM rows |
| Tracker announces | libtorrent 0002, qBittorrent 0015-0016 | **-99.9 % connections** per HTTP/2 tracker, -94 % per HTTP/1.1 tracker; -99.8 % SYNs to a dead tracker |
| Seed-to-seed connection churn | qBittorrent 0014 | up to 50 redundant outgoing connections per second to 0 (opt-in setting) |
| Idle memory | libtorrent 0003-0004, qBittorrent 0017-0019, 0021-0022 | **-78 % RSS** with 0017-0019 (1,552 to 340 MB, ~8,900 torrents), 293 MB with 0021-0022 and mimalloc 3; **-77 % on a long-running instance** (2.0 GB to 465 MB) |
| Memory allocator | **Scudo** preloaded (evaluated: musl, jemalloc, mimalloc 2/3 regular and secure, Scudo) | **-10 % memory** against musl at about its speed, with the strongest heap hardening |
| WebUI session memory | qBittorrent 0020 | 85-120 MB pinned per cookieless `sync/maindata` call, unbounded, to capped |

Every new behaviour has a setting in the WebUI (Options), the WebAPI preferences and `qBittorrent.conf`.

## Contents

| Path | |
|---|---|
| `Dockerfile` | multi-stage build (needs BuildKit) |
| `patches/libtorrent/` | applied to libtorrent 2.0.15 in file-name order |
| `patches/qbittorrent/` | applied to qBittorrent 5.1.4 in file-name order |
| `exporter/` | optional torrent-stats exporter (extra s6 service) |

## Build

```sh
docker build -t qbittorrent-patched .
```

| Build arg | Default | |
|---|---|---|
| `LSIO_TAG` | `5.1.4-r3-ls453` | linuxserver base tag; 5.1.x only (5.2+ ships a static binary with no library to swap) |
| `LIBTORRENT_VERSION` | `2.0.15` | libtorrent release to build (2.0.x) |
| `APPLY_PATCHES` | `1` | `0` builds both unpatched with the same toolchain (comparison build) |
| `ALLOCATOR_PRELOAD` | `/usr/lib/libscudo.so` | empty builds without the Scudo preload |

The image lists the applied patches in `/etc/libtorrent-patches` and `/etc/qbittorrent-patches`.

## Run

Same as the linuxserver image (`PUID`, `PGID`, `TZ`, `WEBUI_PORT`, `/config`, ...). Scudo is preloaded for every
process; `-e LD_PRELOAD=` turns it off.

The optional exporter writes Prometheus text format for node-exporter's textfile collector and stays off unless
`QBT_EXPORTER_FILE` is set. It needs "Bypass authentication for clients on localhost" in the WebUI settings.

| Variable | Default | |
|---|---|---|
| `QBT_EXPORTER_FILE` | | output file, e.g. `/config/metrics/qbittorrent.prom` |
| `QBT_EXPORTER_INTERVAL` | `60` | seconds between collections |
| `QBT_EXPORTER_URL` | `http://localhost:$WEBUI_PORT` | WebUI base URL |
| `QBT_EXPORTER_TIMEOUT` | `30` | HTTP timeout in seconds |

## Patches without Docker

```sh
cd libtorrent-2.0.15         && for p in /path/to/patches/libtorrent/*.patch;  do patch -p1 < "$p"; done
cd qBittorrent-release-5.1.4 && for p in /path/to/patches/qbittorrent/*.patch; do patch -p1 < "$p"; done
```

The files are `git format-patch` output, so `git am` works as well. The qBittorrent series expects the patched
libtorrent: qBittorrent 0015-0016 configure the tracker settings added by libtorrent 0002, and qBittorrent 0019
uses the on-demand piece hashes from libtorrent 0003.

## libtorrent

### 0001: hash a v1 piece with one storage call
During a recheck, 75 % of qBittorrent's CPU went to the kernel, mostly futex contention: every 16 KiB block
took the store buffer's global mutex, a file pool lookup and a fresh scratch allocation. The patch hashes a
whole v1 piece per storage call when none of its blocks are pending writes, and reads in bounded 256 KiB
chunks.

- 32 threads: 2.97 to 8.97 GB/s (+202 %), 114 to 478 MB hashed per CPU-second (-76 % CPU per GB)
- 8 threads: 2.78 to 6.29 GB/s (+126 %), 454 to 1,171 MB per CPU-second (-61 % CPU per GB)

### 0002: per-tracker announce queues, down-tracker detection, pooled HTTP/2 transport
Stock libtorrent sends every HTTP(S) announce through one global queue, each on its own connection with
`Connection: close`, so one slow or dead tracker holds back everyone else.

- Queues per tracker, round-robin between trackers, adaptive concurrency per tracker
- A tracker that keeps failing is treated as down: its requests wait without taking slots, one probe at a
  time finds out when it is back
- libcurl multi transport: kept-alive connections, HTTP/2 multiplexing, proxy support; name resolution, SSRF
  mitigation, the IP filter and listen-socket routing stay in libtorrent
- Queued requests time out (default 600 s) and each tracker's queue is capped (default 20,000)
- A torrent's requests to one tracker go out one at a time, in the order they were made; high priority
  announces (libtorrent 2.0.12+) pass other torrents' requests, never an older one of their own
- The queue timer is cancelled when nothing waits on it (it used to keep a shutting-down session alive for up
  to the queue timeout)

Benchmark, 6,750 seeding torrents against five fake trackers:

| | stock | patched | change |
|---|---|---|---|
| connections, HTTP/2 tracker (2,200 torrents) | 2,200 | 3 | -99.9 % |
| connections, HTTP/1.1 tracker (550 torrents) | 550 | 32 | -94 % |
| plain HTTP tracker queued behind slow ones: all announced | 18.5 s | 7.8 s | -58 % |
| SYNs to a dead tracker in 4 minutes | 17,550 | ~40 | -99.8 % |
| shutdown, all `stopped` announces delivered | 21.2 s | 17.4 s | -18 % |
| dead tracker back after 7 minutes: all announced | 0 of 650 within 60 s | 45 s | |

Trade-offs: a fast HTTP/1.1 tracker took 10.9 s instead of 3.7 s for its startup burst (the per-tracker limit
starts at 4 connections and grows), and a tracker back after a 2-minute outage was fully announced to in 25 s
instead of 15 s (probe back-off).

### 0003: load SHA-1 piece hashes on demand
Piece hashes were 99 % of the metadata (792 of 803 MB) and stayed in memory for every torrent, although a seed
only reads them for a recheck, seed-mode piece verification or a metadata export. `torrent_info` can now keep
everything but the hashes in memory and load the info section back through a client callback, verified against
the info-hash, then free it again when idle. A torrent freed too early backs off (up to 16 times the idle time)
so busy torrents do not thrash. Released hashes are freed one release cycle later, so pointers handed to
other threads stay valid.

- Reload from the qBittorrent database: p50 0.23 ms, p99 2.0 ms, max 15 ms (5 MB of metadata); with heavy
  concurrent database writes p99 2.5 ms

### 0004: no peer list for seeds that never connect out
With `seeding_outgoing_connections` off, a seeding torrent never connects to the peers trackers and resume
data hand out, and a private torrent has no DHT or PEX that would use them, so they are no longer kept (about
48 bytes each). Banned peers are kept, incoming peers are added as before, and the seed/leech counts still come
from the trackers' reported counts.

## qBittorrent

### 0001-0003: faster `sync/maindata` and `torrents/info`
Compile constant path regexes once, write the JSON directly instead of through `QJsonObject`, gzip large
responses at level 1.

| request (~7,800 torrents) | stock | patched | change |
|---|---|---|---|
| `maindata`, new session (opening the WebUI) | 1,267 ms | 444 ms | -65 % |
| `maindata`, same session (reload) | 927 ms | 218 ms | -77 % |
| `torrents/info?includeTrackers=true` | 1,598 ms | 708 ms | -56 % |

Responses are value-for-value identical to stock. RSS after the runs: -21 % (1.9 to 1.5 GiB).

### 0004-0013: WebUI virtual list (backport from 5.2)
Upstream's virtual list, cherry-picked with authors kept and on by default: the tables render only the rows in
view.

- Torrent table usable after 7.4 to 1.4 s in Chromium (-81 %), 7.7 to 1.7 s in Firefox (-78 %)
- ~7,800 to 56 table rows in the DOM (-99 %)

### 0014: setting for outgoing connections of seeding torrents
Exposes libtorrent's `seeding_outgoing_connections`. On private trackers the peer lists are almost all seeds;
a seed connecting out to them only produces connections closed as redundant: up to 50 outgoing connections
per second, 89 % to seeds, with the sweep starting over after every restart. Off, complete torrents only accept
incoming connections. Default stays stock (on).

### 0015-0016: libtorrent settings in qBittorrent
A generic `name=value` override for any libtorrent setting, and the tracker settings of libtorrent 0002 as
regular options (connection pool, HTTP/2, per-tracker limits, failure threshold, connect timeout, queue timeout,
queue cap), applied live.

### 0017: tracker endpoint statuses in a list
Qt 6 allocates 48 entries on a `QHash`'s first insert, about 6 KiB per tracker for one or two endpoints. A list
saves about 48 MB at ~8,900 single-tracker torrents.

### 0018: piece bitfields of seeds as flags
Each torrent kept its piece bitfield up to four times (status, a `QBitArray` copy, cached resume data, plus a
`verified_pieces` copy nothing read). A seed's are all ones, so they are now flags, expanded only where a full
bitfield is needed (about 25 MB at 39.6 million pieces).

### 0019: piece hashes from the resume database
With the SQLite resume data storage, torrents start without their piece hashes in memory (libtorrent 0003);
they are read back from the database on demand (own read-only SQLite connection, WAL) and freed after an idle
time (default 15 minutes) when the torrent is not downloading, checking or moving.

Idle RSS, ~8,900 torrents all seeding, 2 minutes after start:

| | RSS |
|---|---|
| linuxserver 5.1.4, stock | 1,550 MB |
| patches 0001-0016 | 1,552 MB |
| all patches | **340 MB (-78 %)** |

### 0020: WebUI session limits
Under the authentication bypass (localhost or a whitelisted subnet), every request without a session cookie
started a new WebUI session kept for the whole session timeout, and one that called `sync/maindata` held a
full snapshot (85-120 MB at ~8,000 torrents). A client polling without cookies could exhaust memory. New
sessions are now provisional until their cookie comes back (default 60 s), with at most 8 sessions per client
address and 32 in total; provisional sessions are evicted first.

### 0021: free the torrent extension's initial data
qBittorrent's torrent extension collects a new torrent's full status (with its piece bitfields), trackers and
URL seeds for one constructor call, then kept it until the torrent was removed. It is now freed once read.

### 0022: pending tracker updates in a flat list
Tracker alerts queue per-torrent updates (trackers, endpoints, peer counts) until the tracker statuses are
refreshed. They were two levels of nested `QHash`es, each allocating 48 entries on first insert, about 3 KB per
waiting torrent: 29 MB while announces were failing. Now a flat list per torrent.

## Memory allocator
qBittorrent on Alpine uses musl's allocator (mallocng). Same image, each candidate preloaded with
`LD_PRELOAD`, ~8,900 torrents, three rounds against musl in the same run (rounds vary by about 10 %); load = 10
full `sync/maindata` + 10 `torrents/info` with trackers, through one session:

| allocator | idle RSS | peak in the first minutes | startup CPU | idle CPU | load CPU | `torrents/info` |
|---|---|---|---|---|---|---|
| musl (mallocng) | 332-341 MB | ~340 MB | 36-38 s | 4.5 s per 8 min | 8.5-9.8 s | 690-730 ms |
| jemalloc 5.3 | +7 % | | -25 % | | -38 % | -37 % |
| mimalloc 2.2 regular | +55 % (keeps freed memory) | | -28 % | | -44 % | -42 % |
| mimalloc 3.5 regular | -3 % | ~610 MB | -27 % | -30 % | -46 % | -45 % |
| mimalloc 3.5 secure | +3 % | **~1.4 GB** | -28 % | -2 % | -20 to -35 % | -24 to -39 % |
| **Scudo** (LLVM) | **-10 %** | ~308 MB | -7 % | same | -4 % | -6 % |

Security, from the sources (musl 1.2.5, mimalloc 3.5.0 with `MI_SECURE=ON`):

- **musl mallocng**: no free-list pointers inside freed memory (free slots are bitmasks in out-of-band
  metadata); every `free()` validates the slot header against the metadata and a per-process secret; double
  and invalid frees and small overflows abort. Layout is deterministic.
- **mimalloc regular**: free lists stored in freed blocks as plain pointers, no guard pages, little
  corruption detection: a much easier target for heap exploitation.
- **mimalloc secure**: free-list pointers encoded and checked, guard pages around metadata, randomized
  allocation; corruption aborts, but double and invalid frees are only logged.
- **Scudo**: checksummed chunk headers, quarantine before reuse, randomization; aborts on every
  inconsistency. The hardened allocator Android uses.

Scudo uses the least memory and hardens the most, at roughly musl's speed; regular mimalloc 3 is the fastest
at musl's memory but gives up most heap hardening. The image ships **Scudo** (Alpine's signed `scudo-malloc`
package, `LD_PRELOAD`; `-e LD_PRELOAD=` turns it off). Rechecks hash at the same CPU cost with it (1,206 vs
1,135 MB per CPU-second for musl, 8 hashing threads). A running qbittorrent-nox binds `malloc`/`free` in Qt
and libtorrent to Scudo, and the exporter reports the allocator in use (`qbittorrent_allocator_info`).

## Patch list

### libtorrent

| | |
|---|---|
| 0001 | mmap_disk_io: hash a v1 piece with one storage call |
| 0002 | trackers: per-tracker HTTP queues, down-tracker detection, pooled curl transport |
| 0003 | torrent_info: load SHA-1 piece hashes on demand |
| 0004 | torrent: don't keep peers a non-connecting seed would never use |

### qBittorrent

0004-0013 are upstream commits from qBittorrent 5.2 and keep their original authors.

| | |
|---|---|
| 0001 | Compile constant path regexes once |
| 0002 | WebAPI: write maindata and torrent list JSON directly |
| 0003 | WebUI: gzip responses over 1 MiB at level 1 |
| 0004 | WebUI: Optimize table performance with virtual list |
| 0005 | WebUI: fix virtual list defects |
| 0006 | WebUI: Increase number of buffered virtual rows |
| 0007 | WebUI: Fix row selection by Shift key with virtual list enabled |
| 0008 | WebUI: Avoid forced reflow on virtual list rerender |
| 0009 | WebUI: Fix column reordering with virtual rows |
| 0010 | WebUI: Fix keyboard navigation when using virtual rendering |
| 0011 | WebUI: Fix row collapsing with virtual list enabled |
| 0012 | WebUI: Fix header text displayed in table in Firefox |
| 0013 | WebUI: Enable virtual list by default |
| 0014 | Add setting for outgoing connections of seeding torrents |
| 0015 | Add setting to override libtorrent settings |
| 0016 | Add settings for per-tracker announce limits |
| 0017 | Keep tracker endpoint statuses in a list |
| 0018 | Don't keep per-torrent piece bitfields for seeds |
| 0019 | Load piece hashes of idle torrents from the resume data database |
| 0020 | WebUI: Expire unconfirmed sessions early and cap sessions |
| 0021 | Free the torrent extension's initial data once it is used |
| 0022 | Keep pending tracker status updates in a flat list |
