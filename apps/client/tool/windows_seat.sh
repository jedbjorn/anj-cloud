#!/usr/bin/env bash
# host-side driver for the Windows seat W10C-Testing (spec #32 W0; decisions
# #117 and #120). Direct SSH with the host-held key is the standing exception
# to the VM broker (#120 Q3). This script only starts, ACPI-shuts down and
# screenshots the domain: it never snapshots, reverts or redefines it (#117).
#
#   windows_seat.sh preflight            seat free, machine.slice headroom, no anj-qual
#   windows_seat.sh start                start the shut-off VM, take the lease, wait for SSH
#   windows_seat.sh ssh <command...>     run a command on the guest
#   windows_seat.sh ps <script> [args]   copy a .ps1 into C:\anj\tools and run it
#   windows_seat.sh push                 send this checkout's apps/client (HEAD plus
#                                        the working tree's tracked changes) to
#                                        C:\anj\work\client
#   windows_seat.sh pull <guest-dir> <halo-dir>
#   windows_seat.sh screenshot <file.png>
#   windows_seat.sh forward-check        prove the reverse forward to a the VM host
#                                        service on the guest's 127.0.0.1
#   windows_seat.sh stop                 ACPI shutdown, wait for "shut off", drop the lease
#   windows_seat.sh stop --force-unleased [<qemu-start>]
#                                        recovery only: shut down a running seat that
#                                        has no valid lease (see below)
#   windows_seat.sh state | lease        domain state | the lease, if any
#
# Lease: the seat is shared with other projects and with every anj lane, all
# of which run as the same the VM host user (spec #32, Test Seat: "If W is already
# running and this shell did not start it, another project holds it: do not
# use it"). ANJ_WIN_OWNER must name the lane (its anj-test-<TAG> tag, e.g.
# w2); there is no default. `start` records the boot it started and its
# owner in $ANJ_WIN_LEASE_DIR: domain UUID, `virsh domid`, the qemu
# process's start time (/proc/<pid>/stat field 22) and the VM host boot id.
# domids repeat after a libvirtd restart; the qemu start time with the boot
# id does not. Every command that touches the guest, and `stop`, refuses
# unless the lease matches the running boot and the caller's owner. start
# and stop run under flock on $ANJ_WIN_LEASE_DIR/<domain>.lock, so neither
# can act on a state the other is changing.
#
# Recovery: a seat left running with no valid lease (a start killed before
# it wrote the lease, or a lease lost) is refused by everything above. Find
# out who runs it first: `stop --force-unleased` without a UUID prints the
# qemu process, any stale lease and the SSH sessions to the guest, and
# changes nothing. If it is yours, pass the qemu start it printed (it names
# this boot only): it refuses with a non-default ANJ_WIN_LEASE_DIR, a valid
# lease or an SSH session to the guest, then ACPI-shuts down. The owner tag
# is self-declared: never set ANJ_WIN_OWNER to another lane's tag.
#
# Run each call in its own scope (anj_test_seats):
#   systemd-run --user --scope --unit=anj-test-<TAG>-<n> -p MemoryMax=4G … windows_seat.sh …
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
client="$(dirname "$here")"

domain="${ANJ_WIN_DOMAIN:-W10C-Testing}"
host="${ANJ_WIN_HOST:-192.168.122.100}"
user="${ANJ_WIN_USER:-Public}"
key="${ANJ_WIN_KEY:-$HOME/.ssh/sc_win_test}"
# The host key pinned when the seat was set up (shared with other projects).
known="${ANJ_WIN_KNOWN_HOSTS:-$HOME/Repos/rst-c/.sc-state/local/vm/W10C-Testing.known_hosts}"
need_gib="${ANJ_WIN_NEED_GIB:-13}"
default_lease_dir="$HOME/.local/share/anj-cloud/state"
lease_dir="${ANJ_WIN_LEASE_DIR:-$default_lease_dir}"
lease="$lease_dir/$domain.lease"
lock="$lease_dir/$domain.lock"
owner="${ANJ_WIN_OWNER:-}"
# Test seam: tool/test_windows_seat.sh points this at a fake /proc.
proc_root="${ANJ_WIN_PROC_ROOT:-/proc}"
virsh=(virsh -c qemu:///system)
ssh_opts=(-i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$known" -o ConnectTimeout=10 -o ServerAliveInterval=15)

# Temporary state, removed on every exit: success, die(), a failing step
# under set -e, or a signal. Every cleanup step is non-fatal, because set -e
# also applies inside the trap (a killed server's `wait` returns 143).
server_pid=""
temp_paths=()
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [ "${#temp_paths[@]}" -gt 0 ]; then rm -rf -- "${temp_paths[@]}" || true; fi
}
trap cleanup EXIT
# A signal ends the script through exit, so the EXIT trap runs.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

die() { echo "windows_seat: $*" >&2; exit 1; }
state() { "${virsh[@]}" domstate "$domain" 2>/dev/null | head -1; }
guest() { ssh "${ssh_opts[@]}" "$user@$host" "$@"; }
boot_id() { cat "$proc_root/sys/kernel/random/boot_id"; }

require_owner() {
  [[ "$owner" =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "set ANJ_WIN_OWNER to your lane tag (the anj-test-<TAG> tag, e.g. w2); there is no default"
}

# Holds the lease lock on descriptor 9 until the script exits or unlock.
take_lock() {
  mkdir -p "$lease_dir"
  exec 9>>"$lock"
  flock -w "${ANJ_WIN_LOCK_WAIT:-360}" 9 || die "another start or stop holds $lock"
}
unlock() { exec 9>&-; }

# The current boot's identity, read in the calling shell (never inside a
# command substitution, where die() would end only the subshell and leave
# an empty field): sets boot_uuid, boot_domid, boot_qemu_start (the qemu
# process's start time in clock ticks since the VM host boot, /proc/<pid>/stat
# field 22) and boot_halo. Dies unless every field is present, with domid
# and qemu_start numeric.
read_boot() {
  boot_uuid="$("${virsh[@]}" domuuid "$domain" 2>/dev/null | head -1)" || true
  boot_domid="$("${virsh[@]}" domid "$domain" 2>/dev/null | head -1)" || true
  boot_halo="$(cat "$proc_root/sys/kernel/random/boot_id" 2>/dev/null)" || true
  local pids
  pids="$(pgrep -f -- "^[^ ]*qemu-system-[^ ]* -name guest=${domain}," || true)"
  [ "$(wc -w <<<"$pids")" = 1 ] || die "cannot identify the qemu process of $domain (found: ${pids:-none})"
  boot_pid="$pids"
  local stat=""
  stat="$(cat "$proc_root/$boot_pid/stat" 2>/dev/null)" || true
  # After the comm field the words start at field 3, so field 22 is word 20.
  boot_qemu_start="$(awk '{ print $20 }' <<<"${stat##*) }")"
  [ -n "$boot_uuid" ] && [ -n "$boot_halo" ] && [[ "$boot_domid" =~ ^[0-9]+$ ]] &&
    [[ "$boot_qemu_start" =~ ^[0-9]+$ ]] ||
    die "cannot read the boot identity of $domain (uuid '$boot_uuid', domid '$boot_domid', qemu start '$boot_qemu_start', the VM host boot '$boot_halo')"
}

# One field of the lease (key=value lines; never sourced).
lease_field() { sed -n "s/^$1=//p" "$lease" 2>/dev/null | head -1; }

# Whether the lease describes the boot running now (any owner). An empty
# field never matches.
lease_matches_boot() {
  [ -f "$lease" ] || return 1
  read_boot
  local key want have
  for key in uuid domid qemu_start halo_boot; do
    have="$(lease_field "$key")"
    case "$key" in
      uuid) want="$boot_uuid" ;; domid) want="$boot_domid" ;;
      qemu_start) want="$boot_qemu_start" ;; halo_boot) want="$boot_halo" ;;
    esac
    [ -n "$have" ] && [ "$have" = "$want" ] || return 1
  done
}

# The running domain is the boot this lane started.
require_lease() {
  require_owner
  [ -f "$lease" ] || die "no lease for $domain ($lease): this session did not start it, do not use it"
  local st; st="$(state)"
  [ "$st" = "running" ] || die "$domain is '$st', not running"
  lease_matches_boot ||
    die "$domain is not the boot this lease started (lease owner $(lease_field owner), domid $(lease_field domid)): another session holds it, do not use it"
  [ "$(lease_field owner)" = "$owner" ] ||
    die "$domain is held by $(lease_field owner), not $owner: do not use it, and never set ANJ_WIN_OWNER to another lane's tag"
}

preflight() {
  [ -r "$known" ] || die "pinned host key file missing: $known"
  [ -r "$key" ] || die "seat key missing: $key"
  local st; st="$(state)"
  [ "$st" = "shut off" ] || die "$domain is '$st': another session holds it, do not use it"
  # Captured first: under pipefail, grep -q exiting early can SIGPIPE virsh
  # and read as "not running".
  local names; names="$("${virsh[@]}" list --name)"
  if grep -qx 'anj-qual' <<<"$names"; then
    die "an anj-qual run is active: wait for it, never stop it"
  fi
  local max cur free
  max=$(systemctl show machine.slice -p MemoryMax --value)
  cur=$(systemctl show machine.slice -p MemoryCurrent --value)
  [[ "$max" =~ ^[0-9]+$ && "$cur" =~ ^[0-9]+$ ]] || die "cannot read machine.slice memory ($max, $cur)"
  free=$(( (max - cur) / 1073741824 ))
  [ "$free" -ge "$need_gib" ] || die "machine.slice has ${free} GiB free, need ${need_gib}"
  echo "preflight ok: $domain shut off, no anj-qual, machine.slice ${free} GiB free"
}

start() {
  require_owner
  take_lock
  preflight
  # Fails if another session started the domain since preflight: no lease.
  "${virsh[@]}" start "$domain" >/dev/null
  # Dies (leaving the D4 recovery path) unless the identity is complete.
  read_boot
  local tmp
  tmp="$(mktemp "$lease_dir/.lease.XXXXXX")"; temp_paths+=("$tmp")
  printf 'domain=%s\nuuid=%s\ndomid=%s\nqemu_start=%s\nhalo_boot=%s\nowner=%s\nstarted=%s\n' \
    "$domain" "$boot_uuid" "$boot_domid" "$boot_qemu_start" "$boot_halo" "$owner" "$(date -Is)" >"$tmp"
  mv -f "$tmp" "$lease"
  unlock
  echo "started $domain (domid $boot_domid, owner $owner, lease $lease); waiting for SSH"
  local i
  for i in $(seq 1 60); do
    if guest 'echo ready' >/dev/null 2>&1; then echo "ssh ready after ~$((i * 5))s"; return 0; fi
    sleep 5
  done
  die "SSH did not come up within 300s (the VM is left running under this lease: call stop)"
}

ps_run() {
  local script="$1"; shift
  [ -f "$script" ] || die "no such script: $script"
  local name; name="$(basename "$script")"
  guest 'if not exist C:\anj\tools mkdir C:\anj\tools' >/dev/null
  scp -q "${ssh_opts[@]}" "$script" "$user@$host:C:/anj/tools/$name"
  guest "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\anj\\tools\\$name $*"
}

push() {
  local dir; dir="$(mktemp -d)"; temp_paths+=("$dir")
  # Tracked files only, as they are in the working tree.
  (cd "$client" && git ls-files -z --cached -- . | tar --null -T - -cf "$dir/client.tar")
  guest 'if not exist C:\anj\downloads mkdir C:\anj\downloads' >/dev/null
  scp -q "${ssh_opts[@]}" "$dir/client.tar" "$user@$host:C:/anj/downloads/client.tar"
  ps_run "$here/windows/unpack.ps1"
  echo "pushed $(cd "$client" && git rev-parse HEAD)$(cd "$client" && git diff --quiet HEAD -- . || echo ' plus working-tree changes')"
}

pull() {
  local from="$1" to="$2"
  mkdir -p "$to"
  scp -q -r "${ssh_opts[@]}" "$user@$host:${from//\\//}/*" "$to/"
  echo "pulled $from -> $to"
}

screenshot() {
  local out="$1" tmp; tmp="$(mktemp --suffix=.ppm)"; temp_paths+=("$tmp")
  "${virsh[@]}" screenshot "$domain" "$tmp" >/dev/null
  magick "$tmp" "$out"
  echo "screenshot $out"
}

# R reached from the guest: an SSH reverse forward binds the guest's
# 127.0.0.1 so a dev certificate naming 127.0.0.1 verifies (spec #32, Test
# Seat). Proven here with a throwaway the VM host HTTP server and a random token.
forward_check() {
  local port="${1:-18443}" dir token
  dir="$(mktemp -d)"; temp_paths+=("$dir")
  token="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  printf '%s' "$token" >"$dir/token.txt"
  python3 -u -m http.server --bind 127.0.0.1 --directory "$dir" 0 >"$dir/server.log" 2>&1 &
  server_pid=$!
  local hport="" i
  for i in $(seq 1 50); do
    hport=$(sed -n 's/.*port \([0-9]*\).*/\1/p' "$dir/server.log" | head -1)
    [ -n "$hport" ] && break; sleep 0.1
  done
  [ -n "$hport" ] || die "test server did not start"
  local got
  got=$(ssh "${ssh_opts[@]}" -o ExitOnForwardFailure=yes -R "127.0.0.1:$port:127.0.0.1:$hport" "$user@$host" \
    "powershell -NoProfile -Command \"(Invoke-WebRequest -UseBasicParsing http://127.0.0.1:$port/token.txt).Content\"" | tr -d '\r\n')
  [ "$got" = "$token" ] || die "reverse forward check failed (got '$got')"
  echo "reverse forward ok: guest 127.0.0.1:$port -> the VM host 127.0.0.1:$hport, token matched"
}

stop() {
  [ "${1:-}" = --force-unleased ] && { shift; force_unleased "$@"; return; }
  require_owner
  # Held through the state read, the shutdown and the lease removal, so a
  # start cannot slip in between (it waits for the lock).
  take_lock
  local st; st="$(state)"
  if [ "$st" = "shut off" ]; then
    if [ -f "$lease" ] && [ "$(lease_field owner)" = "$owner" ]; then rm -f "$lease"; fi
    echo "$domain already shut off"; return 0
  fi
  # Never shut down a session this lane did not start.
  require_lease
  "${virsh[@]}" shutdown "$domain" --mode acpi >/dev/null
  wait_shut_off
  rm -f "$lease"
}

wait_shut_off() {
  local i st
  for i in $(seq 1 60); do
    st="$(state)"
    if [ "$st" = "shut off" ]; then echo "$domain: shut off"; return 0; fi
    sleep "${ANJ_WIN_POLL:-5}"
  done
  die "$domain is still '$st' after 300s; ACPI shutdown again, never force it off"
}

# Recovery for a running seat with no valid lease. Prints who appears to
# run it; acts only when confirmed with this boot's qemu start time (which no
# other boot has), with the default lease dir, no valid lease and no SSH
# session to the guest.
force_unleased() {
  local want="${1:-}"
  require_owner
  [ "$lease_dir" = "$default_lease_dir" ] ||
    die "--force-unleased needs the default lease dir ($default_lease_dir), not $lease_dir: other lanes' leases live there"
  take_lock
  local st; st="$(state)"
  [ "$st" = "running" ] || die "$domain is '$st', not running: nothing to recover"
  read_boot
  echo "$domain is running: uuid $boot_uuid, domid $boot_domid, qemu start $boot_qemu_start"
  echo "qemu: $(ps -o pid=,user=,lstart=,etime= -p "$boot_pid" 2>/dev/null || echo "pid $boot_pid")"
  if [ -f "$lease" ]; then echo "lease on file:"; sed 's/^/  /' "$lease"; else echo "lease on file: none"; fi
  local sessions
  sessions="$(pgrep -af -- "^ssh .*${user}@${host}( |\$)" || true)"
  echo "SSH sessions to $user@$host from the VM host: ${sessions:-none}"
  [ -n "$want" ] || die "nothing changed; if this boot is yours, rerun: stop --force-unleased $boot_qemu_start"
  [ "$want" = "$boot_qemu_start" ] ||
    die "$want is not this boot's qemu start ($boot_qemu_start): the seat may have restarted; run the dry run again"
  if lease_matches_boot; then
    die "the lease is valid for this boot (owner $(lease_field owner)): not unleased; ask that lane to stop it"
  fi
  [ -z "$sessions" ] || die "a session is using the guest right now: not shutting it down"
  echo "ACPI shutdown of unleased $domain (qemu start $boot_qemu_start) requested by $owner"
  "${virsh[@]}" shutdown "$domain" --mode acpi >/dev/null
  wait_shut_off
  rm -f "$lease"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  preflight) preflight ;;
  start) start ;;
  ssh) require_lease; guest "$@" ;;
  ps) require_lease; ps_run "$@" ;;
  push) require_lease; push ;;
  pull) require_lease; pull "$@" ;;
  screenshot) require_lease; screenshot "$@" ;;
  forward-check) require_lease; forward_check "$@" ;;
  stop) stop "$@" ;;
  state) state ;;
  lease) if [ -f "$lease" ]; then cat "$lease"; else echo "no lease ($lease)"; fi ;;
  *) sed -n '2,47p' "$0"; exit 2 ;;
esac
