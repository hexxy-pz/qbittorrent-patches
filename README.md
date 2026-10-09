# qBittorrent 5.1.4 + libtorrent 2.0.15: performance, memory and tracker patches

A drop-in rebuild of the linuxserver qBittorrent image (`ghcr.io/linuxserver/qbittorrent` 5.1.4): qbittorrent-nox
is rebuilt from the image's release and libtorrent-rasterbar from release 2.0.15 (the image packages 2.0.11, four
releases behind, missing fixes in HTTP response parsing, tracker URL checks, SOCKS5, the UPnP XML parser, an mmap
storage corruption bug and DNS leaks of tracker-supplied peer hostnames), both with the patches below, and Scudo
is preloaded as the allocator. The client identity (peer ID, User-Agent, `--version`) stays the stock release's;
the build fails if a patch touches it.

Benchmarks ran on 7,800 to 8,900 seeding torrents. "Before" is the same version built unpatched with the same
toolchain, unless noted.

## Summary

| | Before | After | Result | Patches |
|---|---|---|---|---|
| Recheck speed, 32 hashing threads | 3.0 GB/s | 9.0 GB/s | **3× faster**, ¼ of the CPU per GB | libtorrent 0001 |
| Recheck speed, 8 hashing threads | 2.8 GB/s | 6.3 GB/s | **2.3× faster**, 40 % of the CPU per GB | libtorrent 0001 |
| Opening the WebUI | 1.27 s | 0.44 s | **2.9× faster** | qBittorrent 0001-0003 |
| Torrent table usable in the browser (Chromium) | 7.4 s | 1.4 s | **5× faster** | qBittorrent 0004-0013 |
| Connections to one HTTP/2 tracker (2,200 torrents) | 2,200 | 3 | **99.9 % fewer** | libtorrent 0002 |
| Connection attempts to a dead tracker, 4 minutes | 17,550 | ~40 | **99.8 % fewer** | libtorrent 0002 |
| Redundant outgoing connections from seeds | up to 50 per second | 0 | opt-in setting | qBittorrent 0014 |
| Idle memory (~8,900 torrents) | 1,550 MB | 340 MB | **4.6× less** | libtorrent 0003, qBittorrent 0017-0019 |
| Idle memory, long-running instance | 2.0 GB | 465 MB | **4.3× less** | libtorrent 0003-0004, qBittorrent 0017-0022 |
| Memory allocator: musl → Scudo | ~335 MB | ~300 MB | **10 % less memory**, same speed, strongest heap hardening | Dockerfile |
| WebUI sessions from clients without cookies | unlimited, 85-120 MB each | at most 32 | memory capped | qBittorrent 0020 |

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

| Hashing threads | Speed before | Speed after | Data hashed per CPU-second before | after | Result |
|---|---|---|---|---|---|
| 32 | 2.97 GB/s | 8.97 GB/s | 114 MB | 478 MB | 3× faster, ¼ of the CPU per GB |
| 8 | 2.78 GB/s | 6.29 GB/s | 454 MB | 1,171 MB | 2.3× faster, 40 % of the CPU per GB |

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

Benchmark: 6,750 seeding torrents against five fake trackers.

| | Before | After | Result |
|---|---|---|---|
| Connections to an HTTP/2 tracker (2,200 torrents) | 2,200 | 3 | 99.9 % fewer |
| Connections to an HTTP/1.1 tracker (550 torrents) | 550 | 32 | 94 % fewer |
| Fast tracker stuck behind slow ones: time until all announced | 18.5 s | 7.8 s | 2.4× faster |
| Connection attempts to a dead tracker in 4 minutes | 17,550 | ~40 | 99.8 % fewer |
| Shutdown: time until all `stopped` announces are delivered | 21.2 s | 17.4 s | 18 % faster |
| Tracker back after a 7-minute outage: all 650 torrents announced | none within 60 s | within 45 s | |

Trade-offs, where the patch is slower:

| | Before | After |
|---|---|---|
| Startup burst to a fast HTTP/1.1 tracker (the per-tracker limit starts at 4 connections and grows) | 3.7 s | 10.9 s |
| Tracker back after a 2-minute outage: all announced (probe back-off) | 15 s | 25 s |

### 0003: load SHA-1 piece hashes on demand
Piece hashes were 99 % of the metadata (792 of 803 MB) and stayed in memory for every torrent, although a seed
only reads them for a recheck, seed-mode piece verification or a metadata export. `torrent_info` can now keep
everything but the hashes in memory and load the info section back through a client callback, verified against
the info-hash, then free it again when idle. A torrent freed too early backs off (up to 16 times the idle time)
so busy torrents do not thrash. Released hashes are freed one release cycle later, so pointers handed to
other threads stay valid.

Time to load a torrent's hashes back from the qBittorrent database:

| | Typical (p50) | 99th percentile | Worst |
|---|---|---|---|
| Normal | 0.23 ms | 2.0 ms | 15 ms (5 MB of metadata) |
| Heavy concurrent database writes | | 2.5 ms | |

### 0004: no peer list for seeds that never connect out
With `seeding_outgoing_connections` off, a seeding torrent never connects to the peers trackers and resume
data hand out, and a private torrent has no DHT or PEX that would use them, so they are no longer kept (about
48 bytes each). Banned peers are kept, incoming peers are added as before, and the seed/leech counts still come
from the trackers' reported counts.

## qBittorrent

### 0001-0003: faster `sync/maindata` and `torrents/info`
Compile constant path regexes once, write the JSON directly instead of through `QJsonObject`, gzip large
responses at level 1. Responses are value-for-value identical to stock.

| Request (~7,800 torrents) | Before | After | Result |
|---|---|---|---|
| Opening the WebUI (`maindata`, new session) | 1,267 ms | 444 ms | 2.9× faster |
| Reloading the WebUI (`maindata`, same session) | 927 ms | 218 ms | 4.3× faster |
| `torrents/info?includeTrackers=true` | 1,598 ms | 708 ms | 2.3× faster |
| Memory after the runs | 1.9 GiB | 1.5 GiB | 21 % less |

### 0004-0013: WebUI virtual list (backport from 5.2)
Upstream's virtual list, cherry-picked with authors kept and on by default: the tables render only the rows in
view.

| ~7,800 torrents | Before | After | Result |
|---|---|---|---|
| Torrent table usable, Chromium | 7.4 s | 1.4 s | 5× faster |
| Torrent table usable, Firefox | 7.7 s | 1.7 s | 4.5× faster |
| Table rows in the page | ~7,800 | 56 | 99 % fewer |

### 0014: setting for outgoing connections of seeding torrents
Exposes libtorrent's `seeding_outgoing_connections`. On private trackers the peer lists are almost all seeds,
and a seed connecting out to another seed only produces a connection that gets closed as redundant: up to 50
outgoing connections per second, 89 % of them to seeds, starting over after every restart. Turned off,
complete torrents only accept incoming connections. The default stays stock (on).

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
bitfield is needed. Saves about 25 MB at 39.6 million pieces.

### 0019: piece hashes from the resume database
With the SQLite resume data storage, torrents start without their piece hashes in memory (libtorrent 0003);
they are read back from the database on demand (own read-only SQLite connection, WAL) and freed after an idle
time (default 15 minutes) when the torrent is not downloading, checking or moving.

Idle memory, ~8,900 torrents all seeding, 2 minutes after start:

| Build | Memory (RSS) |
|---|---|
| linuxserver 5.1.4, stock | 1,550 MB |
| patches 0001-0016 | 1,552 MB |
| patches 0001-0019 | **340 MB (4.6× less)** |
| all patches (0001-0022), mimalloc 3 as the allocator | 293 MB |

### 0020: WebUI session limits
Under the authentication bypass (localhost or a whitelisted subnet), every request without a session cookie
started a new WebUI session kept for the whole session timeout, and one that called `sync/maindata` held a
full snapshot (85-120 MB at ~8,000 torrents). A client polling without cookies could exhaust memory.

| | Before | After |
|---|---|---|
| New session without its cookie coming back | kept for the session timeout | dropped after 60 s |
| Sessions per client address | unlimited | 8 |
| Sessions in total | unlimited | 32 (unconfirmed ones evicted first) |

### 0021: free the torrent extension's initial data
qBittorrent's torrent extension collects a new torrent's full status (with its piece bitfields), trackers and
URL seeds for one constructor call, then kept it until the torrent was removed. It is now freed once read.

### 0022: pending tracker updates in a flat list
Tracker alerts queue per-torrent updates (trackers, endpoints, peer counts) until the tracker statuses are
refreshed. They were two levels of nested `QHash`es, each allocating 48 entries on first insert, about 3 KB per
waiting torrent: 29 MB while announces were failing. Now a flat list per torrent.

## Memory allocator
qBittorrent on Alpine uses musl's allocator (mallocng). Each candidate was preloaded with `LD_PRELOAD` into the
same image, ~8,900 torrents, three rounds against musl in the same run (rounds vary by about 10 %). Load = 10
full `sync/maindata` + 10 `torrents/info` with trackers, through one session.

| Allocator | Idle memory | Peak after start | Startup CPU | CPU under load | `torrents/info` | Heap hardening |
|---|---|---|---|---|---|---|
| musl (mallocng), stock | 335 MB | 340 MB | 37 s | 9.1 s | 710 ms | good |
| jemalloc 5.3 | ~360 MB | | ~28 s | ~5.7 s | ~450 ms | |
| mimalloc 2.2 | ~520 MB (keeps freed memory) | | ~27 s | ~5.1 s | ~410 ms | weak |
| mimalloc 3.5 | ~325 MB | ~610 MB | ~27 s | ~4.9 s | ~390 ms | weak |
| mimalloc 3.5 secure | ~345 MB | **~1.4 GB** | ~27 s | ~5.9-7.3 s | ~430-540 ms | good |
| **Scudo** (LLVM), shipped | **~300 MB** | ~310 MB | ~34 s | ~8.8 s | ~670 ms | **strongest** |

musl's row is measured (midpoints of its rounds); the others are computed from their measured difference to musl
and rounded. Blank: not measured (jemalloc's hardening was not assessed).

Heap hardening, from the sources (musl 1.2.5, mimalloc 3.5.0 with `MI_SECURE=ON`):

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
but gives up most heap hardening. The image ships **Scudo** (Alpine's signed `scudo-malloc` package,
`LD_PRELOAD`; `-e LD_PRELOAD=` turns it off). Rechecks cost the same CPU with it (1,206 MB hashed per
CPU-second, musl 1,135 MB, 8 hashing threads). A running qbittorrent-nox binds `malloc`/`free` in Qt and
libtorrent to Scudo, and the exporter reports the allocator in use (`qbittorrent_allocator_info`).

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
