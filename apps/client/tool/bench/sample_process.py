#!/usr/bin/env python3
"""Passive, read-only /proc sampler for a running anj_cloud client.

Samples one PID (all threads) every --interval seconds for --duration seconds
and writes a CSV of cumulative counters plus a JSON summary of rates. It only
reads /proc and `ss -tinp` output for sockets owned by the same user; it never
signals, attaches to, or interacts with the target.

Usage:
  python3 tool/bench/sample_process.py --pid PID --duration 600 --interval 1 \
      --out-dir DIR [--remote-port 8834]
"""
import argparse, csv, json, os, re, subprocess, sys, time

CLK = os.sysconf("SC_CLK_TCK")
PAGE = os.sysconf("SC_PAGE_SIZE")


def read(path):
    with open(path) as f:
        return f.read()


def stat_fields(text):
    # comm may contain spaces/parens; split after the last ')'.
    rest = text[text.rfind(")") + 2:].split()
    # rest[0] is field 3 (state); utime=14, stime=15 -> rest[11], rest[12]
    return {"utime": int(rest[11]), "stime": int(rest[12]),
            "num_threads": int(rest[17]), "rss_pages": int(rest[21])}


def kv(text):
    out = {}
    for line in text.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            out[k.strip()] = v.strip()
    return out


def kb(v):
    return int(v.split()[0])


def socket_bytes(pid, port):
    """Sum bytes_sent/bytes_received over TCP sockets of pid to :port."""
    try:
        out = subprocess.run(["ss", "-tinpH", "state", "established"],
                             capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return None
    sent = recv = n = 0
    lines = out.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        info = lines[i + 1] if i + 1 < len(lines) and lines[i + 1].startswith(("\t", " ")) else ""
        if info:
            i += 1
        i += 1
        if f"pid={pid}," not in line or f":{port}" not in line:
            continue
        n += 1
        m = re.search(r"bytes_sent:(\d+)", info)
        sent += int(m.group(1)) if m else 0
        m = re.search(r"bytes_received:(\d+)", info)
        recv += int(m.group(1)) if m else 0
    return {"sockets": n, "bytes_sent": sent, "bytes_received": recv}


# Context switches per thread, last seen. Summing only live threads makes the
# total drop when a thread exits; keeping each thread's last value keeps the
# series monotonic. Switches a thread makes after its last sample are missed,
# so totals are lower bounds when threads exit between samples.
_ctxt_seen = {}


def sample(pid, port):
    base = f"/proc/{pid}"
    t = time.time()
    st = stat_fields(read(f"{base}/stat"))
    status = kv(read(f"{base}/status"))
    io = kv(read(f"{base}/io"))
    roll = kv(read(f"{base}/smaps_rollup"))
    threads = 0
    for tid in os.listdir(f"{base}/task"):
        try:
            ts = kv(read(f"{base}/task/{tid}/status"))
            a, b, c = read(f"{base}/task/{tid}/schedstat").split()
            _ctxt_seen[tid] = (int(ts["voluntary_ctxt_switches"]),
                               int(ts["nonvoluntary_ctxt_switches"]),
                               int(a), int(b), int(c))
            threads += 1
        except (FileNotFoundError, ProcessLookupError, KeyError, ValueError):
            pass  # thread exited between listdir and read
    vol = sum(v[0] for v in _ctxt_seen.values())
    invol = sum(v[1] for v in _ctxt_seen.values())
    run_ns = sum(v[2] for v in _ctxt_seen.values())
    wait_ns = sum(v[3] for v in _ctxt_seen.values())
    slices = sum(v[4] for v in _ctxt_seen.values())
    row = {
        "t": round(t, 3),
        "utime_ticks": st["utime"], "stime_ticks": st["stime"],
        "threads": threads,
        "rss_kb": kb(status["VmRSS"]), "hwm_kb": kb(status["VmHWM"]),
        "pss_kb": kb(roll["Pss"]),
        "pss_anon_kb": kb(roll.get("Pss_Anon", "0 kB")),
        "rchar": int(io["rchar"]), "wchar": int(io["wchar"]),
        "syscr": int(io["syscr"]), "syscw": int(io["syscw"]),
        "read_bytes": int(io["read_bytes"]), "write_bytes": int(io["write_bytes"]),
        "vol_ctxt": vol, "invol_ctxt": invol,
        "sched_run_ns": run_ns, "sched_wait_ns": wait_ns, "sched_slices": slices,
    }
    if port:
        sb = socket_bytes(pid, port)
        if sb:
            row.update({"tcp_sockets": sb["sockets"],
                        "tcp_bytes_sent": sb["bytes_sent"],
                        "tcp_bytes_received": sb["bytes_received"]})
    return row


def pct(xs, p):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * p
    lo = int(k); hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def summarize(rows):
    first, last = rows[0], rows[-1]
    dt = last["t"] - first["t"]
    d = lambda k: last[k] - first[k]
    cpu_s = (d("utime_ticks") + d("stime_ticks")) / CLK
    per = []
    for a, b in zip(rows, rows[1:]):
        w = b["t"] - a["t"]
        if w <= 0:
            continue
        per.append({
            "cpu_pct": 100 * ((b["utime_ticks"] - a["utime_ticks"]) + (b["stime_ticks"] - a["stime_ticks"])) / CLK / w,
            "sched_cpu_pct": 100 * (b["sched_run_ns"] - a["sched_run_ns"]) / 1e9 / w,
            "wakeups_per_s": ((b["vol_ctxt"] - a["vol_ctxt"]) + (b["invol_ctxt"] - a["invol_ctxt"])) / w,
            "rchar_per_s": (b["rchar"] - a["rchar"]) / w,
        })
    s = {
        "samples": len(rows), "duration_s": round(dt, 1),
        "cpu_pct_mean": round(100 * cpu_s / dt, 3),
        "cpu_user_pct_mean": round(100 * d("utime_ticks") / CLK / dt, 3),
        "cpu_sys_pct_mean": round(100 * d("stime_ticks") / CLK / dt, 3),
        "sched_cpu_pct_mean": round(100 * d("sched_run_ns") / 1e9 / dt, 3),
        "sched_cpu_pct_p50": round(pct([p["sched_cpu_pct"] for p in per], .5), 3),
        "sched_cpu_pct_p95": round(pct([p["sched_cpu_pct"] for p in per], .95), 3),
        "sched_cpu_pct_max": round(max(p["sched_cpu_pct"] for p in per), 3),
        "rss_kb_min": min(r["rss_kb"] for r in rows), "rss_kb_max": max(r["rss_kb"] for r in rows),
        "rss_kb_last": last["rss_kb"],
        "pss_kb_min": min(r["pss_kb"] for r in rows), "pss_kb_max": max(r["pss_kb"] for r in rows),
        "hwm_kb": last["hwm_kb"],
        "threads_min": min(r["threads"] for r in rows), "threads_max": max(r["threads"] for r in rows),
        "rchar_per_s": round(d("rchar") / dt), "wchar_per_s": round(d("wchar") / dt),
        "syscr_per_s": round(d("syscr") / dt, 2), "syscw_per_s": round(d("syscw") / dt, 2),
        "read_bytes_per_s": round(d("read_bytes") / dt), "write_bytes_per_s": round(d("write_bytes") / dt),
        "vol_ctxt_per_s": round(d("vol_ctxt") / dt, 2), "invol_ctxt_per_s": round(d("invol_ctxt") / dt, 2),
        "sched_slices_per_s": round(d("sched_slices") / dt, 2),
        "wakeups_per_s_p95": round(pct([p["wakeups_per_s"] for p in per], .95), 1),
    }
    if "tcp_bytes_sent" in last:
        s.update({
            "tcp_sockets_last": last["tcp_sockets"],
            "tcp_sent_per_s": round(d("tcp_bytes_sent") / dt),
            "tcp_received_per_s": round(d("tcp_bytes_received") / dt),
            "tcp_note": "cumulative bytes on the sockets present at both ends; reconnects reset counters",
        })
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pid", type=int, required=True)
    ap.add_argument("--duration", type=float, default=600)
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--remote-port", type=int, default=0)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--label", default="installed_idle")
    a = ap.parse_args()
    os.makedirs(a.out_dir, exist_ok=True)
    rows = []
    end = time.time() + a.duration
    nxt = time.time()
    while time.time() < end:
        try:
            rows.append(sample(a.pid, a.remote_port))
        except (FileNotFoundError, ProcessLookupError):
            print("target exited", file=sys.stderr)
            break
        nxt += a.interval
        time.sleep(max(0, nxt - time.time()))
    csv_path = os.path.join(a.out_dir, f"{a.label}_samples.csv")
    if not rows:
        print("no samples", file=sys.stderr)
    with open(csv_path, "w", newline="") as f:
        keys = sorted({k for r in rows for k in r}, key=lambda k: list(rows[-1]).index(k) if k in rows[-1] else 99)
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader(); w.writerows(rows)
    if len(rows) < 2:
        s = {"samples": len(rows), "error": "fewer than two samples"}
    else:
        s = summarize(rows)
    s.update({"pid": a.pid, "interval_s": a.interval, "clk_tck": CLK,
              "ctxt_method": "per-thread last-seen accumulation (monotonic; "
                             "lower bound if threads exit between samples)"})
    with open(os.path.join(a.out_dir, f"{a.label}_summary.json"), "w") as f:
        json.dump(s, f, indent=2)
    print(json.dumps(s, indent=2))


if __name__ == "__main__":
    main()
