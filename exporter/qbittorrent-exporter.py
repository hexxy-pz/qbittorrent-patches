#!/usr/bin/env python3
"""qbittorrent-exporter - torrent statistics for node-exporter's textfile collector.

Runs inside the qBittorrent container as the s6 service svc-qbittorrent-exporter.
Once a minute it makes ONE bulk call (POST /api/v2/torrents/info, includeTrackers=true)
to the WebUI on localhost, sums the torrents by state, category and first tracker
host, and atomically rewrites $QBT_EXPORTER_FILE in the Prometheus text format.

The container lives on a network Prometheus cannot reach, so nothing listens here:
the file lands in the /config bind mount and node-exporter reads it from the host.
Requests come from localhost, so this needs WebUI\\LocalHostAuth=false ("Bypass
authentication for clients on localhost"); no credentials are stored.

CPU, memory and disk I/O of the container come from cAdvisor, not from here.

It also reports which allocator qbittorrent-nox runs with (qbittorrent_allocator_info), read from the
process's memory map: the image preloads Scudo, and an environment that overrides LD_PRELOAD would
silently fall back to musl's allocator.

Environment:
  QBT_EXPORTER_FILE      output file (required; the s6 run script only starts us when set)
  QBT_EXPORTER_INTERVAL  seconds between collections, aligned to the clock (default 60)
  QBT_EXPORTER_URL       WebUI base URL (default http://localhost:$WEBUI_PORT, port 8080)
  QBT_EXPORTER_TIMEOUT   HTTP timeout in seconds (default 30)

Usage: qbittorrent-exporter [--once] [--stdout]
  --once    collect a single time and exit
  --stdout  print the metrics instead of writing QBT_EXPORTER_FILE
"""
import argparse
import json
import os
import signal
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict

SEED_STATES = ("uploading", "stalledUP", "forcedUP")

# name -> (help, label names); every value is a sum over torrents
TORRENT_METRICS = {
    "qbittorrent_torrents_status": ("Number of torrents", ("status", "category", "tracker")),
    "qbittorrent_torrents_upload": ("Upload speed of torrents in bytes/s", ("category", "tracker")),
    "qbittorrent_torrents_download": ("Download speed of torrents in bytes/s", ("category", "tracker")),
    "qbittorrent_torrents_size": ("Size of seeding torrents in bytes", ("category", "tracker")),
    "qbittorrent_torrents_peers": ("Connected peers (status=leech|seed)", ("status", "category", "tracker")),
    "qbittorrent_torrents_data_uploaded": ("Data uploaded by torrents in bytes", ("category", "tracker")),
}


def log(msg):
    print(f"qbittorrent-exporter: {msg}", flush=True)


def fetch_torrents(base_url, timeout):
    body = urllib.parse.urlencode({"includeTrackers": "true"}).encode()
    req = urllib.request.Request(f"{base_url}/api/v2/torrents/info", data=body, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def first_tracker_host(torrent):
    """Host[:port] of the first real tracker URL ('** [DHT] **' etc. have no '//')."""
    for t in torrent.get("trackers") or ():
        url = t.get("url") or ""
        if "//" in url:
            return url.split("/")[2]
    return "none"


def aggregate(torrents):
    sums = {name: defaultdict(float) for name in TORRENT_METRICS}
    for t in torrents:
        category = t.get("category") or "uncategorized"
        tracker = first_tracker_host(t)
        state = t.get("state") or "unknown"
        ct = (category, tracker)
        sums["qbittorrent_torrents_status"][(state,) + ct] += 1
        sums["qbittorrent_torrents_upload"][ct] += t.get("upspeed") or 0
        sums["qbittorrent_torrents_download"][ct] += t.get("dlspeed") or 0
        if state in SEED_STATES:
            sums["qbittorrent_torrents_size"][ct] += t.get("size") or 0
        sums["qbittorrent_torrents_peers"][("leech",) + ct] += t.get("num_leechs") or 0
        sums["qbittorrent_torrents_peers"][("seed",) + ct] += t.get("num_seeds") or 0
        sums["qbittorrent_torrents_data_uploaded"][ct] += t.get("uploaded") or 0
    return sums


# shared libraries that replace the allocator when loaded (LD_PRELOAD); none of them: musl's own
ALLOCATOR_LIBS = (("/libscudo.so", "scudo"), ("/libmimalloc", "mimalloc"), ("/libjemalloc", "jemalloc"),
                  ("/libtcmalloc", "tcmalloc"))


def qbt_allocator():
    """Allocator of the running qbittorrent-nox, from /proc/<pid>/maps (same user, so readable);
    "unknown" if the process is not found or its map cannot be read."""
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/comm") as fh:
                if fh.read().strip() != "qbittorrent-nox":
                    continue
            with open(f"/proc/{pid}/maps") as fh:
                maps = fh.read()
        except OSError:
            continue
        for marker, name in ALLOCATOR_LIBS:
            if marker in maps:
                return name
        return "musl"
    return "unknown"


def escape(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def fmt(value):
    return repr(float(value)) if value != int(value) else str(int(value))


def render(sums, up, duration, last_success, count, allocator):
    out = [
        "# HELP qbittorrent_allocator_info Allocator qbittorrent-nox runs with (scudo, musl, mimalloc, ...; unknown: not found)",
        "# TYPE qbittorrent_allocator_info gauge",
        f'qbittorrent_allocator_info{{allocator="{escape(allocator)}"}} 1',
    ]
    for name, (help_text, label_names) in TORRENT_METRICS.items():
        out.append(f"# HELP {name} {help_text}")
        out.append(f"# TYPE {name} gauge")
        for labels, value in sorted(sums.get(name, {}).items()):
            lbl = ",".join(f'{k}="{escape(v)}"' for k, v in zip(label_names, labels))
            out.append(f"{name}{{{lbl}}} {fmt(value)}")
    for name, help_text, value in (
        ("qbittorrent_exporter_up", "1 if the last collection succeeded", up),
        ("qbittorrent_exporter_torrents", "Torrents seen by the last successful collection", count),
        ("qbittorrent_exporter_duration_seconds", "Duration of the last collection", duration),
        ("qbittorrent_exporter_last_success_timestamp_seconds", "Unix time of the last successful collection", last_success),
    ):
        out.append(f"# HELP {name} {help_text}")
        out.append(f"# TYPE {name} gauge")
        out.append(f"{name} {fmt(value)}")
    return "\n".join(out) + "\n"


def write_atomic(path, text):
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".qbittorrent-exporter.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--once", action="store_true", help="collect a single time and exit")
    ap.add_argument("--stdout", action="store_true", help="print metrics instead of writing the file")
    args = ap.parse_args()

    path = os.environ.get("QBT_EXPORTER_FILE", "")
    if not path and not args.stdout:
        sys.exit("qbittorrent-exporter: QBT_EXPORTER_FILE is not set")
    interval = int(os.environ.get("QBT_EXPORTER_INTERVAL", "60"))
    timeout = float(os.environ.get("QBT_EXPORTER_TIMEOUT", "30"))
    base_url = os.environ.get("QBT_EXPORTER_URL") or f"http://localhost:{os.environ.get('WEBUI_PORT') or 8080}"
    base_url = base_url.rstrip("/")

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    if not args.once:
        log(f"writing {path} every {interval}s from {base_url}")

    last_success, count, sums, failing = 0, 0, {}, False
    while True:
        start = time.time()
        try:
            torrents = fetch_torrents(base_url, timeout)
            sums, count, up = aggregate(torrents), len(torrents), 1
            last_success = time.time()
            if failing:
                log(f"recovered, {count} torrents")
            failing = False
        except urllib.error.HTTPError as e:
            up = 0
            hint = " (localhost auth bypass off? set WebUI\\LocalHostAuth=false)" if e.code in (401, 403) else ""
            if not failing:
                log(f"WebUI answered HTTP {e.code}{hint}")
            failing = True
        except (urllib.error.URLError, OSError, ValueError) as e:
            up = 0
            if not failing:
                log(f"collection failed: {e}")
            failing = True
        # On failure keep the last good sums: a WebUI hiccup should not zero the dashboards;
        # qbittorrent_exporter_up and _last_success_timestamp_seconds show it is stale.
        text = render(sums, up, time.time() - start, last_success, count, qbt_allocator())
        if args.stdout:
            sys.stdout.write(text)
        else:
            write_atomic(path, text)
        if args.once:
            return 0 if up else 1
        time.sleep(interval - (time.time() % interval))


if __name__ == "__main__":
    sys.exit(main())
