#!/usr/bin/env bash
# Tests tool/windows_seat.sh without a VM (spec #32 W0; PR #52 reviews M1,
# M2, L3 and D1-D4). Fakes for virsh, ssh, scp, magick, systemctl and the
# qemu side of pgrep go first on PATH, and /proc is a fake directory. The
# guest is a TEST-NET address with a test user, so real SSH sessions to the
# real seat (other projects use it) never match. The fake
# ssh serves a reverse forward by fetching its -R target directly.
# Covers: cleanup on success, failure and signals; the lease (owner required
# and checked, boot identity including the qemu start time, flock between
# start and stop) and the unleased recovery path.
set -euo pipefail
seat="$(cd "$(dirname "$0")" && pwd)/windows_seat.sh"
work="$(mktemp -d)"
sleepers=()
trap 'kill "${sleepers[@]}" 2>/dev/null || true; pkill -f "http.server --bind 127.0.0.1 --directory $work" 2>/dev/null || true; rm -rf "$work"' EXIT
fake="$work/bin"; mkdir -p "$fake" "$work/tmp" "$work/home" "$work/proc/sys/kernel/random"
export FAKE="$work/fake"; mkdir -p "$FAKE"
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# virsh: state in $FAKE. A start bumps the domid (or reuses $FAKE/reuse_domid)
# and writes a new qemu start time into the fake /proc. FAKE_SLOW delays
# domstate after reading it, opening the start/stop window the D3 race needs.
cat >"$fake/virsh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -c ] && shift 2
tag="${FAKE_TAG:-}"
echo "$tag $*" >>"$FAKE/virsh.log"
st() { cat "$FAKE/state"; }
case "$1" in
  domstate) s="$(st)"; [ -n "${FAKE_SLOW:-}" ] && sleep "$FAKE_SLOW"; echo "$s"; echo "$tag domstate-done" >>"$FAKE/virsh.log" ;;
  domid) [ "$(st)" = running ] && cat "$FAKE/domid" || echo - ;;
  domuuid) echo 11111111-2222-3333-4444-555555555555 ;;
  list) [ -f "$FAKE/qual" ] && echo anj-qual; echo "$(cat "$FAKE/others" 2>/dev/null)" ;;
  start) [ "$(st)" = "shut off" ] || { echo "error: already active" >&2; exit 1; }
         echo running >"$FAKE/state"
         if [ -f "$FAKE/reuse_domid" ]; then cat "$FAKE/reuse_domid" >"$FAKE/domid"
         else echo $(( $(cat "$FAKE/domid") + 1 )) >"$FAKE/domid"; fi
         n=$(( $(cat "$FAKE/qemu_start" 2>/dev/null || echo 1000) + 7 )); echo "$n" >"$FAKE/qemu_start"
         mkdir -p "$FAKE_PROC/4242"
         printf '4242 (qemu-system x) S %s%s 23 24\n' "$(seq -s ' ' 4 21) " "$n" >"$FAKE_PROC/4242/stat" ;;
  shutdown) echo "shut off" >"$FAKE/state" ;;
  screenshot) [ -f "$FAKE/shot_fail" ] && { echo "error: screenshot" >&2; exit 1; }
              printf 'P6\n1 1\n255\n\0\0\0' >"$3" ;;
  *) echo "fake virsh: $*" >&2; exit 1 ;;
esac
EOF
cat >"$fake/ssh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/ssh.log"
[ -f "$FAKE/ssh_sleep" ] && sleep 30
[ -f "$FAKE/ssh_fail" ] && { echo "ssh: connect: No route to host" >&2; exit 255; }
fwd=""; while [ $# -gt 0 ]; do [ "$1" = -R ] && fwd="$2"; shift; done
if [ -n "$fwd" ]; then
  target="${fwd#*:*:}"   # 127.0.0.1:<guest>:127.0.0.1:<halo> -> 127.0.0.1:<halo>
  python3 -c 'import sys, urllib.request; sys.stdout.write(urllib.request.urlopen("http://" + sys.argv[1] + "/token.txt").read().decode())' "$target"
else
  echo ready
fi
EOF
# pgrep: the qemu lookup answers from the fake state; everything else is real.
cat >"$fake/pgrep" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *qemu-system*) [ -f "$FAKE/no_qemu" ] && exit 1; [ "$(cat "$FAKE/state")" = running ] && echo 4242 || exit 1 ;;
  *) exec /usr/bin/pgrep "$@" ;;
esac
EOF
printf '#!/usr/bin/env bash\necho "$*" >>"$FAKE/scp.log"\n' >"$fake/scp"
printf '#!/usr/bin/env bash\n[ -f "$FAKE/magick_fail" ] && exit 1\ncp "$1" "$2"\n' >"$fake/magick"
cat >"$fake/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *MemoryMax*) echo 25190940672 ;;
  *MemoryCurrent*) echo 4294967296 ;;
  *) exec /usr/bin/systemctl "$@" ;;
esac
EOF
chmod +x "$fake"/*
touch "$work/key" "$work/known"
export PATH="$fake:$PATH" TMPDIR="$work/tmp" ANJ_WIN_KEY="$work/key" ANJ_WIN_KNOWN_HOSTS="$work/known" \
  HOME="$work/home" ANJ_WIN_PROC_ROOT="$work/proc" FAKE_PROC="$work/proc" \
  ANJ_WIN_OWNER=laneA ANJ_WIN_POLL=0.1 \
  ANJ_WIN_USER=anj-seat-test ANJ_WIN_HOST=198.51.100.77
# A guest address and user no real session can use (198.51.100.0/24 is
# TEST-NET-2), so the live-session check (real pgrep) sees only this test's
# own fake sessions, never another project's SSH to the real seat.
# The default lease dir, under the fake HOME (recovery requires the default).
unset ANJ_WIN_LEASE_DIR
lease="$work/home/.local/share/anj-cloud/state/W10C-Testing.lease"
uuid=11111111-2222-3333-4444-555555555555
reset() {
  rm -f "$FAKE"/*; echo "shut off" >"$FAKE/state"; echo 7 >"$FAKE/domid"; rm -f "$lease"
  echo aaaa-boot >"$work/proc/sys/kernel/random/boot_id"
}
leftovers() { find "$work/tmp" -mindepth 1 | wc -l; }
servers() { pgrep -f "http.server --bind 127.0.0.1 --directory $work" | wc -l; }
run() { set +e; out="$("$seat" "$@" 2>&1)"; code=$?; set -e; }
as() { local o="$1"; shift; set +e; out="$(ANJ_WIN_OWNER="$o" "$seat" "$@" 2>&1)"; code=$?; set -e; }
shutdowns() { grep -c ' shutdown' "$FAKE/virsh.log" 2>/dev/null || true; }
guest_cmds=("ssh dir" "ps $seat" push "pull a b" "screenshot $work/shot.png" forward-check)

# Lease: start records the boot it started, with its owner and qemu start time.
reset; run start
[ "$code" = 0 ] && [ "$(sed -n 's/^domid=//p' "$lease")" = 8 ] && [ "$(sed -n 's/^owner=//p' "$lease")" = laneA ] &&
  [ "$(sed -n 's/^qemu_start=//p' "$lease")" = 1007 ] && ok "start writes a lease: domid 8, owner laneA, qemu start 1007" || bad "start: $code $out"
for c in "${guest_cmds[@]}"; do
  # shellcheck disable=SC2086
  run $c; [ "$code" = 0 ] && ok "$c accepted under its own lease" || bad "$c with lease: $code $out"
done
[ "$(leftovers)" = 0 ] && [ "$(servers)" = 0 ] && ok "success paths leave no temp file or server" || bad "leftovers after success: $(leftovers) files, $(servers) servers"

# M1: forward-check cleans up on failure and signals.
touch "$FAKE/ssh_fail"; run forward-check; rm -f "$FAKE/ssh_fail"
[ "$code" != 0 ] && [ "$(leftovers)" = 0 ] && [ "$(servers)" = 0 ] && ok "forward-check failure ($code) cleans up" || bad "forward-check failure: $code, $(leftovers) files, $(servers) servers"
for sig in TERM INT HUP; do
  touch "$FAKE/ssh_sleep"
  # Job control: the job gets its own process group, and SIGINT is not
  # ignored in it (a non-interactive shell ignores SIGINT in async jobs).
  set -m; "$seat" forward-check >/dev/null 2>&1 & pid=$!; set +m
  for _ in $(seq 1 50); do [ "$(servers)" = 1 ] && [ -s "$FAKE/ssh.log" ] && break; sleep 0.1; done
  sleep 0.3; kill -"$sig" -- "-$pid"; set +e; wait "$pid"; code=$?; set -e
  rm -f "$FAKE/ssh_sleep" "$FAKE/ssh.log"
  [ "$code" != 0 ] && [ "$(leftovers)" = 0 ] && [ "$(servers)" = 0 ] && ok "forward-check SIG$sig ($code) cleans up" || bad "SIG$sig: $code, $(leftovers) files, $(servers) servers"
done

# L3: screenshot cleans up its .ppm when virsh or magick fails.
for f in shot_fail magick_fail; do
  touch "$FAKE/$f"; run screenshot "$work/shot.png"; rm -f "$FAKE/$f"
  [ "$code" != 0 ] && [ "$(leftovers)" = 0 ] && ok "screenshot with $f ($code) leaves no .ppm" || bad "screenshot $f: $code, $(leftovers) files"
done

# D1: another lane on the same the VM host user is refused, including stop.
before="$(shutdowns)"
for c in "${guest_cmds[@]}" stop; do
  # shellcheck disable=SC2086
  as laneB $c; [ "$code" != 0 ] && [[ "$out" == *"held by laneA, not laneB"* ]] && [[ "$out" == *"never set ANJ_WIN_OWNER to another lane's tag"* ]] && ok "laneB: $c refuses laneA's boot" || bad "laneB $c: $code $out"
done
[ "$(shutdowns)" = "$before" ] && [ -f "$lease" ] && ok "laneB's stop sent no shutdown and kept laneA's lease" || bad "laneB shut down laneA's boot"
run ssh dir; [ "$code" = 0 ] && ok "laneA still drives its boot" || bad "laneA after laneB: $code $out"

# D1: the owner is required, with no default.
starts="$(grep -c ' start ' "$FAKE/virsh.log" || true)"
for c in start "ssh dir" stop; do
  # shellcheck disable=SC2086
  set +e; out="$(env -u ANJ_WIN_OWNER "$seat" $c 2>&1)"; code=$?; set -e
  [ "$code" != 0 ] && [[ "$out" == *"set ANJ_WIN_OWNER"* ]] && ok "$c refuses without ANJ_WIN_OWNER" || bad "$c without owner: $code $out"
done
[ "$(shutdowns)" = "$before" ] && [ "$(grep -c ' start ' "$FAKE/virsh.log" || true)" = "$starts" ] && ok "no start or shutdown without an owner" || bad "acted without an owner"

# M2: another boot (a different domid, the VM host boot id or qemu start) is refused.
echo 42 >"$FAKE/domid"
for c in "${guest_cmds[@]}" stop; do
  # shellcheck disable=SC2086
  run $c; [ "$code" != 0 ] && [[ "$out" == *"another session holds it"* ]] && ok "$c refuses another domid" || bad "$c on another domid: $code $out"
done
echo 8 >"$FAKE/domid"; echo bbbb-boot >"$work/proc/sys/kernel/random/boot_id"; run stop
[ "$code" != 0 ] && [[ "$out" == *"another session holds it"* ]] && ok "stop refuses another the VM host boot id" || bad "boot id: $code $out"
echo aaaa-boot >"$work/proc/sys/kernel/random/boot_id"
[ "$(shutdowns)" = "$before" ] && ok "no shutdown of another boot" || bad "shut down another boot"

# X1: the boot identity fails closed. An empty lease field never matches, and
# an unidentifiable qemu process refuses instead of comparing empty values.
cp "$lease" "$work/lease.bak"; sed -i 's/^qemu_start=.*/qemu_start=/' "$lease"
run ssh dir; [ "$code" != 0 ] && [[ "$out" == *"another session holds it"* ]] && ok "an empty lease field is a mismatch" || bad "empty field: $code $out"
cp "$work/lease.bak" "$lease"; touch "$FAKE/no_qemu"; run stop; rm -f "$FAKE/no_qemu"
[ "$code" != 0 ] && [[ "$out" == *"cannot identify the qemu process"* ]] && [ "$(shutdowns)" = "$before" ] && ok "stop refuses when qemu cannot be identified" || bad "no qemu stop: $code $out"

# D2: a stale lease meets a later boot with the same domid (libvirtd restart):
# the qemu start time differs, so it is refused.
echo "shut off" >"$FAKE/state"; echo 8 >"$FAKE/reuse_domid"
FAKE_TAG=other virsh start W10C-Testing   # another project, outside this script
run stop
[ "$code" != 0 ] && [[ "$out" == *"another session holds it"* ]] && [ "$(shutdowns)" = "$before" ] &&
  ok "a reused domid with a new qemu start is refused, no shutdown" || bad "domid reuse: $code $out"

# M2: running with no lease (another project started it) is refused.
rm -f "$lease"
for c in "ssh dir" stop; do
  # shellcheck disable=SC2086
  run $c; [ "$code" != 0 ] && [[ "$out" == *"did not start it"* ]] && ok "$c refuses without a lease" || bad "$c without lease: $code $out"
done
run preflight; [ "$code" != 0 ] && ok "preflight refuses a running seat" || bad "preflight on running seat"

# D4/X2: recovery of an unleased running seat, confirmed by this boot's
# qemu start time (never the constant domain UUID), default lease dir only.
qs="$(cat "$FAKE/qemu_start")"
run stop --force-unleased
[ "$code" != 0 ] && [[ "$out" == *"qemu start $qs"* ]] && [[ "$out" == *"qemu:"* ]] && [[ "$out" == *"rerun: stop --force-unleased $qs"* ]] &&
  [ "$(shutdowns)" = "$before" ] && ok "force-unleased without a token reports and changes nothing" || bad "force no token: $code $out"
for wrong in 00000 "$uuid"; do
  run stop --force-unleased "$wrong"
  [ "$code" != 0 ] && [[ "$out" == *"is not this boot's qemu start"* ]] && [ "$(shutdowns)" = "$before" ] && ok "force-unleased refuses token $wrong" || bad "force token $wrong: $code $out"
done
set +e; out="$(ANJ_WIN_LEASE_DIR="$work/other" "$seat" stop --force-unleased "$qs" 2>&1)"; code=$?; set -e
[ "$code" != 0 ] && [[ "$out" == *"needs the default lease dir"* ]] && [ "$(shutdowns)" = "$before" ] && ok "force-unleased refuses a non-default lease dir" || bad "force other dir: $code $out"
bash -c 'exec -a "ssh -i k anj-seat-test@198.51.100.77" sleep 30' & sleepers+=($!); sleep 0.2
run stop --force-unleased "$qs"
kill "${sleepers[-1]}" 2>/dev/null || true
[ "$code" != 0 ] && [[ "$out" == *"session is using the guest"* ]] && [ "$(shutdowns)" = "$before" ] && ok "force-unleased refuses while an SSH session is open" || bad "force with session: $code $out"
# The reviewer's X2 case: laneA holds the boot in the default dir; laneB,
# idle-looking and with another lease dir, cannot shut it down.
reset; as laneA start; qs="$(cat "$FAKE/qemu_start")"
set +e; out="$(ANJ_WIN_OWNER=laneB ANJ_WIN_LEASE_DIR="$work/other" "$seat" stop --force-unleased "$qs" 2>&1)"; code=$?; set -e
[ "$code" != 0 ] && [ "$(shutdowns)" = 0 ] && ok "laneB with another lease dir cannot force laneA's boot" || bad "X2 probe: $code $out"
as laneB stop --force-unleased "$qs"
[ "$code" != 0 ] && [[ "$out" == *"lease is valid for this boot (owner laneA)"* ]] && [ "$(shutdowns)" = 0 ] && ok "force-unleased refuses a validly leased boot" || bad "force on leased: $code $out"
rm -f "$lease"; as laneB stop --force-unleased "$qs"
[ "$code" = 0 ] && [ "$(shutdowns)" = 1 ] && [ "$(cat "$FAKE/state")" = "shut off" ] && ok "force-unleased with the qemu start shuts down an unleased boot" || bad "force: $code $out"
run stop --force-unleased "$qs"; [ "$code" != 0 ] && [[ "$out" == *"nothing to recover"* ]] && ok "force-unleased on a shut-off seat does nothing" || bad "force shut off: $code $out"

# X1: start fails when the identity cannot be read, and writes no lease
# (the seat is left to the recovery path).
reset; touch "$FAKE/no_qemu"; run start; rm -f "$FAKE/no_qemu"
[ "$code" != 0 ] && [ ! -f "$lease" ] && [[ "$out" == *"cannot identify the qemu process"* ]] && ok "start fails closed without a qemu identity, no lease" || bad "X1 start: $code $out $(cat "$lease" 2>/dev/null)"

# D3: stop and start are serialized. laneA's stop reads "shut off" slowly;
# laneB's start waits for the lock, so its start comes after that read and
# its lease survives.
reset; as laneA start; as laneA stop; echo "shut off" >"$FAKE/state"
cp /dev/null "$FAKE/virsh.log"
(FAKE_TAG=A FAKE_SLOW=1.5 ANJ_WIN_OWNER=laneA "$seat" stop >"$work/a.out" 2>&1; echo $? >"$work/a.code") &
a=$!; sleep 0.4
set +e; out="$(FAKE_TAG=B ANJ_WIN_OWNER=laneB "$seat" start 2>&1)"; code=$?; set -e; wait "$a"
order="$(grep -E '^A domstate-done|^B start' "$FAKE/virsh.log" | cut -d' ' -f1,2 | tr '\n' ',')"
[ "$code" = 0 ] && [ "$(cat "$work/a.code")" = 0 ] && [ "$order" = "A domstate-done,B start," ] &&
  [ "$(sed -n 's/^owner=//p' "$lease")" = laneB ] && ok "start waits for a running stop; the new lease survives" || bad "race: $code, a=$(cat "$work/a.code"), order=$order, $(cat "$lease" 2>/dev/null | tr '\n' ' ')"
as laneB stop; [ "$code" = 0 ] && [ ! -f "$lease" ] && ok "laneB stops its own boot after the race" || bad "laneB stop after race: $code $out"

# Own lease: stop shuts down and drops it; a shut-off seat keeps another
# lane's stale lease and drops the caller's own.
reset; run start; run stop
[ "$code" = 0 ] && [ "$(shutdowns)" = 1 ] && [ ! -f "$lease" ] && ok "stop shuts down its own boot and drops the lease" || bad "own stop: $code $out"
as laneB start; echo "shut off" >"$FAKE/state"; run stop
[ "$code" = 0 ] && [ -f "$lease" ] && ok "stop on a shut-off seat keeps another lane's lease" || bad "kept other lease: $code $out"
as laneB stop; [ "$code" = 0 ] && [ ! -f "$lease" ] && ok "stop on a shut-off seat drops its own stale lease" || bad "own stale lease: $code $out"
touch "$FAKE/qual"; run start; rm -f "$FAKE/qual"
[ "$code" != 0 ] && [ ! -f "$lease" ] && ok "start refuses during an anj-qual run, no lease" || bad "anj-qual: $code $out"

echo "windows_seat tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
