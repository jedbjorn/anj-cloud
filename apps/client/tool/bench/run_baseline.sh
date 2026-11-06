#!/usr/bin/env bash
# Serial Feature #14 resource baseline over synthetic roots (default 1k/10k/50k).
# Usage: tool/bench/run_baseline.sh EVIDENCE_DIR [file-count ...]
# One benchmark at a time (no concurrent SDK/native-asset jobs); each benchmark
# VM is also sampled externally by sample_process.py.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${FLUTTER_SDK:=$HOME/.local/share/anj-cloud/toolchains/flutter-3.47.9}"
export FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
evidence=${1:?evidence directory}
shift
sizes=("$@")
[[ ${#sizes[@]} -eq 0 ]] && sizes=(1000 10000 50000)
./tool/build_rootfs.sh
export ANJ_ROOTFS_LIBRARY="$PWD/.dart_tool/libanj_rootfs.so"
mkdir -p "$evidence/bench"
for n in "${sizes[@]}"; do
  "$FLUTTER_SDK/bin/dart" run tool/bench/sync_bench.dart \
    --files "$n" --work "$evidence/bench/work" \
    --out "$evidence/bench/sync_bench_$n.json" \
    --online-ticks "${ONLINE_TICKS:-3}" \
    --tick-budget-seconds "${TICK_BUDGET_SECONDS:-600}" \
    --idle-seconds "${IDLE_SECONDS:-120}" \
    --offline-seconds "${OFFLINE_SECONDS:-120}" \
    --probes "${PROBES:-3}" 2>"$evidence/bench/sync_bench_$n.log" &
  runner=$!
  bench=""
  for _ in $(seq 1 300); do
    # The VM process that loaded the script (dart run may exec or fork it).
    bench=$(pgrep -n -f "sync_bench.dart --files $n " || true)
    [[ -n $bench ]] && grep -q "fixture" "$evidence/bench/sync_bench_$n.log" 2>/dev/null && break
    sleep 1
  done
  if [[ -n $bench ]]; then
    python3 tool/bench/sample_process.py --pid "$bench" --duration 1000000 \
      --interval 1 --out-dir "$evidence/bench" --label "bench_process_$n" \
      >/dev/null 2>&1 &
    sampler=$!
  fi
  wait "$runner"
  [[ -n ${sampler:-} ]] && { wait "$sampler" || true; unset sampler; }
done
