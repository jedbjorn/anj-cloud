#!/usr/bin/env bash
# The M4 mac-test run list (spec #31 M4), the VM host side: one batched window of
# about 15 minutes of seat time. Run it only inside a window the Planner has
# opened (the operator controls mac-test windows). Without sudo. Owner TAG m4.
#
#   tool/macos/m4_window.sh [<evidence dir>]     (default build/m4-window)
#
# 1. guest preflight: reachable, nothing of owner m4 left (inventory exit 0)
# 2. this branch -> mac-test:~/work/LANE1/m4-1, then tool/macos/check_m4.sh
#    there (release guard row 7, Finish editing, exclusions, consent, editor
#    round trip row 14, M3's SSH keychain rerun), evidence fetched back
# 3. (#68) the hard-link check against origin/main, where #68 lives: a
#    temporary detached worktree of origin/main plus this branch's
#    test_macos/hardlink_macos_test.dart -> ~/work/LANE1/m4-main; link a.txt to
#    b.txt, edit b.txt, expect no cloud delete
# 4. cleanup: mac_test.sh clean m4 --reset-bundle-state, then the guest
#    inventory (mac_test.sh inventory m4) and the VM host inventory
#    (anj-test-inventory --owner m4), both exit 0; the temporary worktree
#    is removed
# The temporary worktree lives in a fresh mktemp directory under this
# client's build/, and only that path is ever removed. If the run stops
# (an error, Ctrl-C, TERM) after anything was sent to the guest, the exit
# trap still runs the guest cleanup.
# Exit 0 only when every step passes and both inventories are clean.
set -uo pipefail
cd "$(dirname "$0")/../.."
client=$PWD
repo=$(git rev-parse --show-toplevel)
evidence=${1:-build/m4-window}
mkdir -p "$evidence"; evidence=$(cd "$evidence" && pwd)
mac=$client/tool/macos/mac_test.sh
main_base=
main_tree=
guest_started=0
guest_cleaned=0
failed=0
start=$(date +%s)
log() { printf '%s  [%3ds] %s\n' "$1" "$(( $(date +%s) - start ))" "$2" | tee -a "$evidence/summary.txt"; }
stage() { # name, command... (output to the terminal and <evidence>/run.log)
  local name=$1; shift
  log "==" "$name"
  if "$@" 2>&1 | tee -a "$evidence/run.log"; then log pass "$name"
  else log FAIL "$name"; failed=1; fi
}
# Removes only the worktree this run created (main_tree is set only after
# a successful worktree add into this run's own mktemp directory).
cleanup_tree() {
  if [[ -n $main_tree ]]; then
    git -C "$repo" worktree remove --force "$main_tree" || true
    main_tree=
  fi
  if [[ -n $main_base ]]; then rmdir -- "$main_base" 2>/dev/null || true; main_base=; fi
}
on_exit() {
  cleanup_tree
  if (( guest_started && !guest_cleaned )); then
    log info "stopped early: guest cleanup for owner m4"
    "$mac" clean m4 --reset-bundle-state || true
  fi
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 1. Preflight (mac_test.sh returns 255 when the guest does not answer).
stage "guest reachable; inventory for owner m4 is empty before the run" "$mac" inventory m4
if (( failed )); then log FAIL "preflight failed; nothing was started"; exit 1; fi

# 2. This branch: rows 7 and 14, Finish editing, exclusions, M3 rerun.
guest_started=1
stage "send this branch to LANE1/m4-1" "$mac" send LANE1/m4-1
stage "check_m4.sh on mac-test" "$mac" run LANE1/m4-1 'zsh tool/macos/check_m4.sh --evidence build/macos-m4'
"$mac" fetch LANE1/m4-1 build/macos-m4 "$evidence/m4-1" || log FAIL "fetch evidence of LANE1/m4-1"

# 3. #68 hard-link check on origin/main.
git -C "$repo" fetch -q origin main
mkdir -p "$client/build"
main_base=$(mktemp -d "$client/build/m4-main.XXXXXX")
if git -C "$repo" worktree add -q --detach "$main_base/tree" origin/main; then
  main_tree=$main_base/tree
  cp "$client/test_macos/hardlink_macos_test.dart" "$main_tree/apps/client/test_macos/"
  log info "origin/main at $(git -C "$main_tree" rev-parse --short HEAD) for the hard-link check"
  # Sent by origin/main's own mac_test.sh, so .anj-source names that commit.
  stage "send origin/main (+ hard-link test) to LANE1/m4-main" \
    bash -c 'cd "$1" && tool/macos/mac_test.sh send LANE1/m4-main' _ "$main_tree/apps/client"
  hardlink='export TMPDIR=$PWD/build/tmp && mkdir -p $TMPDIR && lib=$PWD/.dart_tool/libanj_rootfs.dylib'
  hardlink+=' && flutter --suppress-analytics pub get > /dev/null && tool/macos/build_native.sh --out $lib'
  hardlink+=' && ANJ_MACOS_ROOTFS_LIBRARY=$lib ANJ_ROOTFS_LIBRARY=$lib flutter --suppress-analytics test'
  hardlink+=' --reporter expanded test_macos/hardlink_macos_test.dart'
  stage "hard link: ln a.txt b.txt, edit b.txt, no cloud delete (#68, origin/main)" \
    "$mac" run LANE1/m4-main "$hardlink"
else
  log FAIL "temporary worktree of origin/main"; failed=1
fi
cleanup_tree

# 4. Cleanup and both inventories.
stage "mac_test.sh clean m4 --reset-bundle-state (guest inventory follows)" "$mac" clean m4 --reset-bundle-state
guest_cleaned=1
stage "guest inventory for owner m4" "$mac" inventory m4
stage "The VM host inventory for owner m4" ~/.local/share/anj-cloud/bin/anj-test-inventory --owner m4
log info "seat time $(( $(date +%s) - start )) s; evidence in $evidence"
if (( failed )); then log FAIL "m4 window"; else log pass "m4 window: every step passed"; fi
exit $failed
