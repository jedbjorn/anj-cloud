#!/usr/bin/env bash
# M6 mac-test run list (spec #31 M6, acceptance row 15), driven from the VM host in
# one window of about 20 minutes (decision #121). Run it only when the
# Planner says the mac-test window is open, from apps/client, inside a
# bounded scope:
#
#   systemd-run --user --scope --unit=anj-test-m6-<n> -p MemoryMax=2G -p TasksMax=512 \
#     tool/macos/m6_run.sh [<shell>/<task>]          (default LANE1/m6-1)
#
# Steps (seat-time budget in brackets; the guest has 4 vCPUs):
#  0 owner m6 inventory clean, then send this worktree's client
#    source                                                        [~1 min]
#  1 preflight: no AnJ Cloud running, no cloud.anj LaunchAgent
#    (another lane is live: stop)                                  [<1 min]
#  2 release build, timed, bundle checks, archive and receipt
#    (package_release.sh); a guest-side alarm stops it at 15 min  [8-12 min]
#  3 the hermetic manager tests under macOS /bin/sh and BSD tools [~1 min]
#  4 the guest run list in the GUI session (m6_guest.sh): install from a
#    quarantined zip, update over a running instance, rollback, Start at
#    login through launchd, the embedded manager, uninstall        [~4 min]
#  5 always: fetch evidence, release zip and receipt to the VM host
#    (~/.local/share/anj-cloud/qualification/macos-m6-<commit8>/)  [<1 min]
#  6 always: mac_test.sh clean m6 --reset-bundle-state, then the guest
#    inventory for owner m6 (exit 0) and anj-test-inventory --owner m6 [<1 min]
# Stops at the first failing step (cleanup still runs). Exit 0 = all passed.
set -uo pipefail
cd "$(dirname "$0")/../.."
task=${1:-LANE1/m6-1}
[[ $task =~ ^[A-Za-z0-9_-]+/m6(-[A-Za-z0-9._-]+)?$ ]] || { echo "m6_run.sh: task must be <shell>/m6 or <shell>/m6-<x>" >&2; exit 64; }
mt=tool/macos/mac_test.sh
commit=$(git rev-parse HEAD)
evidence=${M6_EVIDENCE:-$HOME/.local/share/anj-cloud/qualification/macos-m6-${commit:0:8}}
mkdir -p "$evidence"
log="$evidence/run.log"
: > "$log"
t0=$SECONDS
say() { echo "$*" | tee -a "$log"; }
step() { say "== $1 (at $((SECONDS - t0)) s)"; }
failed=0
onboarding_clean=0
finish() {
  step "5 fetch evidence"
  $mt fetch "$task" ev "$evidence" 2>&1 | tee -a "$log"
  say "receipt: $(ls "$evidence"/ev/release/*.receipt.json 2>/dev/null)"
  step "6 cleanup"
  # Spec #31 M8 (#99): a new profile of the installed app makes ~/anj-cloud
  # and ~/Desktop/AnJ Cloud. Remove them only when the preflight saw
  # neither (this run made them), and only the expected kinds: a folder,
  # not a link, and our link. Over SSH, which may touch ~/Desktop.
  if (( onboarding_clean )); then
    $mt run "$task" 'l="$HOME/Desktop/AnJ Cloud"; r="$HOME/anj-cloud"; [[ -L $l && $(readlink "$l") == "$r" ]] && rm -f -- "$l"; [[ -d $r && ! -L $r ]] && rm -rf -- "$r"; if [[ -e $r || -L $r || -L $l ]]; then echo "left: ~/anj-cloud or the Desktop link"; exit 1; fi; echo "removed what the run made: ~/anj-cloud and the Desktop link (none left)"' 2>&1 | tee -a "$log"
    [[ ${PIPESTATUS[0]} == 0 ]] || failed=1
  fi
  $mt clean m6 --reset-bundle-state 2>&1 | tee -a "$log"
  $mt inventory m6 2>&1 | tee "$evidence/guest-inventory.txt" | tee -a "$log"
  inv=${PIPESTATUS[0]}
  ~/.local/share/anj-cloud/bin/anj-test-inventory --owner m6 > "$evidence/halo-inventory.txt" 2>&1
  hinv=$?
  say "guest inventory exit $inv; the VM host anj-test-inventory --owner m6 exit $hinv"
  [[ $inv == 0 && $hinv == 0 ]] || failed=1
  say "m6_run: $( ((failed)) && echo FAILED || echo 'all steps passed') in $((SECONDS - t0)) s seat time; evidence $evidence"
  exit $failed
}
trap finish EXIT
run() { $mt run "$task" "$1" 2>&1 | tee -a "$log"; return "${PIPESTATUS[0]}"; }
need() { "$@" || { failed=1; say "FAIL  step: $*"; exit 1; }; }

step "0 inventory and send"
need $mt inventory m6
need $mt send "$task"

step "1 preflight"
need run 'if ps -axo comm= | grep -q "/AnJ Cloud.app/Contents/MacOS/AnJ Cloud$"; then echo "an AnJ Cloud is running (another lane?)"; exit 1; fi; if find ~/Library/LaunchAgents -maxdepth 1 -name "cloud.anj.*" 2>/dev/null | grep .; then echo "a cloud.anj LaunchAgent exists"; exit 1; fi; exit 0'
# The run leaves the guest's home as it found it (spec #31 M8): it must
# start without ~/anj-cloud or ~/Desktop/AnJ Cloud, so whatever exists
# afterwards was made by the installed app and is removed in step 6.
need run 'for x in "$HOME/anj-cloud" "$HOME/Desktop/AnJ Cloud"; do if [[ -e $x || -L $x ]]; then echo "$x exists on the guest; move it away first"; exit 1; fi; done; exit 0'
onboarding_clean=1
# A real TMPDIR (macOS /tmp is a symlink) inside the task directory.
env='export TMPDIR=$PWD/tmp; mkdir -p $TMPDIR'

step "2 release build, archive, receipt"
need run "$env; perl -e 'alarm shift; exec @ARGV' 900 zsh tool/macos/package_release.sh ev/release"

step "3 hermetic manager tests on macOS"
need run "$env; SHELLS='/bin/sh|bash --posix' perl -e 'alarm shift; exec @ARGV' 300 bash tool/macos/test_manager.sh > ev/test_manager.log 2>&1; rc=\$?; tail -3 ev/test_manager.log; grep FAIL ev/test_manager.log; exit \$rc"

step "4 install, update, rollback, Start at login, uninstall (GUI session)"
need run "$env; zip=\$(ls ev/release/anj-cloud-macos-arm64-*.zip | head -1); zsh tool/macos/gui_run.sh ev/gui 600 env TMPDIR=\$TMPDIR zsh tool/macos/m6_guest.sh ev/guest \"\$zip\""
