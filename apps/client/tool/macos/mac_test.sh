#!/usr/bin/env bash
# host-side driver for the mac-test seat (spec #31, mac_test skill): sends
# this client source to a task directory on the guest, runs commands there,
# fetches evidence back, and cleans up. Durable work stays in the VM host
# worktree and its PR; guest state can be lost on a Baseline restore.
#
#   mac_test.sh send  <shell>/<task>              client source -> ~/work/<shell>/<task>
#   mac_test.sh run   <shell>/<task> <command>    run <command> (zsh -lc) in that directory
#   mac_test.sh check <shell>/<task> [args]       tool/macos/check_macos.sh there
#   mac_test.sh fetch <shell>/<task> <path> <dir> copy <path> (relative) back into <dir>
#   mac_test.sh clean <owner> [--reset-bundle-state]
#                                                 this owner's cleanup, then its inventory (exit 0 = clean)
#   mac_test.sh inventory <owner> [--strict]
#
# Owner TAG: letters, digits and '_' only. <task> is exactly <owner> or
# <owner>-<anything> (for example DEV1/m0-1 for owner m0); '-' is the
# separator, so owner m0 never matches m0rev-1. --reset-bundle-state also
# resets the shared state of the test bundle id and refuses while another
# lane is live (mac_test_cleanup.sh). Direct Tailscale SSH as the operator user (decision #1); no
# sudo; one heavy build on the guest at a time.
set -euo pipefail
cd "$(dirname "$0")/../.."
# The guest comes from the deployment profile ([lab] mac_test_host); MAC_TEST_HOST overrides it.
host=${MAC_TEST_HOST:-$(python3 -I ../../deploy/deployment_profile.py get lab.mac_test_host)}
remote() { tailscale ssh "$host" "$@"; }
# tailscale ssh always exits 0, whatever the remote command returned, so
# the remote status travels as a last line and this returns it.
remote_rc() {
  rm -f -- "$scratch/rc"
  # The marker starts on its own line even when the output does not end in
  # a newline; the empty line that adds before it is dropped again.
  tailscale ssh "$host" "$1"'; printf "\n__ANJ_RC=%s\n" "$?"' |
    awk -v f="$scratch/rc" '
      /^__ANJ_RC=[0-9]+$/ { sub(/^__ANJ_RC=/, ""); print > f; held = 0; next }
      { if (held) { print ""; held = 0 } }
      /^$/ { held = 1; next }
      { print; fflush() }
      END { if (held) print "" }'
  if [[ ! -s $scratch/rc ]]; then
    echo "mac_test.sh: no exit status from mac-test (connection lost?)" >&2
    return 255
  fi
  return "$(cat "$scratch/rc")"
}
task_dir() {
  [[ $1 =~ ^[A-Za-z0-9_-]+/[A-Za-z0-9._-]+$ && $1 != */.* ]] || {
    echo "mac_test.sh: task must be <shell>/<task>" >&2; exit 64; }
  echo "work/$1"
}
owner_ok() {
  [[ $1 =~ ^[A-Za-z0-9_]+$ ]] || { echo "mac_test.sh: owner must be letters, digits and '_' only" >&2; exit 64; }
}
sources=(.metadata analysis_options.yaml pubspec.yaml pubspec.lock assets lib
  macos native test test_macos integration_test tool)

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
cmd=${1:-}; shift || true
case $cmd in
  send)
    dir=$(task_dir "${1:?task}")
    remote_rc "rm -rf ~/$dir && mkdir -p ~/$dir"
    # The tested revision, for the evidence (check_macos.sh prints it).
    rev=$(git rev-parse HEAD)
    dirty=$(git status --porcelain -- . | wc -l | tr -d ' ')
    printf 'commit %s, %s uncommitted file(s) under apps/client, sent %s\n' \
      "$rev" "$dirty" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$scratch/.anj-source"
    # The deployment profile's release key and origin are untracked: write them into the sent tree.
    python3 tool/apply_profile.py > /dev/null
    [[ ! -f anj-defines.env ]] || sources+=(anj-defines.env)
    tar --exclude=build --exclude=.dart_tool --exclude='macos/Flutter/ephemeral' \
      -cf - "${sources[@]}" -C "$scratch" .anj-source | remote_rc "cd ~/$dir && tar -xf -"
    echo "sent to mac-test:~/$dir ($(cat "$scratch/.anj-source"))"
    ;;
  run)
    dir=$(task_dir "${1:?task}"); shift
    remote_rc "cd ~/$dir && zsh -lc $(printf '%q' "$*")"
    ;;
  check)
    dir=$(task_dir "${1:?task}"); shift
    remote_rc "cd ~/$dir && zsh -l tool/macos/check_macos.sh $(printf '%q ' "$@")"
    ;;
  fetch)
    dir=$(task_dir "${1:?task}"); path=${2:?path}; into=${3:?dir}
    mkdir -p "$into"
    remote "cd ~/$dir && COPYFILE_DISABLE=1 tar --no-xattrs -cf - $(printf '%q' "$path")" | tar -xf - -C "$into"
    ;;
  clean)
    owner_ok "${1:?owner}"
    flag=
    case ${2:-} in '') ;; --reset-bundle-state) flag=$2 ;; *) echo "mac_test.sh: unknown option $2" >&2; exit 64 ;; esac
    cleaned=0
    remote_rc 'sh -s -- --owner '"$1 $flag" < tool/macos/mac_test_cleanup.sh || cleaned=$?
    remote_rc 'sh -s -- --owner '"$1" < tool/macos/mac_test_inventory.sh
    exit $cleaned
    ;;
  inventory)
    owner_ok "${1:?owner}"
    flag=
    case ${2:-} in '') ;; --strict) flag=$2 ;; *) echo "mac_test.sh: unknown option $2" >&2; exit 64 ;; esac
    remote_rc 'sh -s -- --owner '"$1 $flag" < tool/macos/mac_test_inventory.sh
    ;;
  *)
    sed -n '2,22p' "$0" >&2; exit 64 ;;
esac
