#!/usr/bin/env bash
# halo-vm.sh: the anj-cloud production VM on the VM host (spec #21 the VM host Host Script; decisions #84,
# #89, #90, #91, #92, #49). Reviewed, idempotent, dry-runnable; the VM host changes are operator-run with sudo.
#
#   sudo deploy/host/halo-vm.sh [--dry-run]                     read-only plan + evidence (default)
#   sudo deploy/host/halo-vm.sh --apply [--only <step>]          steps 1-8 (qual-firewall only via --only)
#   sudo deploy/host/halo-vm.sh --verify [--only <step>]
#   sudo deploy/host/halo-vm.sh --rollback <step>
#   sudo deploy/host/halo-vm.sh --recreate --confirm anj-prod    replace anj-prod (domain and both disks)
#   sudo deploy/host/halo-vm.sh --recreate-os                    rebuild vda only, keep the data disk
#   sudo deploy/host/halo-vm.sh --forward on|off                 off = emergency stop of the 443 forward
#        deploy/host/halo-vm.sh --qual [--run-id ID] [--share-readonly | --scratch-share DIR]  (DIR: anjvm.py scratch-share create)
#        deploy/host/halo-vm.sh --qual-destroy [--run-id ID | --force]   both agent-runnable, no sudo
#        deploy/host/halo-vm.sh --dry-run|--verify                             agent subset, read-only
# Options: --key FILE (SSH public key for user anj; repeatable), --image FILE, --host NAME,
#          --net-mode nat|open, --evidence-dir DIR.
#
# Steps: 1 preflight, 2 network, 3 domain, 4 backup-share, 5 forward, 6 start-stop, 7 hosts,
# 8 host-checks, 9 qual-firewall (ufw rules for the anj-qual bridge; only with --only).
# Backup share (decision #115): owned by the system account anj-cloud-backup, mode 0700; the VM's
# anj (1000) reaches it through the virtiofsd-anj-cloud wrapper's uid mapping. A --scratch-share: owned
# by one of your subuids (deploy/host/anjvm.py scratch-share create DIR) or by anj-cloud-backup.
#
# Never: ufw enable/reload/reset/disable; any change to sshd, virbr0, the default network, other
# domains, libvirt daemon or libvirt-guests settings, system Docker, halo-host-memory or the
# machine.slice/user.slice drop-ins; formatting a disk. Every created file is named *anj-cloud*
# (or is the backup mount unit) and listed in /etc/anj-cloud-host/manifest; the one in-place edit
# is a marked /etc/hosts line. Evidence holds digests and states only, never keys or the topic.
set -euo pipefail
shopt -s nullglob
umask 022

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$HERE/../.." && pwd -P)"
readonly HERE REPO

# Test harness only: ANJ_HOST_ROOT prefixes every filesystem path and ANJ_HOST_STUBS must provide
# every external command; both or neither (guard_test_mode).
readonly R="${ANJ_HOST_ROOT:-}"

# Household values come from the deployment profile (deploy/deployment_profile.py; ANJ_PROFILE, then
# the invoking user's ~/.local/share/anj-cloud/profile.toml, then deploy/.local/profile.toml).
# Without a profile the placeholders of deploy/profile.example.toml apply; only --dry-run and
# --verify run on placeholders (see the check after argument parsing).
PROFILE_FILE=""
for candidate in "${ANJ_PROFILE:-}" \
        "$(getent passwd "${SUDO_USER:-}" 2>/dev/null | cut -d: -f6)/.local/share/anj-cloud/profile.toml" \
        "${HOME:-}/.local/share/anj-cloud/profile.toml" "$HERE/../.local/profile.toml"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then PROFILE_FILE="$candidate"; break; fi
done
profile_value() {  # dotted.key placeholder-default
    local value=""
    if [[ -n "$PROFILE_FILE" ]]; then
        value="$(python3 -I - "$PROFILE_FILE" "$1" <<'PY' 2>/dev/null || true
import sys, tomllib
node = tomllib.load(open(sys.argv[1], "rb"))
for part in sys.argv[2].split("."):
    node = node[part]
print(node)
PY
)"
    fi
    printf '%s' "${value:-$2}"
}
REQUIRED_HOST="$(profile_value host.name vm-host)"
readonly MIN_LIBVIRT="12.8.0"
IFACE="$(profile_value host.interface eth0)"
LAN_ADDR="$(profile_value network.lan_addr 192.168.0.10)"
ROUTER="$(profile_value network.router 192.168.0.1)"
BACKUP_UUID="$(profile_value host.backup_uuid 00000000-0000-4000-8000-000000000000)"
readonly REQUIRED_HOST IFACE LAN_ADDR ROUTER BACKUP_UUID
readonly MOUNT_POINT="/mnt/anj-backup"
readonly SHARE_DIR="/mnt/anj-backup/anj-cloud-prod"
readonly MOUNT_UNIT='mnt-anj\x2dbackup.mount'
readonly SHARE_ACCOUNT="anj-cloud-backup"
readonly SYSUSERS_FILE="/etc/sysusers.d/anj-cloud-backup.conf"
readonly GUEST_ID=1000
readonly PROD="anj-prod"
readonly QUAL="anj-qual"
readonly THREADS="14 15 30 31"
readonly PROD_HEADROOM=$((4608 * 1024 * 1024))   # 4.5 GiB beyond running domains
readonly QUAL_HEADROOM=$((5120 * 1024 * 1024))   # 5 GiB (#89 (6))
readonly HOSTS_MARK="# anj-cloud"
readonly VM_COMMENT="anj-cloud-vm"
readonly QUAL_COMMENT="anj-cloud-qual"

readonly CONF_DIR="/etc/anj-cloud-host"
readonly MANIFEST="$CONF_DIR/manifest"
readonly HOST_CONFIG="$CONF_DIR/anj-cloud-host.json"
readonly NFT_FILE="$CONF_DIR/anj-cloud-fwd.nft"
readonly TOPIC_FILE="$CONF_DIR/ntfy-topic"
readonly FORWARD_OFF="$CONF_DIR/forward-off"
readonly LIB_DIR="/usr/local/lib/anj-cloud-host"
readonly VAR_DIR="/var/lib/anj-cloud-host"
readonly OTHERS_BASELINE="$VAR_DIR/anj-cloud-others-before.txt"
readonly UNIT_DIR="/etc/systemd/system"
readonly PACMAN_HOOK="/etc/pacman.d/hooks/zz-anj-cloud-host-check.hook"
readonly SUDOERS_ALERT="/etc/sudoers.d/anj-cloud-host-alert"
readonly ROUTINES=(anj-alert anjvm.py host-check vm-start virtiofsd-anj-cloud)
readonly WRAPPER="$LIB_DIR/virtiofsd-anj-cloud"

readonly STEP_NAMES=(_ preflight network domain backup-share forward start-stop hosts host-checks qual-firewall)

MODE="dry-run"
ONLY=""
ROLLBACK_STEP=""
CONFIRM=""
FORWARD_STATE=""
EVIDENCE_PARENT=""
NET_MODE=""
PROD_HOSTNAME="$(profile_value gateway.host gateway.example.com)"
IMAGE=""
KEYS=()
QUAL_SHARE=""
QUAL_SHARE_RO=0
RUN_ID=""
FORCE=0
AGENT=0
FAKE_ROOT=0
USER_NAME=""
USER_UID=""
USER_HOME=""
EVID=""
WORK=""
FAILED=0
STOPPED=""
COMPLETED=()
WANT_CHANGED=0
CURRENT_STEP=1
ABORTING=0
APPLY_STARTED=0
RECREATE_BUILDING=0
IMAGE_TMP=""
IMAGE_COPY=""
MODE_COUNT=0
SHARE_NOTE=""

# ---------------------------------------------------------------------------------------------
# Basics

p() { printf '%s%s' "$R" "$1"; }
log() { printf '%s\n' "$*"; [[ -n "$EVID" ]] && printf '%s\n' "$*" >> "$EVID/run.log"; return 0; }
die() { log "halo-vm: ERROR: $*"; exit 2; }
is_apply() { [[ "$MODE" =~ ^(apply|rollback|recreate|recreate-os|forward|qual|qual-destroy)$ ]]; }
is_root() { (( EUID == 0 || FAKE_ROOT )); }
sha() { sha256sum | cut -d' ' -f1; }
# has PATTERN CMD...: CMD's output matches PATTERN. Captures first: `cmd | grep -q` under pipefail
# reports a false "no match" when grep exits early and the command dies of SIGPIPE.
has() { local out; out="$("${@:2}" 2>/dev/null)" || true; grep -q -- "$1" <<<"$out"; }
hasF() { local out; out="$("${@:2}" 2>/dev/null)" || true; grep -qF -- "$1" <<<"$out"; }
V() { LC_ALL=C virsh -q -c qemu:///system "$@"; }
anjvm() { python3 -I "$HERE/anjvm.py" "$@"; }

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

step_number() {
    local wanted="$1" i
    if [[ "$wanted" =~ ^[0-9]+$ ]] && (( wanted >= 1 && wanted <= 9 )); then printf '%s' "$wanted"; return 0; fi
    for i in "${!STEP_NAMES[@]}"; do
        if (( i >= 1 )) && [[ "${STEP_NAMES[$i]}" == "$wanted" ]]; then printf '%s' "$i"; return 0; fi
    done
    return 1
}

# record step status before after detail; status: compliant | changed | planned | pass | fail |
# skipped | refused | rolled-back | info
record() {
    local step="$1" status="$2" before="${3:-}" after="${4:-}" detail="${5:-}"
    before="${before//$'\n'/ }"; after="${after//$'\n'/ }"; detail="${detail//$'\n'/ }"
    [[ -n "$EVID" ]] || return 0
    printf '%s\t%s\t%s\t%s\t%s\n' "$step" "$status" "${before//$'\t'/ }" "${after//$'\t'/ }" \
        "${detail//$'\t'/ }" | tr -d '\r' >> "$EVID/steps.tsv"
    case "$status" in fail|refused) FAILED=1 ;; esac
    log "  [$step ${STEP_NAMES[$step]}] $status${detail:+: $detail}"
}

read_raw() {
    local name="$1"; shift
    local out
    out="$("$@" 2>&1)" || true
    [[ -n "$EVID" ]] && printf '%s\n' "$out" > "$EVID/raw/$name.txt"
    printf '%s' "$out"
}

# The only way a mutating command runs. In --dry-run and --verify it only prints. In a changing
# mode a failed command fails the current step and ends the run with exit 1 (abort): set -e is
# not relied on, because bash turns it off inside `if !` and `||` contexts, where steps run.
# A caller that tolerates a failure (rollback, best-effort cleanup) uses change_try instead.
change() {
    if ! is_apply; then log "    would run: $*"; return 0; fi
    log "    run: $*"
    "$@" && return 0
    abort "command failed: $*"
}

change_try() {
    if ! is_apply; then log "    would run: $*"; return 0; fi
    log "    run (failure tolerated): $*"
    "$@" && return 0
    log "    (failed; tolerated)"
    return 1
}

# abort reason: record a fail line for the current step, stop the run, exit 1.
abort() {
    (( ABORTING )) && exit 1
    ABORTING=1
    trap '' INT TERM HUP   # the restore below must not be cut short
    record "$CURRENT_STEP" fail "" "" "$1"
    STOPPED="${STOPPED:-$CURRENT_STEP}"
    log "STOPPED at step $STOPPED: $1; completed: ${COMPLETED[*]:-none}"
    if (( ${#RESTORE_RULES[@]} )); then
        restore_rules
        local problems
        problems="$(ufw_order_problems)"
        if [[ -n "$problems" ]]; then
            log "!!! UNSAFE UFW ORDER after restore: $(tr '\n' ';' <<<"$problems") Fix by hand before anything else."
            record "$CURRENT_STEP" fail "" "" "UNSAFE UFW ORDER after restore: $(tr '\n' ';' <<<"$problems")"
        fi
    fi
    if [[ "$MODE" == recreate ]] && (( RECREATE_BUILDING )); then recreate_cleanup; fi
    if (( APPLY_STARTED )); then apply_end || true; fi
    exit 1
}

ask() {
    local answer source="/dev/tty"
    [[ -n "$R" && -n "${ANJ_HOST_TTY:-}" ]] && source="$ANJ_HOST_TTY"
    printf '%s [yes/no] ' "$1" > /dev/stderr
    if [[ "$source" == "/dev/tty" ]]; then read -r answer < /dev/tty || answer=""
    else answer="$(head -n1 "$source")"; sed -i '1d' "$source"; fi
    log "    asked: $1 -> ${answer:-<none>}"
    [[ "$answer" == "yes" ]]
}

json_get() {
    python3 -I -c '
import json, sys
try:
    data = json.load(sys.stdin if sys.argv[1] == "-" else open(sys.argv[1]))
except (OSError, ValueError):
    data = {}
for part in sys.argv[2].split("."):
    data = data.get(part) if isinstance(data, dict) else None
print("" if data is None else (" ".join(map(str, data)) if isinstance(data, list) else data))
' "$1" "$2" 2>/dev/null || true
}

group_exists() { if [[ -n "$R" ]]; then grep -q "^$1:" "$(p /etc/group)" 2>/dev/null; else getent group "$1" > /dev/null; fi; }

profile_get() { anjvm profile "$1" | sed -n "s/^$2=//p"; }

# ---------------------------------------------------------------------------------------------
# Manifest: step<TAB>kind<TAB>value; kinds file, dir, ufw, hosts, enabled, libvirt, account

manifest_has() { [[ -f "$(p "$MANIFEST")" ]] && grep -qxF "$1"$'\t'"$2"$'\t'"$3" "$(p "$MANIFEST")"; }
manifest_add() {
    is_apply || return 0
    [[ "$MODE" == qual || "$MODE" == qual-destroy ]] && return 0
    manifest_has "$@" && return 0
    mkdir -p "$(p "$CONF_DIR")" || abort "cannot create $CONF_DIR"
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$(p "$MANIFEST")" || abort "cannot write the manifest"
}
manifest_list() {
    [[ -f "$(p "$MANIFEST")" ]] || return 0
    S="$1" K="$2" awk -F'\t' '$1==ENVIRON["S"] && $2==ENVIRON["K"] {print $3}' "$(p "$MANIFEST")"
}
manifest_drop() {
    is_apply || return 0
    [[ -f "$(p "$MANIFEST")" ]] || return 0
    local tmp; tmp="$(mktemp "$WORK/manifest.XXXXXX")"
    S="$1" K="$2" V="$3" awk -F'\t' '!($1==ENVIRON["S"] && $2==ENVIRON["K"] && $3==ENVIRON["V"])' "$(p "$MANIFEST")" > "$tmp" \
        || abort "cannot read the manifest"
    cat "$tmp" > "$(p "$MANIFEST")" || abort "cannot write the manifest"
}
file_owned_elsewhere() {
    [[ -f "$(p "$MANIFEST")" ]] || return 1
    S="$1" V="$2" awk -F'\t' '$1!=ENVIRON["S"] && $2=="file" && $3==ENVIRON["V"] {f=1} END {exit !f}' "$(p "$MANIFEST")"
}

file_allowed() {
    case "$1" in
        *anj-cloud*) return 0 ;;
        "$UNIT_DIR/$MOUNT_UNIT") return 0 ;;
    esac
    return 1
}

# want_file step path mode < content: write when absent or different; sets WANT_CHANGED=1.
want_file() {
    local step="$1" path="$2" mode="$3" tmp target dir
    file_allowed "$path" || die "file rule: refusing to create $path"
    tmp="$(mktemp "$WORK/file.XXXXXX")"
    cat > "$tmp"
    target="$(p "$path")"
    if [[ -f "$target" ]] && cmp -s "$tmp" "$target" && [[ "$(stat -c '%a' "$target")" == "$mode" ]]; then
        manifest_add "$step" file "$path"
        return 0
    fi
    WANT_CHANGED=1
    if ! is_apply; then
        log "    would write $path (mode $mode$([[ -e "$target" ]] && printf ', replacing the current copy'))"
        return 0
    fi
    dir="$(dirname "$path")"
    if [[ ! -d "$(p "$dir")" ]]; then
        mkdir -p "$(p "$dir")" || abort "cannot create $dir"
        manifest_add "$step" dir "$dir"
    fi
    if (( FAKE_ROOT )); then install -m "$mode" "$tmp" "$target" || abort "cannot write $path"
    else install -m "$mode" -o root -g root "$tmp" "$target" || abort "cannot write $path"; fi
    manifest_add "$step" file "$path"
    log "    wrote $path"
}

remove_step_files() {
    local step="$1" path dir
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        if file_owned_elsewhere "$step" "$path"; then log "    kept $path (listed by another step)"
        elif [[ -e "$(p "$path")" ]]; then change rm -f "$(p "$path")"; fi
        manifest_drop "$step" file "$path"
    done < <(manifest_list "$step" file)
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        if [[ -d "$(p "$dir")" && -z "$(ls -A "$(p "$dir")")" ]]; then change rmdir "$(p "$dir")"; fi
        manifest_drop "$step" dir "$dir"
    done < <(manifest_list "$step" dir)
}

units_verify() {
    local unit failed=0 out
    for unit in "$@"; do
        out="$(systemd-analyze verify "$(p "$UNIT_DIR/$unit")" 2>&1)" || failed=1
        [[ -z "$out" ]] || log "    systemd-analyze verify $unit: $out"
    done
    return "$failed"
}

# ufw rules by comment. A rule's comment is the text after "# " at the end of its status line.
# ufw_numbers COMMENT [prefix]: rule numbers (highest first) whose comment equals COMMENT or, with
# "prefix", equals it or starts with "COMMENT ".
ufw_numbers() {
    local out
    out="$(ufw status numbered 2>/dev/null)" || true
    C="$1" M="${2:-exact}" awk '
        index($0, "# ") {
            s = $0; sub(/^.*# /, "", s); sub(/[ \t]+$/, "", s)
            c = ENVIRON["C"]
            if (s == c || (ENVIRON["M"] == "prefix" && index(s, c " ") == 1)) {
                n = $0; sub(/^\[ */, "", n); sub(/\].*$/, "", n); print n
            }
        }' <<<"$out" | sort -rn
}
ufw_has() { [[ -n "$(ufw_numbers "$1")" ]]; }
ufw_delete_comment() {
    # ufw_delete_comment COMMENT [prefix]: delete those rules, re-reading numbers after each delete.
    local comment="$1" mode="${2:-exact}" n rounds=0
    while n="$(ufw_numbers "$comment" "$mode" | head -n1 || true)"; [[ -n "$n" ]]; do
        (( ++rounds <= 40 )) || abort "ufw rules '$comment' did not go away"
        change ufw --force delete "$n"
        is_apply || break
    done
}

# ---------------------------------------------------------------------------------------------
# Preconditions, evidence

guard_test_mode() {
    [[ -z "$R" && -z "${ANJ_HOST_STUBS:-}" ]] && return 0
    [[ -n "$R" && -n "${ANJ_HOST_STUBS:-}" && "$R" != "/" && -d "$R" ]] || die "ANJ_HOST_ROOT and ANJ_HOST_STUBS are a test harness pair"
    local command
    for command in virsh ufw nft systemctl systemd-analyze ip ss sshd uname pacman docker runuser tailscale visudo sudo \
                   xorriso ssh ssh-keygen mountpoint gpgv sysctl systemd-sysusers; do
        [[ "$(command -v "$command")" == "$ANJ_HOST_STUBS/"* ]] || die "test harness: $command must resolve inside ANJ_HOST_STUBS"
    done
    [[ "${ANJ_HOST_FAKE_ROOT:-0}" == 1 ]] && FAKE_ROOT=1
    return 0
}

preconditions() {
    local host os_id os_like entry
    host="$(uname -n)"
    [[ "$host" == "$REQUIRED_HOST" ]] || die "this host is '$host'; halo-vm.sh runs only on $REQUIRED_HOST"
    os_id="$(sed -n 's/^ID=//p' "$(p /etc/os-release)" | tr -d '"')"
    os_like="$(sed -n 's/^ID_LIKE=//p' "$(p /etc/os-release)" | tr -d '"')"
    [[ "$os_id" == "arch" || " $os_like " == *" arch "* ]] || die "not an Arch-based system"
    if [[ "$MODE" == qual || "$MODE" == qual-destroy ]]; then
        (( EUID != 0 && ! FAKE_ROOT )) || die "--$MODE runs as the VM host user (libvirt group), never as root"
        USER_NAME="$(id -un)"
        AGENT=1
    elif is_root; then
        [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]] || die "run through sudo from the VM host user (SUDO_USER missing)"
        USER_NAME="$SUDO_USER"
    else
        [[ "$MODE" == dry-run || "$MODE" == verify ]] || die "--$MODE changes the VM host and needs sudo (operator-run, #49)"
        AGENT=1
        USER_NAME="$(id -un)"
    fi
    entry="$(getent passwd "$USER_NAME")" || die "unknown user $USER_NAME"
    USER_UID="$(cut -d: -f3 <<<"$entry")"
    USER_HOME="$(cut -d: -f6 <<<"$entry")"
    [[ -n "$IMAGE" ]] || IMAGE="$(p "$USER_HOME")/.local/share/anj-cloud/prod-vm/image/debian-13-genericcloud-amd64.qcow2"
    if (( ${#KEYS[@]} == 0 )); then
        local saved
        saved="$(json_get "$(p "$HOST_CONFIG")" seed_keys)"
        if [[ -n "$saved" ]]; then read -ra KEYS <<<"$saved"
        else KEYS=("$(p "$USER_HOME")/.ssh/anj-prod-admin.pub"); fi
    fi
    [[ -n "$NET_MODE" ]] || NET_MODE="$(json_get "$(p "$HOST_CONFIG")" net_mode)"
    [[ -n "$NET_MODE" ]] || NET_MODE="nat"
    [[ "$NET_MODE" == nat || "$NET_MODE" == open ]] || die "--net-mode is nat or open"
}

setup_evidence() {
    local stamp parent suffix=""
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    parent="${EVIDENCE_PARENT:-$(p "$USER_HOME")/.local/share/anj-cloud/qualification}"
    [[ -n "$ONLY" ]] && suffix="-$ONLY"
    [[ -n "$ROLLBACK_STEP" ]] && suffix="-$ROLLBACK_STEP"
    EVID="$parent/f15-vm-host-$stamp-$MODE$suffix"
    local n=1 base="$EVID"
    while [[ -e "$EVID" ]]; do n=$((n + 1)); EVID="$base-$n"; done
    mkdir -p "$EVID/raw"
    chmod 0750 "$EVID"
    : > "$EVID/steps.tsv"
    WORK="$(mktemp -d)"
    {
        printf 'mode\t%s\n' "$MODE"
        printf 'privilege\t%s\n' "$( (( AGENT )) && echo agent || echo sudo)"
        printf 'user\t%s\n' "$USER_NAME"
        printf 'started\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'script_sha256\t%s\n' "$(sha < "${BASH_SOURCE[0]}")"
        printf 'repo_commit\t%s\n' "$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
        printf 'net_mode\t%s\n' "$NET_MODE"
    } > "$EVID/run.meta"
}

finish() {
    local code=$?
    [[ -n "$EVID" && -d "$EVID" ]] || exit "$code"
    printf 'finished\t%s\nexit\t%s\nstopped\t%s\ncompleted\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$code" \
        "$STOPPED" "${COMPLETED[*]:-}" >> "$EVID/run.meta"
    python3 -I - "$EVID" <<'PY' || true
import json, sys
from pathlib import Path
evid = Path(sys.argv[1])
meta = dict(line.split("\t", 1) for line in (evid / "run.meta").read_text().splitlines() if "\t" in line)
steps = []
for line in (evid / "steps.tsv").read_text().splitlines():
    step, status, before, after, detail = (line.split("\t") + [""] * 5)[:5]
    steps.append({"step": int(step), "status": status, "before": before, "after": after, "detail": detail,
                  "pass": status not in ("fail", "refused")})
others = json.loads((evid / "others-compare.json").read_text()) if (evid / "others-compare.json").exists() else {}
summary = {key: meta.get(key) for key in ("mode", "privilege", "user", "started", "finished", "script_sha256",
                                          "repo_commit", "net_mode")}
summary.update(exit=int(meta.get("exit", "1")), stopped_at=meta.get("stopped") or None,
               completed_steps=meta.get("completed", "").split(), steps=steps, others_untouched=others or None)
summary["pass"] = summary["exit"] == 0 and all(s["pass"] for s in steps) and others.get("pass", True)
(evid / "summary.json").write_text(json.dumps(summary, indent=1) + "\n")
PY
    if (( EUID == 0 )) && [[ -n "$USER_NAME" ]]; then chown -R "$USER_NAME:" "$EVID" 2>/dev/null || true; fi
    [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"
    [[ -n "$IMAGE_TMP" && -d "$IMAGE_TMP" ]] && rm -rf "$IMAGE_TMP"
    printf 'evidence: %s\n' "$EVID"
    exit "$code"
}

capture_reads() {
    log "== reads"
    read_raw libvirt-version V version > /dev/null
    read_raw domains V list --all > /dev/null
    read_raw networks V net-list --all > /dev/null
    read_raw machine-slice anjvm headroom > /dev/null
    if (( AGENT )); then
        log "  agent subset: nft ruleset and ufw status need sudo (skipped)"
    else
        read_raw nft-ruleset nft list ruleset > /dev/null
        read_raw ufw-status-verbose ufw status verbose > /dev/null
    fi
}

# ---------------------------------------------------------------------------------------------
# Others untouched (spec #21 Others Untouched; #90 (4))

snapshot_others() {
    local out="$1" f name line state
    : > "$out"
    snap() { printf '%s\t%s\n' "$1" "$2" >> "$out"; }
    needs_root() { if (( AGENT )); then snap "$1" "skipped-needs-root"; return 1; fi; return 0; }
    snap boot_id "$(cat "$(p /proc/sys/kernel/random/boot_id)" 2>/dev/null || echo unknown)"
    for f in "$(p /etc/ssh/sshd_config)" "$(p /etc/ssh/sshd_config.d)"/*; do
        name="sshd.file.${f#"$(p /etc/ssh/)"}"
        if [[ -r "$f" ]]; then snap "$name" "$(sha < "$f")"; else needs_root "$name" && snap "$name" unreadable; fi
    done
    if needs_root sshd.effective_digest; then snap sshd.effective_digest "$(sshd -T 2>/dev/null | sha)"; fi
    if needs_root sshd.listeners; then
        snap sshd.listeners "$(ss -tlnpH 2>/dev/null | awk '/"sshd/ {print $4}' | sort | tr '\n' ' ')"
    fi
    snap sshd.mainpid "$(systemctl show -p MainPID --value sshd.service 2>/dev/null || echo unknown)"
    # libvirt: every network and domain other than anj-prod/anj-qual (state + XML digest).
    while IFS= read -r name; do
        [[ -n "$name" && "$name" != "$PROD" && "$name" != "$QUAL" ]] || continue
        snap "libvirt.net.$name" "$(V net-dumpxml --inactive "$name" 2>/dev/null | sha)"
        snap "libvirt.net-state.$name" "$(V net-info "$name" 2>/dev/null | awk -F': *' '/^Active/ {print $2}')"
    done < <(V net-list --all --name 2>/dev/null)
    while IFS= read -r name; do
        [[ -n "$name" && "$name" != "$PROD" && "$name" != "$QUAL" ]] || continue
        snap "libvirt.domain.$name" "$(V dumpxml --inactive "$name" 2>/dev/null | sha)"
        snap "vm.$name" "$(V domstate "$name" 2>/dev/null)"
    done < <(V list --all --name 2>/dev/null)
    snap virbr0.addr "$(ip -o addr show dev virbr0 2>/dev/null | awk '{print $3, $4}' | sort | sha)"
    if needs_root libvirt.nft; then
        while IFS= read -r line; do
            [[ "$line" == *libvirt* ]] || continue
            # shellcheck disable=SC2086
            snap "libvirt.nft.${line#table }" "$(nft -s list $line 2>/dev/null | grep -vE 'virbr-anj(prod|qual)|10\.77\.1[01]\.' | sha)"
        done < <(nft list tables 2>/dev/null)
    fi
    # The VM host memory policy: never modified.
    for f in "$(p /etc/systemd/system/machine.slice.d)"/* "$(p /etc/systemd/system/user.slice.d)"/* \
             "$(p /usr/local/lib/halo-host-memory)"/*; do
        [[ -f "$f" && -r "$f" ]] && snap "memory.${f#"$(p /)"}" "$(sha < "$f")"
    done
    for name in docker.socket docker.service containerd.service libvirtd.service libvirt-guests.service; do
        snap "unit-state.$name" "$(systemctl is-enabled "$name" 2>/dev/null || true)/$(systemctl is-active "$name" 2>/dev/null || true)"
    done
    while IFS=$'\t' read -r name state line; do
        [[ -n "$name" ]] || continue
        case "$line" in anj-cloud-*) continue ;; esac
        case "$name" in anj-cloud-*) continue ;; esac
        snap "container.$name" "$state"
    done < <(as_user docker ps -a --format '{{.Names}}\t{{.State}}\t{{.Label "com.docker.compose.project"}}' 2>/dev/null)
    while IFS= read -r name; do
        case "$name" in anj-cloud-*|"") continue ;; esac
        snap "network.$name" present
    done < <(as_user docker network ls --format '{{.Name}}' 2>/dev/null)
    snap tailscale.serve "$(tailscale serve status 2>/dev/null | sha)"
    while IFS= read -r name; do
        snap "$(unit_class "$name").system.$name" running
    done < <(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print $1}' | filter_units)
}

as_user() {
    if (( AGENT )); then env DOCKER_HOST="unix:///run/user/$USER_UID/docker.sock" "$@"
    else runuser -u "$USER_NAME" -- env HOME="$USER_HOME" XDG_RUNTIME_DIR="/run/user/$USER_UID" \
        DOCKER_HOST="unix:///run/user/$USER_UID/docker.sock" "$@"; fi
}

filter_units() {
    grep -vE '^(anj-cloud-|run-|app-|dbus-:|session-|user-runtime-dir@|systemd-(hostnamed|timedated|localed|tmpfiles)|virtiofsd|machine-qemu)' || true
}

unit_class() {
    case "$1" in sshd*|libvirt*|virt*|docker*|containerd*|tailscaled*) printf 'unit.strict' ;; *) printf 'unit.other' ;; esac
}

compare_others() {
    python3 -I - "$1" "$2" "$EVID/others-compare.json" <<'PY'
import json, sys
def load(path):
    return dict(line.split("\t", 1) for line in open(path).read().splitlines() if "\t" in line)
before, after = load(sys.argv[1]), load(sys.argv[2])
rebooted = before.get("boot_id") != after.get("boot_id")
confirm = ("vm.", "container.", "network.", "unit.other.", "libvirt.net-state.")
result = {"pass": True, "equal": 0, "skipped": [], "differences": [], "confirm": [], "rebooted": rebooted}
for key in sorted(set(before) | set(after)):
    if key == "boot_id":
        continue
    b, a = before.get(key, "<absent>"), after.get(key, "<absent>")
    if "skipped-needs-root" in (b, a):
        result["skipped"].append(key)
    elif b == a:
        result["equal"] += 1
    elif key.startswith(confirm) or (rebooted and key == "sshd.mainpid"):
        result["confirm"].append({"item": key, "before": b, "after": a})
    else:
        result["differences"].append({"item": key, "before": b, "after": a})
        result["pass"] = False
json.dump(result, open(sys.argv[3], "w"), indent=1)
print(f"others untouched: {'PASS' if result['pass'] else 'FAIL'}; equal {result['equal']}, differences "
      f"{len(result['differences'])}, for operator confirmation {len(result['confirm'])}, skipped {len(result['skipped'])}")
for row in result["differences"]:
    print(f"  DIFFERENT {row['item']}")
for row in result["confirm"]:
    print(f"  confirm   {row['item']}: {row['before']} -> {row['after']}")
sys.exit(0 if result["pass"] else 1)
PY
}

# ---------------------------------------------------------------------------------------------
# Shared VM helpers (profile = anj-prod | anj-qual)

running_reserved_kib() {
    # Configured memory of running domains other than $1 (counted at full size).
    local skip="$1" name total=0 kib
    while IFS= read -r name; do
        [[ -n "$name" && "$name" != "$skip" ]] || continue
        kib="$(V dominfo "$name" 2>/dev/null | awk '/^Max memory:/ {print $3}' || true)"
        [[ "$kib" =~ ^[0-9]+$ ]] && total=$(( total + kib ))
    done < <(V list --state-running --name 2>/dev/null)
    printf '%s' "$total"
}

image_verified() {
    # image_verified [file]: the file (default the image) must match the digest pinned in the repo
    # and the SHA512SUMS line next to the image.
    local file="${1:-$IMAGE}" pinned actual listed dir sums
    local pin_file="$HERE/libvirt/debian-13-genericcloud-amd64.sha512"
    [[ -n "$R" && -n "${ANJ_HOST_IMAGE_PIN:-}" ]] && pin_file="$ANJ_HOST_IMAGE_PIN"
    pinned="$(awk '{print $1}' "$pin_file")"
    [[ -f "$file" ]] || { log "    image missing: $file"; return 1; }
    dir="$(dirname "$IMAGE")"; sums="$dir/SHA512SUMS"
    actual="$(sha512sum "$file" | cut -d' ' -f1)"
    listed="$(awk -v f="$(basename "$IMAGE")" '$2==f {print $1}' "$sums" 2>/dev/null || true)"
    log "    image sha512 ${actual:0:16}…; pinned ${pinned:0:16}…; SHA512SUMS ${listed:0:16}…"
    if [[ -f "$sums.sign" && -n "${ANJ_DEBIAN_KEYRING:-}" ]]; then
        gpgv --keyring "$ANJ_DEBIAN_KEYRING" "$sums.sign" "$sums" > /dev/null 2>&1 || { log "    SHA512SUMS signature does not verify"; return 1; }
        log "    SHA512SUMS signature verified"
    else
        log "    upstream publishes no SHA512SUMS signature for cloud images; trust = pinned digest in the reviewed repo"
    fi
    [[ "$actual" == "$pinned" && "$listed" == "$pinned" ]]
}

threads_free() {
    # Threads 14,15,30,31 pinned by no domain other than anj-prod/anj-qual.
    local name used=""
    : > "$WORK/others-cpus"
    while IFS= read -r name; do
        [[ -n "$name" && "$name" != "$PROD" && "$name" != "$QUAL" ]] || continue
        V dumpxml --inactive "$name" > "$WORK/dom-$name.xml" 2>/dev/null || continue
        printf '%s\n' "$WORK/dom-$name.xml" >> "$WORK/others-cpus"
    done < <(V list --all --name 2>/dev/null)
    if [[ -s "$WORK/others-cpus" ]]; then
        mapfile -t files < "$WORK/others-cpus"
        used="$(anjvm cpus "${files[@]}" || echo unknown)"
    fi
    local thread clash=""
    for thread in $THREADS; do [[ " $used " == *" $thread "* ]] && clash+="$thread "; done
    [[ -z "$clash" ]] || { log "    threads pinned by another domain: $clash"; return 1; }
}

subnet_free() {
    local subnet="$1" bridge="$2" routes
    routes="$(ip -4 route show "$subnet.0/24" 2>/dev/null | grep -v "dev $bridge" || true)"
    [[ -z "$routes" ]] || { log "    $subnet.0/24 already routed: $routes"; return 1; }
}

headroom_ok() {
    local profile="$1" need="$2" json room
    json="$(anjvm headroom --reserved-kib "$(running_reserved_kib "$profile")" 2>&1 || true)"
    room="$(json_get - headroom <<<"$json")"
    log "    machine.slice: $json (need $need)"
    [[ "$room" =~ ^-?[0-9]+$ ]] && (( room >= need ))
}

ensure_pool() {
    local profile="$1" pool
    pool="$(profile_get "$profile" pool)"
    if ! V pool-info "$pool" > /dev/null 2>&1; then
        anjvm render-pool "$profile" > "$WORK/pool.xml"
        change V pool-define "$WORK/pool.xml"
        change V pool-build "$pool"
        [[ "$profile" == "$PROD" ]] && change V pool-autostart "$pool"
        manifest_add 3 libvirt "pool:$pool"
    fi
    has 'State:.*running' V pool-info "$pool" || change V pool-start "$pool"
}

vol_exists() { V vol-info --pool "$1" "$2" > /dev/null 2>&1; }

make_seed() {
    # make_seed profile instance-id -> uploads <profile>-seed.iso (replacing an older one).
    local profile="$1" instance="$2" pool key args=()
    pool="$(profile_get "$profile" pool)"
    for key in "${KEYS[@]}"; do args+=(--key "$key"); done
    rm -rf "$WORK/seed"
    anjvm seed "$profile" --out "$WORK/seed" --instance-id "$instance" "${args[@]}" > /dev/null || abort "cannot build the seed"
    xorriso -as mkisofs -quiet -o "$WORK/seed.iso" -V cidata -J -R "$WORK/seed" 2> /dev/null || abort "cannot build the seed image"
    vol_exists "$pool" "$profile-seed.iso" && change V vol-delete --pool "$pool" "$profile-seed.iso"
    change V vol-create-as "$pool" "$profile-seed.iso" "$(stat -c %s "$WORK/seed.iso")" --format raw
    change V vol-upload --pool "$pool" "$profile-seed.iso" "$WORK/seed.iso"
}

verified_image_copy() {
    # Copy the image to a private temporary file and verify that copy; sets IMAGE_COPY. The bytes
    # uploaded are the bytes verified, whatever happens to the user-writable original meanwhile.
    local dir
    dir="$(mktemp -d "$(p /var/tmp)/anj-cloud-image.XXXXXX")" || abort "cannot create a private image copy"
    IMAGE_TMP="$dir"
    cp --no-preserve=all "$IMAGE" "$dir/image.qcow2" || abort "cannot copy the image"
    image_verified "$dir/image.qcow2" || abort "the image copy does not match the pinned digest; nothing uploaded"
    IMAGE_COPY="$dir/image.qcow2"
}

make_volumes() {
    # OS disk from the verified image, data disk only if absent, seed only if absent (or $2=force).
    local profile="$1" force_seed="${2:-0}" pool os data copy
    pool="$(profile_get "$profile" pool)"; os="$(profile_get "$profile" os_gib)"; data="$(profile_get "$profile" data_gib)"
    if ! vol_exists "$pool" "$profile-os.qcow2"; then
        if is_apply; then
            verified_image_copy
            copy="$IMAGE_COPY"
        else
            image_verified > /dev/null || log "    the image does not verify; --apply would stop here"
            copy="$IMAGE"
        fi
        change V vol-create-as "$pool" "$profile-os.qcow2" "$(stat -c %s "$copy")" --format qcow2
        change V vol-upload --pool "$pool" "$profile-os.qcow2" "$copy"
        change V vol-resize --pool "$pool" "$profile-os.qcow2" "${os}G"
        if [[ -n "$IMAGE_TMP" ]]; then rm -rf "$IMAGE_TMP"; IMAGE_TMP=""; fi
    fi
    if ! vol_exists "$pool" "$profile-data.qcow2"; then
        change V vol-create-as "$pool" "$profile-data.qcow2" "${data}G" --format qcow2
    fi
    if (( force_seed )) || ! vol_exists "$pool" "$profile-seed.iso"; then
        make_seed "$profile" "$profile-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
}

# Backup share ownership (decision #115). passwd_args: the test harness reads $R/etc/passwd.
passwd_args() { [[ -n "$R" ]] && printf -- '--passwd\n%s\n' "$(p /etc/passwd)"; return 0; }
share_check() {
    # share_check PATH: anjvm's JSON view (owner, mode, account, ok) of a share; never fails.
    local args=()
    mapfile -t args < <(passwd_args)
    anjvm share-check "$1" --account "$SHARE_ACCOUNT" "${args[@]}" 2>/dev/null || true
}
share_ok() { [[ "$(json_get - ok <<<"$(share_check "$1")")" == True ]]; }

share_now() {
    # The share the domain should carry now. anj-prod: the backup directory when DOS_BACKUP is
    # mounted and the directory is owned by the account, mode 0700 (as vm-start decides).
    if [[ "$1" == "$PROD" ]] && mountpoint -q "$MOUNT_POINT" 2>/dev/null && [[ -d "$(p "$SHARE_DIR")" ]] \
        && share_ok "$(p "$SHARE_DIR")"; then
        printf '%s' "$SHARE_DIR"
    elif [[ "$1" == "$QUAL" && -n "$QUAL_SHARE" ]]; then
        printf '%s' "$QUAL_SHARE"
    fi
}

share_map() {
    # share_map PROFILE: "uid gid" on the VM host that the guest's anj (1000:1000) maps to: the owner of
    # the share directory (the wrapper reads it), which for the production share is the account.
    local json
    if [[ "$1" == "$PROD" ]] || (( QUAL_SHARE_RO )); then json="$(share_check "$(p "$SHARE_DIR")")"
    else json="$(share_check "$QUAL_SHARE")"; fi   # validated real path
    printf '%s %s' "$(json_get - uid <<<"$json")" "$(json_get - gid <<<"$json")"
}

# wrapper_current: the root-owned virtiofsd wrapper and the anjvm.py it imports are installed and
# equal to this checkout (step 6 installs them; the share's mapping depends on them).
wrapper_current() {
    local name
    for name in virtiofsd-anj-cloud anjvm.py; do
        cmp -s "$HERE/$name" "$(p "$LIB_DIR/$name")" || return 1
    done
}

render_domain() {
    local profile="$1" uuid="$2" share args=()
    share="$(share_now "$profile")"
    [[ -n "$share" ]] && args+=(--share "$share")
    [[ "$profile" == "$QUAL" && "$QUAL_SHARE_RO" == 1 ]] && args+=(--readonly)
    [[ "$profile" == "$QUAL" ]] && args+=(--description "anj-qual run-id=${RUN_ID:-none}")
    anjvm render-domain "$profile" --uuid "$uuid" "${args[@]}"
}

new_uuid() { python3 -I -c 'import uuid; print(uuid.uuid4())'; }

# ---------------------------------------------------------------------------------------------
# Steps: step_N phase (plan | apply | verify | rollback)

step_1() {
    local phase="$1" problems=() version
    [[ "$phase" == rollback ]] && { record 1 info "" "" "read-only step"; return 0; }
    version="$(V version --daemon 2>/dev/null | sed -nE 's/.*Running against daemon: *([0-9.]+).*/\1/p' || true)"
    if [[ -z "$version" || "$(printf '%s\n%s\n' "$MIN_LIBVIRT" "$version" | sort -V | head -n1)" != "$MIN_LIBVIRT" ]]; then
        problems+=("libvirt ${version:-unknown} < $MIN_LIBVIRT")
    fi
    headroom_ok "$PROD" "$PROD_HEADROOM" || problems+=("machine.slice headroom below 4.5 GiB beyond running domains")
    threads_free || problems+=("threads 14,30,15,31 pinned by another domain")
    subnet_free 10.77.10 virbr-anjprod || problems+=("10.77.10.0/24 in use")
    image_verified || problems+=("Debian image not verified")
    local key
    for key in "${KEYS[@]}"; do [[ -r "$key" ]] || problems+=("SSH key $key unreadable"); done
    if (( ${#problems[@]} )); then
        record 1 "$([[ "$phase" == verify ]] && echo fail || echo refused)" "" "" "$(IFS=';'; echo "${problems[*]}")"
        [[ "$phase" == apply ]] && { STOPPED=1; return 1; }
    else
        record 1 pass "" "" "libvirt $version; headroom, threads, subnet, image and keys OK"
    fi
    return 0
}

# --- ufw rule order -------------------------------------------------------------------------
# ufw stops at the first matching rule, so order is part of every rule's meaning:
# - input from a VM bridge: the DHCP and DNS allows must sit above that bridge's deny-all;
# - routed traffic from a VM: every "no LAN" deny must sit above the broad egress allow.
# Rules this script must delete while a replacement is not yet in place are kept on a restore
# list; an abort or signal puts them back in a safe position (allows prepended above the bridge
# deny; the egress allow appended below the LAN denies), and the order is checked afterwards.

RESTORE_RULES=()   # "position<TAB>comment<TAB>ufw args (unit separator)" to re-add on abort

restore_push() {
    # restore_push prepend|append COMMENT ARGS...: remember how to put this rule back.
    local position="$1" comment="$2"
    shift 2
    local IFS=$'\x1f'
    RESTORE_RULES+=("$position"$'\t'"$comment"$'\t'"$*")
}

restore_pop() {
    # restore_pop COMMENT: its replacement is in place.
    local kept=() entry
    for entry in "${RESTORE_RULES[@]}"; do
        [[ "$(cut -f2 <<<"$entry")" == "$1" ]] || kept+=("$entry")
    done
    RESTORE_RULES=("${kept[@]}")
}

restore_rules() {
    # On abort: re-add every rule taken out by this run whose replacement is not in place.
    local entry position comment args
    for entry in "${RESTORE_RULES[@]}"; do
        position="$(cut -f1 <<<"$entry")"; comment="$(cut -f2 <<<"$entry")"
        IFS=$'\x1f' read -ra args <<<"$(cut -f3- <<<"$entry")"
        log "    restoring ufw rule: $comment"
        if [[ "$position" == prepend ]]; then
            if [[ "${args[0]}" == route ]]; then change_try ufw route prepend "${args[@]:1}" comment "$comment" || true
            else change_try ufw prepend "${args[@]}" comment "$comment" || true; fi
        else
            change_try ufw "${args[@]}" comment "$comment" || true
        fi
    done
    RESTORE_RULES=()
}

ufw_order_problems() {
    # Print one line per unsafe ordering in the current ruleset (empty when safe).
    local out
    out="$(ufw status numbered 2>/dev/null)" || { echo "ufw status unreadable"; return 0; }
    local prog
    prog="$(cat <<'PY'
import re, sys
rules = []
for line in sys.stdin.read().splitlines():
    m = re.match(r"\[\s*(\d+)\]\s+(.*?)(?:\s+#\s+(.*))?$", line)
    if m:
        rules.append((int(m.group(1)), m.group(2), (m.group(3) or "").strip()))
# ufw numbers IPv4 rules first and IPv6 rules (marked "(v6)") after them: compare within a family.
def family(text):
    return "v6" if "(v6)" in text else "v4"
for bridge, prefix in (("virbr-anjprod", ("anj-cloud-vm", "anj-prod")), ("virbr-anjqual", ("anj-cloud-qual",))):
    for fam in ("v4", "v6"):
        mine = [(n, text, comment) for n, text, comment in rules if bridge in text and family(text) == fam]
        denies = [n for n, text, comment in mine if comment.endswith("bridge deny")]
        if denies:
            for n, text, comment in mine:
                if comment.startswith(prefix) and re.search(r"\b(dhcp|dns udp|dns tcp|DHCP|DNS UDP|DNS TCP)$", comment) \
                        and n > min(denies):
                    print(f"{comment} (#{n}) sits below {bridge}'s deny (#{min(denies)})")
        lan_denies = [n for n, text, comment in mine if " no LAN " in f" {comment} "]
        for n, text, comment in mine:
            if comment.endswith(("egress", "outbound NAT")) and any(d > n for d in lan_denies):
                print(f"{comment} (#{n}) sits above a LAN deny on {bridge}")
PY
)"
    python3 -I -c "$prog" <<<"$out" 2>/dev/null || echo "order check failed"
}

check_ufw_order() {
    # check_ufw_order CONTEXT: abort loudly when an allow precedes a deny it must not shadow.
    local problems
    (( AGENT )) && return 0
    is_apply || return 0
    problems="$(ufw_order_problems)"
    [[ -z "$problems" ]] || abort "UNSAFE UFW ORDER after $1: $(tr '\n' ';' <<<"$problems")"
}

# Planner-made rules for virbr-anjprod (2026-11-03, prod-vm/ufw-anj-prod.sh), adopted by --apply.
readonly PLANNER_INPUT=("anj-prod DHCP" "anj-prod DNS UDP" "anj-prod DNS TCP")
readonly PLANNER_ROUTE=("anj-prod no LAN 10.0.0.0/8" "anj-prod no LAN 172.16.0.0/12" "anj-prod no LAN 192.168.0.0/16"
                        "anj-prod outbound NAT")
readonly PLANNER_RULES=("${PLANNER_INPUT[@]}" "${PLANNER_ROUTE[@]}")

planner_original() {
    # The ufw arguments the planner used (prod-vm/ufw-anj-prod.sh).
    case "$1" in
        "anj-prod DHCP") printf '%s\n' allow in on virbr-anjprod proto udp from any port 68 to any port 67 ;;
        "anj-prod DNS UDP") printf '%s\n' allow in on virbr-anjprod proto udp from 10.77.10.0/24 to 10.77.10.1 port 53 ;;
        "anj-prod DNS TCP") printf '%s\n' allow in on virbr-anjprod proto tcp from 10.77.10.0/24 to 10.77.10.1 port 53 ;;
        "anj-prod outbound NAT") printf '%s\n' route allow in on virbr-anjprod out on "$IFACE" from 10.77.10.0/24 ;;
        "anj-prod no LAN "*) printf '%s\n' route deny in on virbr-anjprod out on "$IFACE" from 10.77.10.0/24 to "${1#anj-prod no LAN }" ;;
    esac
}

planner_rules_present() {
    # Comments of planner-made rules still present (root: ufw status; agent: /etc/ufw/user.rules).
    local comment
    if (( AGENT )); then
        python3 -I - "$(p /etc/ufw/user.rules)" "${PLANNER_RULES[@]}" <<'PY' 2>/dev/null || true
import re, sys
text = open(sys.argv[1]).read()
found = {bytes.fromhex(h).decode("utf-8", "replace") for h in re.findall(r"comment=([0-9a-f]+)", text)}
print("\n".join(c for c in sys.argv[2:] if c in found))
PY
        return 0
    fi
    for comment in "${PLANNER_RULES[@]}"; do ufw_has "$comment" && printf '%s\n' "$comment"; done
    return 0
}

list_planner_rules() {
    # Dry run and agent subset: name the planner rules this step will replace.
    local comment present
    present="$(planner_rules_present)"
    for comment in "$@"; do
        grep -qxF -- "$comment" <<<"$present" || continue
        if is_apply; then log "    replacing planner-made rule: $comment"
        else log "    will replace planner-made rule: $comment"; fi
    done
}

ufw_bridge_input() {
    # ufw_bridge_input bridge subnet comment: the VM reaches the VM host only for DHCP (67/udp) and DNS
    # (53/tcp+udp to the bridge address); every other input from the bridge is denied, whatever
    # The VM host listens on (for example KDE Connect on all interfaces). Final order, top down: DHCP,
    # DNS TCP, DNS UDP, then the deny. Every rule taken out on the way is on the restore list
    # until its replacement is in, and a restore prepends allows, so they always stay above the deny.
    local bridge="$1" subnet="$2" comment="$3" old i planner present
    local names=("$comment dns udp" "$comment dns tcp" "$comment dhcp")
    local specs=("allow in on $bridge from $subnet.0/24 to $subnet.1 port 53 proto udp"
                 "allow in on $bridge from $subnet.0/24 to $subnet.1 port 53 proto tcp"
                 "allow in on $bridge proto udp from any port 68 to any port 67")
    local planners=("anj-prod DNS UDP" "anj-prod DNS TCP" "anj-prod DHCP")
    [[ "$bridge" == virbr-anjprod ]] || planners=("" "" "")
    present="$(planner_rules_present)"
    local args
    # 1. The allows, each replacing its planner twin (same tuple) at the top.
    for i in 0 1 2; do
        read -ra args <<<"${specs[$i]}"
        planner="${planners[$i]}"
        if [[ -n "$planner" ]] && grep -qxF -- "$planner" <<<"$present"; then
            local orig
            mapfile -t orig < <(planner_original "$planner")
            is_apply && restore_push prepend "$planner" "${orig[@]}"
            ufw_delete_comment "$planner"
            ufw_has "${names[$i]}" || change ufw prepend "${args[@]}" comment "${names[$i]}"
            restore_pop "$planner"
        else
            ufw_has "${names[$i]}" || change ufw prepend "${args[@]}" comment "${names[$i]}"
        fi
    done
    # 2. The deny directly below them: take the allows out, prepend the deny, prepend the allows.
    if ! ufw_has "$comment bridge deny"; then
        for i in 0 1 2; do
            read -ra args <<<"${specs[$i]}"
            is_apply && restore_push prepend "${names[$i]}" "${args[@]}"
            ufw_delete_comment "${names[$i]}"
        done
        change ufw prepend deny in on "$bridge" comment "$comment bridge deny"
        for i in 0 1 2; do
            read -ra args <<<"${specs[$i]}"
            change ufw prepend "${args[@]}" comment "${names[$i]}"
            restore_pop "${names[$i]}"
        done
    fi
    for old in "$comment host dns" "$comment no host"; do ufw_delete_comment "$old"; done
    check_ufw_order "the $bridge input rules"
}

step_2() {
    local phase="$1" live
    case "$phase" in
        plan|apply)
            anjvm render-net "$PROD" --mode "$NET_MODE" > "$WORK/net.xml"
            if V net-info "$PROD" > /dev/null 2>&1; then
                V net-dumpxml --inactive "$PROD" > "$WORK/net-live.xml"
                if ! live="$(anjvm compare-net "$WORK/net.xml" "$WORK/net-live.xml")"; then
                    record 2 refused "" "" "network $PROD differs from the template: $live (use --recreate)"
                    [[ "$phase" == apply ]] && { STOPPED=2; return 1; }
                    return 0
                fi
            else
                change V net-define "$WORK/net.xml"
                manifest_add 2 libvirt "network:$PROD"
                WANT_CHANGED=1
            fi
            has 'Autostart:.*yes' V net-info "$PROD" || change V net-autostart "$PROD"
            has 'Active:.*yes' V net-info "$PROD" || change V net-start "$PROD"
            list_planner_rules "${PLANNER_INPUT[@]}"
            if (( AGENT )); then log "    agent subset: ufw rules need sudo"
            else ufw_bridge_input virbr-anjprod 10.77.10 "$VM_COMMENT"; fi
            record 2 "$([[ "$phase" == plan ]] && echo planned || echo pass)" "" "" "network $PROD ($NET_MODE) matches the template"
            ;;
        verify)
            anjvm render-net "$PROD" --mode "$NET_MODE" > "$WORK/net.xml"
            V net-dumpxml --inactive "$PROD" > "$WORK/net-live.xml" 2>/dev/null || true
            if live="$(anjvm compare-net "$WORK/net.xml" "$WORK/net-live.xml" 2>&1)" && has 'Active:.*yes' V net-info "$PROD"; then
                record 2 pass "" "" "net-dumpxml facts equal the template; active"
            else record 2 fail "" "" "network: ${live:-absent or inactive}"; fi
            ;;
        rollback)
            log "    the network is kept while anj-prod exists; --recreate replaces it"
            record 2 info "" "" "network not removed by rollback"
            ;;
    esac
}

domain_uuid() { local out; out="$(V domuuid "$PROD" 2>/dev/null)" || true; printf '%s' "${out%%$'\n'*}"; }

step_3() {
    local phase="$1" uuid live
    case "$phase" in
        plan|apply)
            uuid="$(domain_uuid)"
            if [[ -z "$uuid" ]]; then ensure_pool "$PROD"; make_volumes "$PROD"; fi
            if [[ -n "$uuid" ]]; then
                render_domain "$PROD" "$uuid" > "$WORK/dom.xml"
                V dumpxml --inactive "$PROD" > "$WORK/dom-live.xml"
                if ! live="$(anjvm compare-domain --ignore shares "$WORK/dom.xml" "$WORK/dom-live.xml")"; then
                    record 3 refused "" "" "domain $PROD differs from the template (never redefined silently): $live; use --recreate --confirm $PROD"
                    [[ "$phase" == apply ]] && { STOPPED=3; return 1; }
                    return 0
                fi
                record 3 "$([[ "$phase" == plan ]] && echo planned || echo compliant)" "" "" "domain matches the template"
            else
                uuid="$(new_uuid)"
                render_domain "$PROD" "$uuid" > "$WORK/dom.xml"
                change V define "$WORK/dom.xml"
                manifest_add 3 libvirt "domain:$PROD"
                record 3 "$([[ "$phase" == plan ]] && echo planned || echo changed)" "" "defined" "4 GiB memfd, pinned 14,30,15,31, UEFI"
            fi
            has 'Autostart:.*disable' V dominfo "$PROD" || change V autostart --disable "$PROD"
            write_prod_ssh_config "$phase"
            ;;
        verify)
            uuid="$(domain_uuid)"
            [[ -n "$uuid" ]] || { record 3 fail "" "" "domain $PROD absent"; return 0; }
            render_domain "$PROD" "$uuid" > "$WORK/dom.xml"
            V dumpxml --inactive "$PROD" > "$WORK/dom-live.xml"
            local pins
            pins="$(V vcpupin "$PROD" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $NF}' | tr '\n' ' ' || true)"
            if live="$(anjvm compare-domain --ignore shares "$WORK/dom.xml" "$WORK/dom-live.xml")"; then
                record 3 pass "" "" "dumpxml facts equal the template; vcpupin $pins; emulatorpin $(V emulatorpin "$PROD" 2>/dev/null | awk 'NF {print $NF}' | tail -n1)"
            else record 3 fail "" "" "differs: $live"; fi
            ;;
        rollback) record 3 info "" "" "the domain is replaced only with --recreate --confirm $PROD" ;;
    esac
}

share_facts() { anjvm share-facts "$1" 2>/dev/null || printf 'unreadable'; }

# share_plan PHASE: create the share, or migrate it (empty only) to the account, mode 0700.
share_plan() {
    local phase="$1" json exists empty owner mode args=()
    json="$(share_check "$(p "$SHARE_DIR")")"
    exists="$(json_get - exists <<<"$json")"; empty="$(json_get - empty <<<"$json")"
    owner="$(json_get - uid <<<"$json"):$(json_get - gid <<<"$json")"; mode="$(json_get - mode <<<"$json")"
    if [[ "$(json_get - ok <<<"$json")" == True ]]; then
        SHARE_NOTE="share $SHARE_DIR owned by $SHARE_ACCOUNT, 0700"
        return 0
    fi
    # Non-empty and not the account's (also while the account does not exist yet): never re-owned.
    if [[ "$exists" == True && "$empty" == False \
          && "$owner" != "$(json_get - account.uid <<<"$json"):$(json_get - account.gid <<<"$json")" ]]; then
        record 4 fail "$owner $mode" "" "$SHARE_DIR holds data owned by $owner; not re-owned (inspect it by hand, decision #115)"
        STOPPED=4; return 1
    fi
    if [[ "$exists" == True ]]; then
        SHARE_NOTE="share $SHARE_DIR $owner $mode$([[ -z "$empty" ]] && echo ' (emptiness checked under sudo)') -> $SHARE_ACCOUNT 0700"
    else
        SHARE_NOTE="share $SHARE_DIR created, $SHARE_ACCOUNT 0700"
    fi
    mapfile -t args < <(passwd_args)
    # The only writes to the shared drive: anj-cloud's own directory (created, or an empty one
    # re-owned), never removed, never formatted.
    change python3 -I "$HERE/anjvm.py" share-own "$(p "$SHARE_DIR")" --account "$SHARE_ACCOUNT" "${args[@]}"
}

# expected_share_facts: the share facts anj-prod should carry (the wrapper binary), or nothing
# while the domain does not exist yet.
expected_share_facts() {
    local uuid
    uuid="$(domain_uuid)"
    [[ -n "$uuid" ]] || return 0
    anjvm render-domain "$PROD" --uuid "$uuid" --share "$SHARE_DIR" > "$WORK/dom-share.xml" && share_facts "$WORK/dom-share.xml"
}

readonly COLD_RESTART="sudo systemctl stop anj-cloud-vm-stop.service; sudo systemctl restart anj-cloud-vm.service; sudo systemctl start anj-cloud-vm-stop.service"

# restart_note: the running anj-prod does not carry the mapped share: a cold restart switches it
# (vm-start redefines the share while the domain is shut off).
restart_note() {
    local expected
    [[ "$(V domstate "$PROD" 2>/dev/null)" == running ]] || return 0
    V dumpxml "$PROD" > "$WORK/dom-running.xml" 2>/dev/null || return 0
    expected="$(expected_share_facts)"
    if [[ -z "$expected" || "$(share_facts "$WORK/dom-running.xml")" != "$expected" ]]; then
        printf '%s' "; the running $PROD does not carry the mapped share: COLD RESTART REQUIRED after this apply ($COLD_RESTART)"
    fi
}

step_4() {
    local phase="$1"
    case "$phase" in
        plan|apply)
            WANT_CHANGED=0
            want_file 4 "$UNIT_DIR/$MOUNT_UNIT" 644 < <(sed "s/@BACKUP_UUID@/$BACKUP_UUID/" "$HERE/units/anj-cloud-backup.mount")
            if [[ "$phase" == apply ]] && (( WANT_CHANGED )) && ! units_verify "$MOUNT_UNIT"; then
                remove_step_files 4; record 4 fail "" "" "mount unit verification failed"; STOPPED=4; return 1
            fi
            (( WANT_CHANGED )) && change systemctl daemon-reload
            [[ "$(systemctl is-enabled "$MOUNT_UNIT" 2>/dev/null || true)" == enabled ]] || change systemctl enable "$MOUNT_UNIT"
            # The account (decision #115): systemd-sysusers allocates a system uid/gid (never 1000).
            want_file 4 "$SYSUSERS_FILE" 644 < "$HERE/units/anj-cloud-backup.sysusers"
            local json problems
            json="$(share_check "$(p "$SHARE_DIR")")"
            if [[ -z "$(json_get - account.uid <<<"$json")" ]]; then
                change systemd-sysusers "$(p "$SYSUSERS_FILE")"
                json="$(share_check "$(p "$SHARE_DIR")")"
            fi
            manifest_add 4 account "$SHARE_ACCOUNT"
            if [[ "$phase" == apply ]]; then
                problems="$(python3 -I -c 'import json,sys; print("; ".join(p for p in json.load(sys.stdin)["problems"] if p.startswith("account")))' <<<"$json" 2>/dev/null || echo "account unreadable")"
                if [[ -n "$problems" ]]; then record 4 fail "" "" "$problems"; STOPPED=4; return 1; fi
            fi
            local account="$SHARE_ACCOUNT $(json_get - account.uid <<<"$json"):$(json_get - account.gid <<<"$json")"
            [[ -n "$(json_get - account.uid <<<"$json")" ]] || account="$SHARE_ACCOUNT (uid assigned by systemd-sysusers)"
            if [[ -e "$(p "/dev/disk/by-uuid/$BACKUP_UUID")" ]]; then
                mountpoint -q "$MOUNT_POINT" || change systemctl start "$MOUNT_UNIT"
                SHARE_NOTE="share $SHARE_DIR created or re-owned to $SHARE_ACCOUNT 0700 once mounted"
                if mountpoint -q "$MOUNT_POINT"; then share_plan "$phase" || return 1; fi
                record 4 "$([[ "$phase" == plan ]] && echo planned || echo pass)" "" "" "DOS_BACKUP present; mount unit at $MOUNT_POINT; account $account; $SHARE_NOTE; guest anj 1000:1000 maps to the account$(restart_note)"
            else
                record 4 "$([[ "$phase" == plan ]] && echo planned || echo info)" "" "" "DOS_BACKUP absent: unit enabled; account $account; the VM starts without the share (#89 (2))"
            fi
            ;;
        verify)
            local problems=() json uid gid expected live probe
            json="$(share_check "$(p "$SHARE_DIR")")"
            uid="$(json_get - account.uid <<<"$json")"; gid="$(json_get - account.gid <<<"$json")"
            mountpoint -q "$MOUNT_POINT" || problems+=("DOS_BACKUP not mounted (VM runs without backups)")
            wrapper_current || problems+=("$WRAPPER or its anjvm.py is missing or differs from this checkout (step 6)")
            if [[ "$(json_get - ok <<<"$json")" != True ]]; then
                problems+=("share: $(python3 -I -c 'import json,sys; print(", ".join(json.load(sys.stdin)["problems"]))' <<<"$json" 2>/dev/null || echo unreadable)")
            fi
            expected="$(expected_share_facts)"
            if [[ -n "$expected" ]]; then
                V dumpxml --inactive "$PROD" > "$WORK/dom-inactive.xml" 2>/dev/null || true
                live="$(share_facts "$WORK/dom-inactive.xml")"
                [[ "$live" == "$expected" ]] || problems+=("persistent definition share $live, expected $expected")
                if [[ "$(V domstate "$PROD" 2>/dev/null)" == running ]]; then
                    V dumpxml "$PROD" > "$WORK/dom-running.xml" 2>/dev/null || true
                    live="$(share_facts "$WORK/dom-running.xml")"
                    [[ "$live" == "$expected" ]] || problems+=("running domain share $live, expected $expected (cold restart: $COLD_RESTART)")
                    # The live mapping, read from the running virtiofsd's own arguments.
                    probe="$(anjvm virtiofsd-args "$SHARE_DIR" --proc "$(p /proc)" 2>/dev/null || true)"
                    if [[ "$probe" != *"\"map:$GUEST_ID:$uid:1\""* || "$probe" != *"\"map:$GUEST_ID:$gid:1\""* \
                          || "$probe" != *"\"squash-guest:0:$uid:1\""* || "$probe" != *"\"squash-guest:0:$gid:1\""* ]]; then
                        problems+=("the running virtiofsd for $SHARE_DIR does not map guest $GUEST_ID to $uid:$gid (cold restart: $COLD_RESTART)")
                    fi
                    probe=""
                fi
            else
                problems+=("cannot render the expected share (account or domain absent)")
            fi
            # Observed, not inferred: uid 1000 (and the invoking user) really try to list and create.
            if [[ -d "$(p "$SHARE_DIR")" ]]; then
                local uids=(--uid "$GUEST_ID")
                [[ "$USER_UID" != "$GUEST_ID" ]] && uids+=(--uid "$USER_UID")
                local probe_code=0
                probe="$(anjvm share-probe "$(p "$SHARE_DIR")" "${uids[@]}" 2>&1)" || probe_code=$?
                case "$probe_code" in
                    0) ;;
                    1) problems+=("The VM host uid can reach the share: $probe") ;;
                    *) problems+=("the uid probe did not run (not proof of denial): $probe") ;;
                esac
            fi
            if (( ${#problems[@]} )); then record 4 fail "" "" "$(IFS=';'; echo "${problems[*]}")"
            else record 4 pass "" "" "mounted; $SHARE_DIR owned by $SHARE_ACCOUNT ($uid:$gid) 0700; definition and running domain use $WRAPPER; running virtiofsd maps guest 1000 to $uid:$gid; the VM host uid access $probe"; fi
            ;;
        rollback)
            change_try systemctl disable "$MOUNT_UNIT" || true
            remove_step_files 4
            change systemctl daemon-reload
            record 4 rolled-back "" "" "unit removed; the drive stays mounted until reboot; $SHARE_DIR and the account $SHARE_ACCOUNT are kept (data)"
            ;;
    esac
}

render_nft() {
    cat <<EOF
# anj-cloud (spec #21 step 5): 443 on the VM host's LAN address to the production VM, client source kept.
# Only this table is loaded and replaced; the ruleset is never flushed. Mode: $NET_MODE.
table ip anj_cloud_fwd
delete table ip anj_cloud_fwd
table ip anj_cloud_fwd {
	chain prerouting {
		type nat hook prerouting priority dstnat; policy accept;
		iifname "$IFACE" ip daddr $LAN_ADDR tcp dport 443 counter dnat to 10.77.10.10:443
	}
	chain output {
		type nat hook output priority -100; policy accept;
		ip daddr $LAN_ADDR tcp dport 443 counter dnat to 10.77.10.10:443
	}
EOF
    if [[ "$NET_MODE" == open ]]; then
        cat <<'EOF'
	chain postrouting {
		type nat hook postrouting priority srcnat; policy accept;
		ip saddr 10.77.10.0/24 ip daddr != 10.77.10.0/24 counter masquerade
	}
EOF
    fi
    printf '}\n'
}

ufw_vm_rules() {
    # Routed rules for anj-prod. A planner rule with the same tuple is renamed in place by ufw when
    # the script's rule is added (ufw replaces a rule that differs only in its comment), so its
    # position, and therefore the deny-above-egress order, is kept and nothing is ever missing.
    ufw_has "$VM_COMMENT inbound 443" || change ufw route allow in on "$IFACE" out on virbr-anjprod to 10.77.10.10 port 443 proto tcp comment "$VM_COMMENT inbound 443"
    ufw_has "$VM_COMMENT router dns" || change ufw route prepend allow in on virbr-anjprod out on "$IFACE" from 10.77.10.0/24 to "$ROUTER" port 53 comment "$VM_COMMENT router dns"
    local priv
    for priv in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
        ufw_has "$VM_COMMENT no LAN $priv" || change ufw route deny in on virbr-anjprod out on "$IFACE" from 10.77.10.0/24 to "$priv" comment "$VM_COMMENT no LAN $priv"
    done
    ufw_has "$VM_COMMENT egress" || change ufw route allow in on virbr-anjprod out on "$IFACE" from 10.77.10.0/24 comment "$VM_COMMENT egress"
    # If an egress allow still sits above a LAN deny (an unusual earlier state), move it below:
    # out (failing closed), then appended after the denies; restored the same way on abort.
    if [[ -n "$(ufw_order_problems | grep -F ' above a LAN deny on virbr-anjprod' || true)" ]]; then
        local args=(route allow in on virbr-anjprod out on "$IFACE" from 10.77.10.0/24)
        restore_push append "$VM_COMMENT egress" "${args[@]}"
        ufw_delete_comment "$VM_COMMENT egress"
        ufw_delete_comment "anj-prod outbound NAT"
        change ufw "${args[@]}" comment "$VM_COMMENT egress"
        restore_pop "$VM_COMMENT egress"
    fi
    check_ufw_order "the anj-prod route rules"
}

step_5() {
    local phase="$1"
    case "$phase" in
        plan|apply)
            if (( AGENT )); then
                list_planner_rules "${PLANNER_ROUTE[@]}"   # listed only; the agent changes nothing
                record 5 skipped "" "" "nft and ufw need sudo"; return 0
            fi
            WANT_CHANGED=0
            render_nft > "$WORK/fwd.nft"
            if ! nft -c -f "$WORK/fwd.nft" > "$WORK/nft-check.txt" 2>&1; then
                record 5 fail "" "" "nft -c rejected the table: $(head -c 300 "$WORK/nft-check.txt")"; STOPPED=5; return 1
            fi
            want_file 5 "$NFT_FILE" 644 < "$WORK/fwd.nft"
            want_file 5 "$UNIT_DIR/anj-cloud-forward.service" 644 < "$HERE/units/anj-cloud-forward.service"
            if [[ "$phase" == apply ]] && (( WANT_CHANGED )) && ! units_verify anj-cloud-forward.service; then
                remove_step_files 5; record 5 fail "" "" "unit verification failed"; STOPPED=5; return 1
            fi
            local changed=$WANT_CHANGED
            (( changed )) && change systemctl daemon-reload
            # The planner's route rules are adopted here, where their equivalents are added (in place).
            list_planner_rules "${PLANNER_ROUTE[@]}"
            ufw_vm_rules
            if [[ -e "$(p "$FORWARD_OFF")" ]]; then
                record 5 info "" "" "forward is off (emergency stop); --forward on re-enables"
                return 0
            fi
            [[ "$(systemctl is-enabled anj-cloud-forward.service 2>/dev/null || true)" == enabled ]] || change systemctl enable anj-cloud-forward.service
            if (( changed )) || ! nft list table ip anj_cloud_fwd > /dev/null 2>&1; then change systemctl restart anj-cloud-forward.service; fi
            record 5 "$([[ "$phase" == plan ]] && echo planned || echo pass)" "" "" "DNAT $LAN_ADDR:443 -> 10.77.10.10:443 ($NET_MODE mode)"
            ;;
        verify)
            if (( AGENT )); then record 5 skipped "" "" "nft and ufw need sudo"; return 0; fi
            local problems=()
            nft list table ip anj_cloud_fwd > /dev/null 2>&1 || problems+=("table ip anj_cloud_fwd missing")
            ufw_has "$VM_COMMENT inbound 443" || problems+=("ufw route rule missing")
            local probe="not run (harness)"
            if [[ -z "$R" ]]; then
                probe="$(timeout 10 bash -c "exec 3<>/dev/tcp/$LAN_ADDR/443" 2>/dev/null && echo open || echo closed)"
            fi
            if (( ${#problems[@]} )); then record 5 fail "" "" "$(IFS=';'; echo "${problems[*]}")"
            else record 5 pass "" "" "table and route rules present; host-local TCP probe to $LAN_ADDR:443: $probe"; fi
            ;;
        rollback)
            change_try systemctl disable --now anj-cloud-forward.service || true
            nft list table ip anj_cloud_fwd > /dev/null 2>&1 && change nft delete table ip anj_cloud_fwd
            ufw_delete_comment "$VM_COMMENT inbound 443"
            ufw_delete_comment "$VM_COMMENT router dns"
            ufw_delete_comment "$VM_COMMENT no host"
            ufw_delete_comment "$VM_COMMENT no LAN" prefix
            ufw_delete_comment "$VM_COMMENT egress"
            # The emergency-stop flag is the operator's control: rollback never removes it.
            manifest_drop 5 file "$FORWARD_OFF"
            remove_step_files 5
            change systemctl daemon-reload
            record 5 rolled-back "" "" "forward table and anj-cloud-vm route rules removed; bridge DHCP/DNS rules kept (step 2)"
            ;;
    esac
}

install_routines() {
    local step="$1" name
    for name in "${ROUTINES[@]}"; do want_file "$step" "$LIB_DIR/$name" 755 < "$HERE/$name"; done
    for name in anj-prod.xml anj-prod-net.xml; do want_file "$step" "$LIB_DIR/libvirt/$name" 644 < "$HERE/libvirt/$name"; done
    python3 -I - "$PROD_HOSTNAME" "$LAN_ADDR" "$NET_MODE" "${KEYS[@]}" > "$WORK/config.json" <<'PY'
import json, sys
host, lan, mode, *keys = sys.argv[1:]
print(json.dumps({"domain": "anj-prod", "host": host, "lan_addr": lan, "net_mode": mode,
                  "backup_mount": "/mnt/anj-backup", "seed_keys": keys}, indent=1, sort_keys=True))
PY
    want_file "$step" "$HOST_CONFIG" 644 < "$WORK/config.json"
}

unit_files() {
    local step="$1" unit
    shift
    for unit in "$@"; do want_file "$step" "$UNIT_DIR/$unit" 644 < "$HERE/units/$unit"; done
}

step_6() {
    local phase="$1" units=(anj-cloud-vm.service anj-cloud-vm-stop.service)
    case "$phase" in
        plan|apply)
            WANT_CHANGED=0
            install_routines 6
            unit_files 6 "${units[@]}"
            if [[ "$phase" == apply ]] && (( WANT_CHANGED )) && ! units_verify "${units[@]}"; then
                remove_step_files 6; record 6 fail "" "" "unit verification failed"; STOPPED=6; return 1
            fi
            (( WANT_CHANGED )) && change systemctl daemon-reload
            has 'Autostart:.*disable' V dominfo "$PROD" || change V autostart --disable "$PROD"
            local unit
            for unit in "${units[@]}"; do
                [[ "$(systemctl is-enabled "$unit" 2>/dev/null || true)" == enabled ]] || change systemctl enable "$unit"
                [[ "$(systemctl is-active "$unit" 2>/dev/null || true)" == active ]] || change systemctl start "$unit"
            done
            record 6 "$([[ "$phase" == plan ]] && echo planned || echo pass)" "" "" "libvirt autostart off; anj-cloud-vm and -vm-stop enabled"
            ;;
        verify)
            local problems=() unit
            for unit in "${units[@]}"; do
                [[ "$(systemctl is-enabled "$unit" 2>/dev/null || true)" == enabled ]] || problems+=("$unit not enabled")
            done
            has 'Autostart:.*disable' V dominfo "$PROD" || problems+=("libvirt autostart is on")
            [[ "$(V domstate "$PROD" 2>/dev/null)" == running ]] || problems+=("VM not running")
            if (( ${#problems[@]} )); then record 6 fail "" "" "$(IFS=';'; echo "${problems[*]}")"
            else record 6 pass "" "" "units enabled; autostart off; VM running"; fi
            ;;
        rollback)
            change_try systemctl disable anj-cloud-vm.service anj-cloud-vm-stop.service || true
            remove_step_files 6
            change systemctl daemon-reload
            record 6 rolled-back "" "" "units removed; the VM is left running; libvirt autostart stays off"
            ;;
    esac
}

step_7() {
    local phase="$1" line hosts
    hosts="$(p /etc/hosts)"
    line="$LAN_ADDR $PROD_HOSTNAME $HOSTS_MARK"
    case "$phase" in
        plan|apply)
            if grep -qxF "$line" "$hosts"; then manifest_add 7 hosts "$line"; record 7 compliant "" "" "$line"; return 0; fi
            local others
            others="$(grep -vxF "$line" "$hosts" | sed 's/#.*//' || true)"
            if grep -qwF -- "$PROD_HOSTNAME" <<<"$others"; then
                record 7 refused "" "" "/etc/hosts already maps $PROD_HOSTNAME elsewhere"; STOPPED=7; return 1
            fi
            if [[ "$phase" == plan ]]; then log "    would append to /etc/hosts: $line"; record 7 planned "" "$line"; return 0; fi
            if [[ -n "$(tail -c1 "$hosts")" ]]; then printf '\n' >> "$hosts" || abort "cannot write /etc/hosts"; fi
            printf '%s\n' "$line" >> "$hosts" || abort "cannot write /etc/hosts"
            manifest_add 7 hosts "$line"
            record 7 changed "" "$line"
            ;;
        verify)
            local resolved
            if [[ -n "$R" ]]; then resolved="$(awk -v h="$PROD_HOSTNAME" '$2==h {print $1; exit}' "$hosts")"
            else resolved="$(getent ahostsv4 "$PROD_HOSTNAME" | awk 'NR==1 {print $1}' || true)"; fi
            if [[ "$resolved" == "$LAN_ADDR" ]]; then record 7 pass "" "" "$PROD_HOSTNAME -> $LAN_ADDR"
            else record 7 fail "" "" "$PROD_HOSTNAME -> ${resolved:-unresolved}"; fi
            ;;
        rollback)
            while IFS= read -r line; do
                [[ -n "$line" ]] || continue
                if grep -qxF "$line" "$hosts"; then
                    if is_apply; then grep -vxF "$line" "$hosts" > "$WORK/hosts" || true
                        cat "$WORK/hosts" > "$hosts" || abort "cannot rewrite /etc/hosts"
                        log "    removed from /etc/hosts: $line"
                    else log "    would remove from /etc/hosts: $line"; fi
                fi
                manifest_drop 7 hosts "$line"
            done < <(manifest_list 7 hosts)
            record 7 rolled-back
            ;;
    esac
}

ensure_topic() {
    # The topic is asked with hidden input and written root-only; never printed or logged.
    local target topic
    target="$(p "$TOPIC_FILE")"
    if [[ -f "$target" ]]; then log "    ntfy topic file present (root-only)"; return 0; fi
    if ! is_apply; then log "    would ask for the ntfy topic (hidden) and write $TOPIC_FILE (0600 root)"; return 0; fi
    printf 'ntfy topic for the VM host alerts (same as the VM; input hidden): ' > /dev/stderr
    if [[ -n "$R" && -n "${ANJ_HOST_TOPIC_INPUT:-}" ]]; then topic="$(cat "$ANJ_HOST_TOPIC_INPUT")"
    else IFS= read -rs topic < /dev/tty || topic=""; fi
    printf '\n' > /dev/stderr
    [[ "$topic" =~ ^[A-Za-z0-9_-]{24,64}$ ]] || { log "    the topic must be 24-64 letters, digits, '-' or '_'"; return 1; }
    mkdir -p "$(p "$CONF_DIR")" || abort "cannot create $CONF_DIR"
    ( umask 077; printf '%s\n' "$topic" > "$target" ) || abort "cannot write $TOPIC_FILE"
    chmod 0600 "$target" || abort "cannot set the mode of $TOPIC_FILE"
    [[ -s "$target" ]] || abort "the ntfy topic file is empty after writing"
    manifest_add 8 file "$TOPIC_FILE"
    log "    wrote $TOPIC_FILE (0600 root)"
}

render_sudoers() {
    # Only the operator user who ran --apply may run exactly the VM host alert dispatcher as root, with any
    # arguments (golive.py's emergency-stop fallback, #37 ruling); nothing else.
    [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || abort "unexpected user name for sudoers: $USER_NAME"
    printf '# anj-cloud (spec #21 Host Checks 1): %s may run only the VM host alert dispatcher as root.\n' "$USER_NAME"
    printf 'Defaults!%s env_reset\n' "$LIB_DIR/anj-alert"
    printf '%s ALL=(root) NOPASSWD: %s\n' "$USER_NAME" "$LIB_DIR/anj-alert"
}

step_8() {
    local phase="$1" units=(anj-cloud-host-check.service anj-cloud-host-boot.service anj-cloud-host-boot.timer
                            anj-cloud-host-watchdog.service anj-cloud-host-watchdog.timer)
    case "$phase" in
        plan|apply)
            WANT_CHANGED=0
            install_routines 8
            unit_files 8 "${units[@]}"
            want_file 8 "$PACMAN_HOOK" 644 < "$HERE/units/zz-anj-cloud-host-check.hook"
            render_sudoers > "$WORK/sudoers"
            if ! visudo -cqf "$WORK/sudoers" > /dev/null 2>&1; then
                record 8 fail "" "" "visudo rejected the alert sudoers rule; nothing installed"; STOPPED=8; return 1
            fi
            want_file 8 "$SUDOERS_ALERT" 440 < "$WORK/sudoers"
            if [[ "$phase" == apply ]] && (( WANT_CHANGED )) && ! units_verify "${units[@]}"; then
                remove_step_files 8; record 8 fail "" "" "unit verification failed"; STOPPED=8; return 1
            fi
            ensure_topic || { record 8 fail "" "" "no valid ntfy topic"; STOPPED=8; return 1; }
            (( WANT_CHANGED )) && change systemctl daemon-reload
            # The boot timer is enabled, not started: started late, OnBootSec would fire at once.
            [[ "$(systemctl is-enabled anj-cloud-host-boot.timer 2>/dev/null || true)" == enabled ]] || change systemctl enable anj-cloud-host-boot.timer
            [[ "$(systemctl is-active anj-cloud-host-watchdog.timer 2>/dev/null || true)" == active ]] || change systemctl enable --now anj-cloud-host-watchdog.timer
            record 8 "$([[ "$phase" == plan ]] && echo planned || echo pass)" "" "" "host check, boot check, watchdog, pacman hook, dispatcher"
            ;;
        verify)
            local problems=()
            units_verify "${units[@]}" > /dev/null 2>&1 || problems+=("systemd-analyze verify failed")
            [[ "$(systemctl is-enabled anj-cloud-host-boot.timer 2>/dev/null || true)" == enabled ]] || problems+=("boot timer not enabled")
            [[ "$(systemctl is-active anj-cloud-host-watchdog.timer 2>/dev/null || true)" == active ]] || problems+=("watchdog timer inactive")
            grep -q 'When = PostTransaction' "$(p "$PACMAN_HOOK")" 2>/dev/null || problems+=("pacman hook missing")
            render_sudoers > "$WORK/sudoers"
            if (( ! AGENT )); then
                cmp -s "$WORK/sudoers" "$(p "$SUDOERS_ALERT")" || problems+=("alert sudoers rule missing or changed")
                visudo -cqf "$(p "$SUDOERS_ALERT")" > /dev/null 2>&1 || problems+=("alert sudoers rule does not validate")
                # sudo itself must honour the drop-in (@includedir active): list the exact command.
                sudo -n -l -U "$USER_NAME" "$LIB_DIR/anj-alert" > /dev/null 2>&1 \
                    || problems+=("sudo does not grant $USER_NAME the alert dispatcher (is /etc/sudoers.d included?)")
            fi
            local owner=root
            (( FAKE_ROOT )) && owner="$(id -un)"
            if (( ! AGENT )) && [[ "$(stat -c '%U %a' "$(p "$TOPIC_FILE")" 2>/dev/null)" != "$owner 600" ]]; then problems+=("topic file not 0600 root"); fi
            if (( ${#problems[@]} )); then record 8 fail "" "" "$(IFS=';'; echo "${problems[*]}")"
            else record 8 pass "" "" "units verified; timers enabled; hook present; topic root-only; alert sudoers rule valid"; fi
            ;;
        rollback)
            change_try systemctl disable --now anj-cloud-host-watchdog.timer anj-cloud-host-boot.timer || true
            remove_step_files 8
            change systemctl daemon-reload
            record 8 rolled-back
            ;;
    esac
}

step_9() {
    # ufw rules for the qualification bridge: DHCP/DNS to the host, internet egress, no LAN.
    local phase="$1" priv
    case "$phase" in
        plan|apply)
            if (( AGENT )); then record 9 skipped "" "" "ufw needs sudo"; return 0; fi
            ufw_bridge_input virbr-anjqual 10.77.11 "$QUAL_COMMENT"
            for priv in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
                ufw_has "$QUAL_COMMENT no LAN $priv" || change ufw route deny in on virbr-anjqual out on "$IFACE" from 10.77.11.0/24 to "$priv" comment "$QUAL_COMMENT no LAN $priv"
            done
            ufw_has "$QUAL_COMMENT egress" || change ufw route allow in on virbr-anjqual out on "$IFACE" from 10.77.11.0/24 comment "$QUAL_COMMENT egress"
            manifest_add 9 ufw "$QUAL_COMMENT"
            record 9 "$([[ "$phase" == plan ]] && echo planned || echo pass)" "" "" "anj-qual bridge: only DHCP and DNS to 10.77.11.1 reach the VM host; internet egress; LAN denied"
            ;;
        verify)
            if (( AGENT )); then
                if grep -q "$(printf '%s' "$QUAL_COMMENT egress" | od -An -tx1 | tr -d ' \n')" "$(p /etc/ufw/user.rules)" 2>/dev/null; then
                    record 9 pass "" "" "anj-cloud-qual rules present (user.rules)"
                else record 9 fail "" "" "anj-cloud-qual rules absent"; fi
                return 0
            fi
            if ufw_has "$QUAL_COMMENT egress" && ufw_has "$QUAL_COMMENT dhcp"; then record 9 pass "" "" "rules present"
            else record 9 fail "" "" "anj-cloud-qual rules absent"; fi
            ;;
        rollback)
            ufw_delete_comment "$QUAL_COMMENT" prefix
            manifest_drop 9 ufw "$QUAL_COMMENT"
            record 9 rolled-back
            ;;
    esac
}

run_step() {
    local step="$1" phase="$2"
    CURRENT_STEP="$step"
    log "-- step $step ${STEP_NAMES[$step]} ($phase)"
    "step_$step" "$phase"
}

# ---------------------------------------------------------------------------------------------
# Modes

selected_steps() {
    if [[ -n "$ONLY" ]]; then step_number "$ONLY"; printf '\n'; return; fi
    seq 1 8
}

mode_dry_run() {
    capture_reads
    log "== others-untouched snapshot"
    snapshot_others "$EVID/others-before.txt"
    log "  $(grep -c . "$EVID/others-before.txt") items recorded"
    log "== plan"
    local step
    for step in $(selected_steps); do run_step "$step" plan || true; STOPPED=""; done
    log "dry run complete: nothing was changed"
}

apply_start() {
    capture_reads
    log "== others-untouched snapshot (start)"
    snapshot_others "$EVID/others-before.txt"
    mkdir -p "$(p "$VAR_DIR")" || abort "cannot create $VAR_DIR"
    cp "$EVID/others-before.txt" "$(p "$OTHERS_BASELINE")" || abort "cannot write $OTHERS_BASELINE"
    chmod 0644 "$(p "$OTHERS_BASELINE")"
    APPLY_STARTED=1
}

apply_end() {
    APPLY_STARTED=0
    log "== others-untouched comparison (start vs end)"
    snapshot_others "$EVID/others-after.txt"
    compare_others "$EVID/others-before.txt" "$EVID/others-after.txt" | tee -a "$EVID/run.log" || FAILED=1
}

mode_apply() {
    local step
    apply_start
    for step in $(selected_steps); do
        if ! run_step "$step" apply; then
            STOPPED="${STOPPED:-$step}"
            log "STOPPED at step $STOPPED; completed: ${COMPLETED[*]:-none}. Fix and re-run --apply; completed steps report compliant."
            break
        fi
        COMPLETED+=("$step")
    done
    apply_end
    [[ -z "$STOPPED" ]] || return 1
}

mode_verify() {
    local step baseline
    capture_reads
    for step in $(selected_steps); do run_step "$step" verify || true; done
    log "== others-untouched comparison"
    snapshot_others "$EVID/others-after.txt"
    baseline="$(p "$OTHERS_BASELINE")"
    if [[ -r "$baseline" ]]; then
        cp "$baseline" "$EVID/others-before.txt"
        compare_others "$baseline" "$EVID/others-after.txt" | tee -a "$EVID/run.log" || FAILED=1
    else
        log "  no apply snapshot at $OTHERS_BASELINE; recorded the current state only"
    fi
}

mode_rollback() {
    local step
    step="$(step_number "$ROLLBACK_STEP")" || die "unknown step '$ROLLBACK_STEP'"
    ask "Roll back step $step (${STEP_NAMES[$step]})?" || die "not confirmed"
    run_step "$step" rollback
}

delete_prod_objects() {
    # Only anj-prod's own domain and its three volumes; never other volumes in any pool.
    local vol
    if [[ "$(V domstate "$PROD" 2>/dev/null)" == running ]]; then
        change_try V shutdown "$PROD" || true
        local waited=0
        while is_apply && [[ "$(V domstate "$PROD" 2>/dev/null)" == running ]] && (( waited < 120 )); do sleep 2; waited=$((waited + 2)); done
        [[ "$(V domstate "$PROD" 2>/dev/null)" == running ]] && change V destroy "$PROD"
    fi
    V dominfo "$PROD" > /dev/null 2>&1 && change V undefine "$PROD" --nvram
    for vol in "$PROD-os.qcow2" "$PROD-data.qcow2" "$PROD-seed.iso"; do
        vol_exists "$PROD" "$vol" && change V vol-delete --pool "$PROD" "$vol"
    done
    if V net-info "$PROD" > /dev/null 2>&1; then
        anjvm render-net "$PROD" --mode "$NET_MODE" > "$WORK/net.xml"
        V net-dumpxml --inactive "$PROD" > "$WORK/net-live.xml"
        if ! anjvm compare-net "$WORK/net.xml" "$WORK/net-live.xml" > /dev/null; then
            change_try V net-destroy "$PROD" || true
            change V net-undefine "$PROD"
        fi
    fi
}

recreate_cleanup() {
    # A failed rebuild leaves no half-made anj-prod: undefine the new domain, delete the new volumes.
    log "== recreate failed after the old $PROD was removed: cleaning up the partial rebuild"
    V dominfo "$PROD" > /dev/null 2>&1 && { change_try V destroy "$PROD" || true; change_try V undefine "$PROD" --nvram || true; }
    local vol
    for vol in "$PROD-os.qcow2" "$PROD-data.qcow2" "$PROD-seed.iso"; do
        vol_exists "$PROD" "$vol" && { change_try V vol-delete --pool "$PROD" "$vol" || true; }
    done
    record 3 info "" "" "partial rebuild removed; re-run --recreate --confirm $PROD after fixing the cause"
}

mode_recreate() {
    [[ "$CONFIRM" == "$PROD" ]] || die "--recreate replaces $PROD and BOTH disks; pass --confirm $PROD"
    ask "Replace $PROD: its domain, OS disk and DATA disk are deleted and rebuilt from the template. Continue?" || die "not confirmed"
    apply_start
    run_step 1 apply || { apply_end; return 1; }
    log "== removing $PROD (domain, os, data, seed; network only if it differs)"
    CURRENT_STEP=3
    delete_prod_objects
    record 3 info "" "" "old $PROD domain and disks removed"
    RECREATE_BUILDING=1
    local step
    for step in 2 3; do run_step "$step" apply || { apply_end; return 1; }; COMPLETED+=("$step"); done
    if [[ "$(systemctl is-enabled anj-cloud-vm.service 2>/dev/null || true)" == enabled ]]; then
        change systemctl restart anj-cloud-vm.service
    else
        change V start "$PROD"
    fi
    RECREATE_BUILDING=0
    record 3 changed "" "running" "recreated from the templates (decision #89 (7))"
    apply_end
}

mode_recreate_os() {
    ask "Rebuild the $PROD OS disk from the verified image (the data disk is kept)?" || die "not confirmed"
    apply_start
    run_step 1 apply || { apply_end; return 1; }
    CURRENT_STEP=3
    if [[ "$(V domstate "$PROD" 2>/dev/null)" == running ]]; then
        change V shutdown "$PROD"
        local waited=0
        while is_apply && [[ "$(V domstate "$PROD" 2>/dev/null)" == running ]] && (( waited < 120 )); do sleep 2; waited=$((waited + 2)); done
        [[ "$(V domstate "$PROD" 2>/dev/null)" == running ]] && { record 3 fail "" "" "guest did not shut down"; apply_end; return 1; }
    fi
    vol_exists "$PROD" "$PROD-os.qcow2" && change V vol-delete --pool "$PROD" "$PROD-os.qcow2"
    make_volumes "$PROD" 1
    if [[ "$(systemctl is-enabled anj-cloud-vm.service 2>/dev/null || true)" == enabled ]]; then change systemctl restart anj-cloud-vm.service
    else change V start "$PROD"; fi
    record 3 changed "" "" "OS disk rebuilt, new seed instance; data disk kept"
    apply_end
}

mode_forward() {
    case "$FORWARD_STATE" in
        off)
            # The flag first: the unit's ConditionPathExists=! then keeps it from starting again,
            # whether by a reboot, anj-cloud-vm.service's Wants= or a stray start.
            CURRENT_STEP=5
            mkdir -p "$(p "$CONF_DIR")" || abort "cannot create $CONF_DIR"
            change touch "$(p "$FORWARD_OFF")"
            change systemctl stop anj-cloud-forward.service
            change systemctl disable anj-cloud-forward.service
            nft list table ip anj_cloud_fwd > /dev/null 2>&1 && change nft delete table ip anj_cloud_fwd
            record 5 changed "on" "off" "443 forward stopped and disabled (emergency stop); only the operator turns it back on"
            ;;
        on)
            CURRENT_STEP=5
            ask "Re-enable public access through the 443 forward?" || die "not confirmed"
            change rm -f "$(p "$FORWARD_OFF")"
            manifest_drop 5 file "$FORWARD_OFF"   # entries written by older versions
            change systemctl enable anj-cloud-forward.service
            change systemctl restart anj-cloud-forward.service
            record 5 changed "off" "on" "443 forward re-enabled and restored"
            ;;
        *) die "--forward on|off" ;;
    esac
}

prod_known_hosts() { printf '%s/.ssh/known_hosts.anj-prod' "$(p "$USER_HOME")"; }
prod_ssh_config() { printf '%s/.local/share/anj-cloud/prod-vm/ssh_config' "$(p "$USER_HOME")"; }
qual_known_hosts() { printf '%s/.ssh/known_hosts.anj-qual' "$(p "$USER_HOME")"; }
qual_tag_file() { printf '%s/.local/state/anj-cloud-qual/run-id' "$(p "$USER_HOME")"; }
qual_ssh_config() { prod_ssh_config; }

write_prod_ssh_config() {
    local phase="$1" file key block address
    file="$(prod_ssh_config)"
    if [[ "$phase" == plan ]]; then log "    would write ssh alias: ssh -F $file anj-prod"; return 0; fi
    key="${KEYS[0]%.pub}"
    address="$(profile_get "$PROD" subnet).10"
    block="$(printf '# >>> anj-prod (halo-vm.sh --apply) >>>\nHost anj-prod\n  HostName %s\n  User anj\n  IdentityFile %s\n  IdentitiesOnly yes\n  UserKnownHostsFile %s\n  StrictHostKeyChecking accept-new\n  ConnectTimeout 5\n  BatchMode yes\n# <<< anj-prod <<<' "$address" "$key" "$(prod_known_hosts)")"
    if [[ -f "$file" ]]; then
        awk '
            /^# >>> anj-prod / { marked=1; next }
            marked {
                if ($0 ~ /^# <<< anj-prod /) marked=0
                next
            }
            { directive=tolower($0) }
            directive ~ /^[[:space:]]*host[[:space:]]+/ {
                stale = directive ~ /^[[:space:]]*host[[:space:]]+anj-prod[[:space:]]*$/
                if (!stale) print
                next
            }
            directive ~ /^[[:space:]]*match[[:space:]]+/ { stale=0; print; next }
            stale && $0 !~ /^[[:space:]]*(#|$)/ { next }
            { print }
        ' "$file" > "$WORK/prod_ssh_config" || abort "cannot read $file"
    else
        : > "$WORK/prod_ssh_config" || abort "cannot prepare $file"
    fi
    printf '%s\n' "$block" >> "$WORK/prod_ssh_config" || abort "cannot prepare $file"
    if [[ -f "$file" ]] && cmp -s "$WORK/prod_ssh_config" "$file"; then
        log "    ssh alias unchanged: ssh -F $file anj-prod"
        return 0
    fi
    as_user mkdir -p "$(dirname "$file")" || abort "cannot create the SSH config directory"
    as_user cp "$WORK/prod_ssh_config" "$file" || abort "cannot write $file"
    log "    ssh alias: ssh -F $file anj-prod"
}

# qual_lock FLOCK-ARGS...: the user-owned lock that serialises --qual and --qual-destroy. --qual
# holds it from the busy check through the tag write and define (to its exit), so of two runs
# exactly one creates anj-qual; the other exits 3 without writing anything.
qual_lock() {
    local dir
    dir="$(dirname "$(qual_tag_file)")"
    mkdir -p "$dir" || return 1
    exec 8>> "$dir/lock"
    flock "$@" 8
}

# listed KIND NAME: "yes" or "no" from a successful listing, "unknown" when the listing failed.
# Absence is inferred only from a listing that succeeded, never from a lookup error (virsh prints
# "failed to get domain" for any lookup failure).
listed() {
    local out
    case "$1" in
        domain) out="$(V list --all --name 2>/dev/null)" || { printf unknown; return; } ;;
        network) out="$(V net-list --all --name 2>/dev/null)" || { printf unknown; return; } ;;
        pool) out="$(V pool-list --all --name 2>/dev/null)" || { printf unknown; return; } ;;
    esac
    if grep -qxF -- "$2" <<<"$out"; then printf yes; else printf no; fi
}

# qual_presence: "absent", "present" or "unknown" for anj-qual's domain, network and pool together.
qual_presence() {
    local kind state any=0
    for kind in domain network pool; do
        state="$(listed "$kind" "$QUAL")"
        [[ "$state" == unknown ]] && { printf unknown; return; }
        [[ "$state" == yes ]] && any=1
    done
    if (( any )); then printf present; else printf absent; fi
}

qual_run_tag() {
    # The run id of the existing anj-qual. When a domain is listed its description is authoritative;
    # the tag file only covers a run that failed before define. Prints "?unknown" when libvirt
    # cannot answer, which callers treat as "not ours".
    local text domain xml
    domain="$(listed domain "$QUAL")"
    case "$domain" in
        unknown) printf '?unknown'; return ;;
        yes)
            xml="$(V dumpxml --inactive "$QUAL" 2>/dev/null)" || { printf '?unknown'; return; }
            text="$(sed -nE 's#.*<description>anj-qual run-id=([^<]*)</description>.*#\1#p' <<<"$xml" || true)"
            ;;
        *) text="$(cat "$(qual_tag_file)" 2>/dev/null || true)" ;;
    esac
    printf '%s' "$text"
}

write_qual_ssh_config() {
    # A Host anj-qual block in the same ssh_config as anj-prod (ssh -F <file> anj-qual).
    local file key block
    file="$(qual_ssh_config)"
    key="${KEYS[0]%.pub}"
    mkdir -p "$(dirname "$file")"
    [[ -f "$file" ]] || : > "$file"
    block="$(printf '# >>> anj-qual (halo-vm.sh --qual) >>>\nHost anj-qual\n  HostName 10.77.11.10\n  User anj\n  IdentityFile %s\n  IdentitiesOnly yes\n  UserKnownHostsFile %s\n  StrictHostKeyChecking accept-new\n  ConnectTimeout 5\n  BatchMode yes\n# <<< anj-qual <<<' "$key" "$(qual_known_hosts)")"
    awk '/^# >>> anj-qual /{skip=1} !skip {print} /^# <<< anj-qual /{skip=0}' "$file" > "$WORK/ssh_config"
    printf '%s\n' "$block" >> "$WORK/ssh_config"
    cat "$WORK/ssh_config" > "$file"
    log "    ssh alias: ssh -F $file anj-qual"
}

in_subids() {
    # in_subids FILE ID: ID lies in one of USER_NAME's ranges in /etc/subuid or /etc/subgid.
    U="$USER_NAME" N="$USER_UID" I="$2" awk -F: '($1==ENVIRON["U"] || $1==ENVIRON["N"]) && NF==3 \
        && ENVIRON["I"] >= $2 && ENVIRON["I"] < $2 + $3 {f=1} END {exit !f}' "$(p "$1")" 2>/dev/null
}

validate_scratch_share() {
    # --scratch-share: an existing directory under ~/.local/share/anj-cloud/qualification/, with no
    # symlink anywhere in the path, under the production ownership model (decision #115): mode 0700,
    # owned by one of your subuids/subgids (anjvm.py scratch-share create DIR) or by anj-cloud-backup,
    # never by you, root or 1000. The guest's anj is mapped to that owner. Anything else exits 2.
    local base real lexical json uid gid
    base="$(realpath -e -- "$(p "$USER_HOME")/.local/share/anj-cloud/qualification" 2>/dev/null)" \
        || die "--scratch-share: ~/.local/share/anj-cloud/qualification does not exist"
    [[ "$QUAL_SHARE" == /* ]] || die "--scratch-share needs an absolute path"
    real="$(realpath -e -- "$QUAL_SHARE" 2>/dev/null)" || die "--scratch-share: $QUAL_SHARE does not exist"
    lexical="$(realpath -s -m -- "$QUAL_SHARE")"
    [[ "$real" == "$lexical" ]] || die "--scratch-share: the path contains a symlink"
    [[ "$real" == "$base"/?* && "$(dirname "$real")" == "$base" ]] || die "--scratch-share must be a directory directly under $base"
    [[ -d "$real" && ! -L "$real" ]] || die "--scratch-share must be a directory"
    json="$(share_check "$real")"
    uid="$(json_get - uid <<<"$json")"; gid="$(json_get - gid <<<"$json")"
    [[ "$(json_get - mode <<<"$json")" == 0700 ]] || die "--scratch-share must be mode 0700 (decision #115)"
    [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || die "--scratch-share: owner unreadable"
    if [[ "$uid" == 0 || "$uid" == "$GUEST_ID" || "$uid" == "$USER_UID" || "$gid" == 0 || "$gid" == "$GUEST_ID" ]]; then
        die "--scratch-share must not be owned by root, 1000 or $USER_NAME (decision #115): create it with deploy/host/anjvm.py scratch-share create DIR"
    fi
    if ! { [[ "$uid:$gid" == "$(json_get - account.uid <<<"$json"):$(json_get - account.gid <<<"$json")" ]] \
           || { in_subids /etc/subuid "$uid" && in_subids /etc/subgid "$gid"; }; }; then
        die "--scratch-share must be owned by one of $USER_NAME's subuids/subgids or by $SHARE_ACCOUNT (got $uid:$gid)"
    fi
    QUAL_SHARE="$real"
}

mode_qual() {
    local problems=() uuid key
    if ! qual_lock -n; then
        record 1 refused "" "" "qual-busy: another --qual or --qual-destroy holds the anj-qual lock"
        return 3
    fi
    capture_reads
    log "== preflight (anj-qual)"
    case "$(qual_presence)" in
        absent) ;;
        present)
            # One qualification VM at a time; nothing is touched.
            record 1 refused "" "" "qual-busy: $QUAL exists (run-id $(qual_run_tag)); one qualification VM at a time"
            return 3 ;;
        *)
            record 1 refused "" "" "qual-unknown: libvirt could not list domains, networks or pools; nothing touched"
            return 3 ;;
    esac
    headroom_ok "$QUAL" "$QUAL_HEADROOM" || problems+=("machine.slice headroom below 5 GiB (#89 (6))")
    threads_free || problems+=("threads 14,30,15,31 pinned by a non-anj domain")
    subnet_free 10.77.11 virbr-anjqual || problems+=("10.77.11.0/24 in use")
    image_verified || problems+=("Debian image not verified")
    for key in "${KEYS[@]}"; do [[ -r "$key" ]] || problems+=("SSH key $key unreadable"); done
    if [[ -n "$QUAL_SHARE" ]] && ! wrapper_current; then
        problems+=("the share needs $WRAPPER (and its anjvm.py) installed and equal to this checkout: sudo deploy/host/halo-vm.sh --apply (operator, decision #115)")
    fi
    if (( QUAL_SHARE_RO )); then
        if [[ ! -d "$(p "$QUAL_SHARE")" ]]; then problems+=("--share-readonly needs DOS_BACKUP mounted with $SHARE_DIR")
        elif ! share_ok "$(p "$SHARE_DIR")"; then problems+=("--share-readonly needs $SHARE_DIR owned by $SHARE_ACCOUNT, 0700 (halo-vm.sh --apply, decision #115)"); fi
    fi
    if (( ${#problems[@]} )); then record 1 refused "" "" "$(IFS=';'; echo "${problems[*]}")"; return 1; fi
    record 1 pass "" "" "headroom, threads, subnet, image and keys OK"
    log "== create anj-qual (run-id $RUN_ID)"
    printf '%s\n' "$RUN_ID" > "$(qual_tag_file)" || abort "cannot write the run-id tag"
    anjvm render-net "$QUAL" > "$WORK/net.xml"
    change V net-define "$WORK/net.xml"
    change V net-start "$QUAL"
    ensure_pool "$QUAL"
    make_volumes "$QUAL"
    uuid="$(new_uuid)"
    render_domain "$QUAL" "$uuid" > "$WORK/dom.xml"
    change V define "$WORK/dom.xml"
    change V start "$QUAL"
    record 3 changed "" "running" "anj-qual run-id ${RUN_ID:-none}: 4 GiB, threads 14,30,15,31, network 10.77.11.0/24, no DNAT/DDNS${QUAL_SHARE:+, share $QUAL_SHARE$( (( QUAL_SHARE_RO )) && echo ' read-only'), guest 1000:1000 mapped to $(share_map "$QUAL" | tr ' ' :)}"
    write_qual_ssh_config
    log "== wait for SSH (up to 300 s)"
    rm -f "$(qual_known_hosts)"
    local deadline=$(( SECONDS + ${ANJ_QUAL_SSH_TIMEOUT:-300} )) ok=0
    local ssh_args=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$(qual_known_hosts)")
    [[ -r "${KEYS[0]%.pub}" ]] && ssh_args+=(-i "${KEYS[0]%.pub}" -o IdentitiesOnly=yes)
    while (( SECONDS < deadline )); do
        if ssh "${ssh_args[@]}" anj@10.77.11.10 true 2> /dev/null; then ok=1; break; fi
        sleep 5
    done
    if (( ! ok )); then record 3 fail "" "" "no SSH on 10.77.11.10 within the timeout"; return 1; fi
    # shellcheck disable=SC2016  # expanded by the guest shell
    read_raw qual-guest ssh "${ssh_args[@]}" anj@10.77.11.10 \
        'timeout 180 cloud-init status --wait >/dev/null 2>&1; cloud-init status; . /etc/os-release; echo "$PRETTY_NAME"; uname -r; nproc; free -m | awk "/Mem:/ {print \$2}"; sudo -n true && echo sudo-ok; ls /sys/firmware/efi >/dev/null && echo uefi' > /dev/null
    read_raw qual-vcpupin V vcpupin "$QUAL" > /dev/null
    read_raw qual-emulatorpin V emulatorpin "$QUAL" > /dev/null
    read_raw qual-dominfo V dominfo "$QUAL" > /dev/null
    read_raw qual-headroom anjvm headroom > /dev/null
    record 3 pass "" "" "SSH as anj ok; guest: $(tr '\n' ' ' < "$EVID/raw/qual-guest.txt")"
    log "anj-qual is up: ssh -F $(qual_ssh_config) anj-qual"
    log "destroy it after the run: deploy/host/halo-vm.sh --qual-destroy --run-id $RUN_ID"
}

mode_qual_destroy() {
    # Only the run that owns anj-qual (matching --run-id) or an operator (--force) destroys it.
    # Every step is attempted even if an earlier one fails; the result is judged on what remains.
    local vol remaining=() tag exists=0
    if ! qual_lock -w 900; then
        record 3 refused "" "" "qual-busy: the anj-qual lock is held"
        return 3
    fi
    case "$(qual_presence)" in
        present) exists=1 ;;
        absent) exists=0 ;;
        *)
            record 3 refused "" "" "qual-unknown: libvirt could not list anj-qual objects; nothing destroyed"
            return 3 ;;
    esac
    tag="$(qual_run_tag)"
    if [[ "$tag" == "?unknown" ]]; then
        record 3 refused "" "" "qual-unknown: the owner of anj-qual cannot be read; nothing destroyed"
        return 3
    fi
    if (( exists && ! FORCE )); then
        if [[ -z "$tag" || "$tag" == none ]]; then
            record 3 refused "" "" "qual-untagged: anj-qual carries no run id; use --force for operator cleanup"
            return 3
        elif [[ "$tag" != "$RUN_ID" ]]; then
            record 3 refused "" "" "qual-tag-mismatch: anj-qual belongs to run-id $tag (got ${RUN_ID:-none}); use --force for operator cleanup"
            return 3
        fi
    fi
    if V dominfo "$QUAL" > /dev/null 2>&1; then
        [[ "$(V domstate "$QUAL" 2>/dev/null)" == running ]] && { change_try V destroy "$QUAL" || true; }
        change_try V undefine "$QUAL" --nvram || true
    fi
    if V pool-info "$QUAL" > /dev/null 2>&1; then
        has 'State:.*running' V pool-info "$QUAL" || change_try V pool-start "$QUAL" || true
        while IFS= read -r vol; do
            [[ -n "$vol" ]] && { change_try V vol-delete --pool "$QUAL" "$vol" || true; }
        done < <(V vol-list "$QUAL" 2>/dev/null | awk 'NF >= 2 && $1 != "Name" && $1 !~ /^-+$/ {print $1}')
        change_try V pool-destroy "$QUAL" || true
        change_try V pool-delete "$QUAL" || true
        change_try V pool-undefine "$QUAL" || true
    fi
    if V net-info "$QUAL" > /dev/null 2>&1; then
        has 'Active:.*yes' V net-info "$QUAL" && { change_try V net-destroy "$QUAL" || true; }
        change_try V net-undefine "$QUAL" || true
    fi
    rm -f "$(qual_known_hosts)" "$(qual_tag_file)"
    V dominfo "$QUAL" > /dev/null 2>&1 && remaining+=("domain")
    V net-info "$QUAL" > /dev/null 2>&1 && remaining+=("network")
    V pool-info "$QUAL" > /dev/null 2>&1 && remaining+=("pool")
    [[ -d "$(p /var/lib/libvirt/images/anj-qual)" ]] && remaining+=("image directory")
    read_raw qual-headroom-after anjvm headroom > /dev/null
    if (( ${#remaining[@]} )); then record 3 fail "" "" "left behind: ${remaining[*]}"
    else record 3 pass "" "" "no anj-qual domain, disk, pool or network remains"; fi
}

main() {
    while (( $# )); do
        case "$1" in
            --dry-run) MODE="dry-run"; MODE_COUNT=$((MODE_COUNT + 1)) ;;
            --apply) MODE="apply"; MODE_COUNT=$((MODE_COUNT + 1)) ;;
            --verify) MODE="verify"; MODE_COUNT=$((MODE_COUNT + 1)) ;;
            --rollback) MODE="rollback"; MODE_COUNT=$((MODE_COUNT + 1)); ROLLBACK_STEP="${2:-}"; shift || true ;;
            --recreate) MODE="recreate"; MODE_COUNT=$((MODE_COUNT + 1)) ;;
            --recreate-os) MODE="recreate-os"; MODE_COUNT=$((MODE_COUNT + 1)) ;;
            --confirm) CONFIRM="${2:-}"; shift || true ;;
            --forward) MODE="forward"; MODE_COUNT=$((MODE_COUNT + 1)); FORWARD_STATE="${2:-}"; shift || true ;;
            --qual) MODE="qual"; MODE_COUNT=$((MODE_COUNT + 1)) ;;
            --qual-destroy) MODE="qual-destroy"; MODE_COUNT=$((MODE_COUNT + 1)) ;;
            --scratch-share) QUAL_SHARE="${2:-}"; QUAL_SHARE_RO=0; shift || true ;;
            --share-readonly) QUAL_SHARE="$SHARE_DIR"; QUAL_SHARE_RO=1 ;;
            --run-id) RUN_ID="${2:-}"; shift || true ;;
            --force) FORCE=1 ;;
            --only) ONLY="${2:-}"; shift || true ;;
            --key) KEYS+=("${2:-}"); shift || true ;;
            --image) IMAGE="${2:-}"; shift || true ;;
            --host) PROD_HOSTNAME="${2:-}"; shift || true ;;
            --net-mode) NET_MODE="${2:-}"; shift || true ;;
            --evidence-dir) EVIDENCE_PARENT="${2:-}"; shift || true ;;
            -h|--help) usage 0 ;;
            *) printf 'unknown argument: %s\n' "$1" >&2; usage 2 ;;
        esac
        shift
    done
    if [[ -n "$ONLY" ]]; then
        step_number "$ONLY" > /dev/null || die "unknown step '$ONLY'"
        [[ "$MODE" =~ ^(dry-run|apply|verify)$ ]] || die "--only combines with --dry-run, --apply or --verify"
    fi
    [[ "$PROD_HOSTNAME" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]] || die "--host must be a DNS name"
    [[ -n "$PROFILE_FILE" || -n "$R" || "$MODE" =~ ^(dry-run|verify)$ ]] || die "no deployment profile found (set ANJ_PROFILE or create ~/.local/share/anj-cloud/profile.toml); only --dry-run and --verify run on placeholders"
    [[ "$MODE" != rollback || -n "$ROLLBACK_STEP" ]] || die "--rollback needs a step"
    (( MODE_COUNT <= 1 )) || die "choose one mode: --dry-run, --apply, --verify, --rollback, --recreate, --recreate-os, --forward, --qual or --qual-destroy"
    [[ -z "$RUN_ID" || "$RUN_ID" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "--run-id: 1-64 letters, digits, '.', '_' or '-'"
    [[ "$MODE" != qual || -n "$RUN_ID" ]] || die "--qual needs --run-id <id> (it tags the VM so only its owner destroys it)"
    [[ -z "$QUAL_SHARE" || "$MODE" == qual ]] || die "--scratch-share and --share-readonly go with --qual"
    guard_test_mode
    preconditions
    [[ "$MODE" != qual || -z "$QUAL_SHARE" ]] || (( QUAL_SHARE_RO )) || validate_scratch_share
    if (( EUID == 0 )) && [[ "$MODE" != dry-run && "$MODE" != verify ]]; then
        # Changing modes only, so a dry run or verify leaves no lock file behind.
        exec 9> /run/anj-cloud-host.lock
        flock -n 9 || die "another halo-vm.sh run holds the lock"
    fi
    setup_evidence
    trap finish EXIT
    # Ctrl-C, a kill or a closed terminal mid-step take the same path as a failed command: record,
    # restore any rule taken out, check the order, exit 1.
    trap 'abort "interrupted by SIGINT"' INT
    trap 'abort "interrupted by SIGTERM"' TERM
    trap 'abort "interrupted by SIGHUP"' HUP
    log "halo-vm.sh --$MODE${ONLY:+ --only $ONLY}${ROLLBACK_STEP:+ $ROLLBACK_STEP} ($( (( AGENT )) && echo 'agent, no sudo' || echo sudo)) user=$USER_NAME net-mode=$NET_MODE"
    case "$MODE" in
        dry-run) mode_dry_run ;;
        apply) mode_apply ;;
        verify) mode_verify ;;
        rollback) mode_rollback ;;
        recreate) mode_recreate ;;
        recreate-os) mode_recreate_os ;;
        forward) mode_forward ;;
        qual) mode_qual ;;
        qual-destroy) mode_qual_destroy ;;
    esac
    (( FAILED == 0 )) || exit 1
}

main "$@"
