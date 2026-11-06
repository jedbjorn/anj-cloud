#!/usr/bin/env python3
"""Collect sync_bench_*.json and installed-app sampler output into summary.json.

Usage: python3 tool/bench/summarize.py EVIDENCE_DIR
Writes EVIDENCE_DIR/summary.json and prints a Markdown table.

Before/after comparisons should use the per-pass columns (pass CPU seconds,
pass rchar, pass rows written: from the last online tick, which calls the
real SyncEngine.tick) and the per-state columns of offline_worker_idle (the
unmodified syncWorker). CPU % and per-second rates saturate for any busy pass
and cannot express a per-pass reduction. online_idle and emit() are replicas
of worker.dart at b35f858 and do not follow later scheduling/emit changes.
"""
import glob, json, os, platform, subprocess, sys


def load(path):
    with open(path) as f:
        return json.load(f)


def sh(*cmd, cwd=None):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10, cwd=cwd)
        return r.stdout.strip() if r.returncode == 0 else None
    except Exception:
        return None


def environment(evidence):
    cpu = None
    with open("/proc/cpuinfo") as f:
        for line in f:
            if line.startswith("model name"):
                cpu = line.split(":", 1)[1].strip()
                break
    gov = None
    try:
        with open("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor") as f:
            gov = f.read().strip()
    except OSError:
        pass
    with open("/proc/meminfo") as f:
        mem = f.readline().split(":", 1)[1].strip()
    return {
        "cpu_model": cpu,
        "logical_cpus": os.cpu_count(),
        "governor": gov,
        "kernel": platform.release(),
        "mem_total": mem,
        "evidence_fs": sh("findmnt", "-n", "-T", evidence, "-o", "FSTYPE,OPTIONS"),
    }


def per_pass(t, key, extrapolated_key):
    """(value, kind): exact for a completed pass; for a budget-cut pass the
    extrapolated value when available, else the measured lower bound."""
    if not t:
        return None, None
    if t.get("completed"):
        return t.get(key), "measured"
    if extrapolated_key in t:
        return t[extrapolated_key], "extrapolated"
    return t.get(key), "lower_bound"


def bench_row(r):
    n = r["files"]
    comp = r["components"]
    ticks = r.get("online_ticks", [])
    t = ticks[-1] if ticks else {}
    idle = r.get("online_idle", {})
    off = r.get("offline_worker_idle", {})
    cpu_s = t.get("cpu_s")
    if cpu_s is None and "utime_ms" in t:  # runs before rusage CPU was added
        cpu_s = (t["utime_ms"] + t["stime_ms"]) / 1000
    if t.get("completed"):
        pass_s, pass_kind = t.get("wall_s"), "measured"
    elif "per_path_s" in t:
        # One manifest rewrite per file path (directories skip it), plus one
        # after the local pass: scan + per-path cost x (files + 1).
        pass_s, pass_kind = t["local_scan_s"] + t["per_path_s"] * (n + 1), "extrapolated"
    else:
        pass_s, pass_kind = t.get("wall_s"), "lower_bound" if t else None
    if t.get("completed"):
        pass_cpu, cpu_kind = cpu_s, "measured"
    elif "extrapolated_cpu_s" in t:
        pass_cpu, cpu_kind = t["extrapolated_cpu_s"], "extrapolated"
    else:
        pass_cpu, cpu_kind = cpu_s, "lower_bound" if t else None
    pass_rchar, rchar_kind = per_pass(t, "rchar", "extrapolated_rchar")
    pass_rows, rows_kind = per_pass(t, "rows_written", "extrapolated_rows_written")
    states = off.get("states") or 0
    off_cpu_s = off.get("cpu_s")
    if off_cpu_s is None and "utime_ms" in off:
        off_cpu_s = (off["utime_ms"] + off["stime_ms"]) / 1000
    return {
        "files": n,
        "source": r.get("source"),
        "work_filesystem": r.get("work_filesystem"),
        "entries": r["seed"]["entries"],
        "total_bytes": r["fixture"]["total_bytes"],
        "scan_hash_warm_s": comp["local_scan_hash_warm"]["wall_s"],
        "scan_hash_cold_s": comp["local_scan_hash_cold"]["wall_s"],
        "scan_hash_cold_read_bytes": comp["local_scan_hash_cold"]["read_bytes"],
        "manifest_save_ms": round(comp["manifest_save_ms_each"], 2),
        "emit_ms": comp["emit"]["emit_ms"],
        "propfind_requests_per_cycle": comp["remote_propfind_requests_per_cycle"],
        "online_ticks_run": len(ticks),
        "online_pass_completed": t.get("completed"),
        "online_pass_s": round(pass_s, 3) if pass_s is not None else None,
        "online_pass_s_kind": pass_kind,
        "online_pass_measured_s": t.get("wall_s"),
        "online_pass_cpu_s": round(pass_cpu, 3) if pass_cpu is not None else None,
        "online_pass_cpu_s_kind": cpu_kind,
        "online_pass_cpu_s_measured": cpu_s,
        "online_pass_rchar": pass_rchar,
        "online_pass_rchar_kind": rchar_kind,
        "online_pass_rows_written": pass_rows,
        "online_pass_rows_written_kind": rows_kind,
        "online_pass_saves": t.get("manifest_saves"),
        "online_pass_budget_throws": t.get("budget_throws"),
        "online_pass_cpu_pct": round(t["cpu_pct"], 1) if "cpu_pct" in t else None,
        "online_pass_write_bytes_per_s": t.get("write_bytes_per_s"),
        "online_pass_ctxt_per_s": t.get("ctxt_per_s"),
        "online_pass_peak_rss_kb": t.get("peak_rss_kb"),
        "online_ticks_cpu_s": [x.get("cpu_s") for x in ticks],
        "online_ticks_wall_s": [x.get("wall_s") for x in ticks],
        "online_idle_replica_cpu_pct": round(idle["cpu_pct"], 2) if "cpu_pct" in idle else None,
        "online_idle_replica_write_bytes_per_s": idle.get("write_bytes_per_s"),
        "online_idle_replica_cycles": idle.get("cycles"),
        "online_idle_replica_probe_latency": idle.get("probe_latency"),
        "online_idle_skipped": idle.get("skipped"),
        "offline_worker_cpu_pct": round(off["cpu_pct"], 2) if "cpu_pct" in off else None,
        "offline_worker_cpu_s_per_state": round(off_cpu_s / states, 4) if off_cpu_s is not None and states else None,
        "offline_worker_rchar_per_state": round(off["rchar"] / states) if states and "rchar" in off else None,
        "offline_worker_write_bytes_per_s": off.get("write_bytes_per_s"),
        "offline_worker_rchar_per_s": off.get("rchar_per_s"),
        "offline_worker_ctxt_per_s": off.get("ctxt_per_s"),
        "offline_worker_peak_rss_kb": off.get("peak_rss_kb"),
        "offline_worker_states": off.get("states"),
        "offline_state_interval_s": off.get("state_interval_s"),
        "baseline_rss_kb": r["baseline_process"]["rss_kb"],
        "fixture_digest_sha256": r["seed"]["fixture_digest_sha256"],
        "fixture_removed": r.get("fixture_removed", False),
    }


def main():
    evidence = sys.argv[1]
    rows = []
    for path in sorted(glob.glob(f"{evidence}/bench/sync_bench_*.json"),
                       key=lambda p: int(p.rsplit("_", 1)[1].split(".")[0])):
        r = load(path)
        if "components" in r:
            rows.append(bench_row(r))
    externals = {}
    for path in glob.glob(f"{evidence}/bench/bench_process_*_summary.json"):
        externals[path.rsplit("bench_process_", 1)[1].split("_")[0]] = load(path)
    installed = None
    p = f"{evidence}/installed/installed_idle_summary.json"
    if os.path.exists(p):
        installed = load(p)
    recorded = {json.dumps(r["source"], sort_keys=True) for r in rows if r["source"]}
    here = os.path.dirname(os.path.abspath(__file__))
    source = {
        "recorded_by_runs": [json.loads(s) for s in sorted(recorded)],
        "consistent": len(recorded) <= 1,
        "runs_without_source": [r["files"] for r in rows if not r["source"]],
        "summarizer_checkout": {
            "head": sh("git", "rev-parse", "HEAD", cwd=here),
            "dirty": bool(sh("git", "status", "--porcelain=v1", cwd=here)),
        },
    }
    if not source["consistent"]:
        print("WARNING: runs recorded different source heads/dirty states", file=sys.stderr)
    work_fs = sorted({r["work_filesystem"] for r in rows if r["work_filesystem"]})
    if any(fs in ("tmpfs", "ramfs") for fs in work_fs):
        print("WARNING: --work on tmpfs; read/write bytes are not disk I/O", file=sys.stderr)
    summary = {
        "source": source,
        "work_filesystems": work_fs,
        "environment": environment(evidence),
        "installed_idle": installed,
        "bench": rows,
        "bench_external_process_samples": externals,
    }
    with open(f"{evidence}/summary.json", "w") as f:
        json.dump(summary, f, indent=2)

    def fmt(value, kind, scale=1.0, digits=2):
        if value is None:
            return "-"
        mark = {"extrapolated": " (extrap.)", "lower_bound": " (>=)"}.get(kind, "")
        return f"{value / scale:.{digits}f}{mark}"

    print("| N files | bytes | pass s | pass CPU s | pass rchar MiB | pass rows written | saves | "
          "offline CPU s/state | offline rchar MiB/state | offline period s |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        gaps = (r["offline_state_interval_s"] or [])[:-1]
        period = sum(gaps) / len(gaps) if gaps else None
        print(f"| {r['files']} | {r['total_bytes'] / 2**20:.0f} MiB | "
              f"{fmt(r['online_pass_s'], r['online_pass_s_kind'])} | "
              f"{fmt(r['online_pass_cpu_s'], r['online_pass_cpu_s_kind'])} | "
              f"{fmt(r['online_pass_rchar'], r['online_pass_rchar_kind'], 2**20, 1)} | "
              f"{fmt(r['online_pass_rows_written'], r['online_pass_rows_written_kind'], 1, 0)} | "
              f"{r['online_pass_saves']} | "
              f"{fmt(r['offline_worker_cpu_s_per_state'], 'measured', 1, 3)} | "
              f"{fmt(r['offline_worker_rchar_per_state'], 'measured', 2**20, 1)} | "
              f"{fmt(period, 'measured')} |")


if __name__ == "__main__":
    main()
