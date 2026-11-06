#!/bin/sh
# mac-test cleanup for one run (spec #31). Runs ON the guest, without sudo.
#
#   mac_test_cleanup.sh --owner <TAG> [--keep-workdir] [--reset-bundle-state]
#
# Owner TAG: letters, digits and '_' only. A run's task directories are
# exactly ~/work/<lane>/<TAG> and ~/work/<lane>/<TAG>-<anything>; '-' is the
# separator, so owner m0 never matches m0rev-1 or m1-x.
#
# Default (this owner only):
#   1. stops app processes whose executable is inside this owner's task
#      directories;
#   2. unregisters LaunchServices registrations whose path is inside them;
#   3. removes the task directories (unless --keep-workdir).
#
# --reset-bundle-state also resets the state every lane shares for the test
# bundle id cloud.anj.anj-cloud: its TCC rows, its defaults, and its exact
# ~/Library paths (Application Support, Caches, HTTPStorages, Preferences,
# Saved Application State, WebKit). It refuses, changing nothing shared,
# while another lane is live: an AnJ Cloud process, a built AnJ Cloud.app,
# or a registration of the bundle id outside this owner's directories.
#
# Never touched: other owners' directories and processes, other bundle ids,
# keychain items and LaunchAgents (the units that create them, M3 and M6,
# remove their own by exact name), the Baseline snapshot.
# Follow with mac_test_inventory.sh --owner <TAG> (exit 0 = clean).
set -u
bundle=cloud.anj.anj-cloud
owner=
keep=0
reset=0
while [ $# -gt 0 ]; do
  case "$1" in
    --owner) [ $# -ge 2 ] || { echo "mac_test_cleanup.sh: --owner needs a value" >&2; exit 64; }
             owner=$2; shift 2 ;;
    --keep-workdir) keep=1; shift ;;
    --reset-bundle-state) reset=1; shift ;;
    *) echo "usage: mac_test_cleanup.sh --owner <TAG> [--keep-workdir] [--reset-bundle-state]" >&2; exit 64 ;;
  esac
done
case "$owner" in
  ''|*[!A-Za-z0-9_]*) echo "mac_test_cleanup.sh: --owner <TAG> is required: letters, digits and '_' only" >&2; exit 64 ;;
esac
case "$HOME" in
  /*) ;;
  *) echo "mac_test_cleanup.sh: HOME must be an absolute path" >&2; exit 64 ;;
esac
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Whether $1 is a real directory at exactly that path: neither it nor any
# directory above it is a symlink (~/work/LINK -> ~/Documents must not let
# the owner glob reach outside ~/work).
real_dir() {
  [ -d "$1" ] && [ ! -L "$1" ] && [ "$(cd -P -- "$1" 2>/dev/null && pwd)" = "$1" ]
}
# This owner's task directories, one per line.
owner_dirs() {
  real_dir "$HOME/work" || return 0
  for d in "$HOME"/work/*/"$owner" "$HOME"/work/*/"$owner"-*; do
    real_dir "$(dirname "$d")" && real_dir "$d" && printf '%s\n' "$d"
  done
}
# Whether $1 is inside one of this owner's task directories.
in_owner_dirs() {
  owner_dirs | {
    while read -r d; do
      case "$1" in "$d"/*) exit 0 ;; esac
    done
    exit 1
  }
}
# The only targets rm -rf accepts: a task directory of this owner
# (~/work/<lane>/<owner> or <owner>-*) or an exact per-bundle Library path.
# Anything else, including empty or '..'/'.' components, is refused.
safe_rm() {
  target=$1
  case "$target" in
    ''|*//*|*/./*|*/../*|*/.|*/..|*/) echo "refused rm: $target" >&2; return 1 ;;
  esac
  rest=${target#"$HOME/work/"}
  if [ "$rest" != "$target" ]; then
    lane=${rest%%/*}
    task=${rest#*/}
    case "$lane" in ''|*[!A-Za-z0-9_-]*) echo "refused rm: $target" >&2; return 1 ;; esac
    case "$task" in
      "$owner") ;;
      "$owner"-*) case "$task" in */*) echo "refused rm: $target" >&2; return 1 ;; esac ;;
      *) echo "refused rm: $target" >&2; return 1 ;;
    esac
    real_dir "$target" || { echo "refused rm (symlink in path): $target" >&2; return 1; }
  else
    case "$target" in
      "$HOME/Library/Application Support/$bundle" | \
      "$HOME/Library/Caches/$bundle" | \
      "$HOME/Library/HTTPStorages/$bundle" | \
      "$HOME/Library/HTTPStorages/$bundle.binarycookies" | \
      "$HOME/Library/Preferences/$bundle.plist" | \
      "$HOME/Library/Saved Application State/$bundle.savedState" | \
      "$HOME/Library/WebKit/$bundle") ;;
      *) echo "refused rm: $target" >&2; return 1 ;;
    esac
  fi
  rm -rf -- "$target"
}
# Executable paths of running AnJ Cloud processes ("pid path").
app_processes() {
  ps -axo pid=,comm= 2>/dev/null | awk '/\/AnJ Cloud[^\/]*\.app\/Contents\/MacOS\// { pid = $1; sub(/^ *[0-9]+ +/, ""); print pid " " $0 }'
}
# Registered paths of the test bundle id.
registrations() {
  [ -x "$lsregister" ] || return 0
  "$lsregister" -dump 2>/dev/null | awk -v id="$bundle" '
    /^path:/ { sub(/^path: +/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0 }
    /^identifier:/ { if ($2 == id) print path }' | sort -u
}

# 1. This owner's app processes (TERM, then KILL).
for sig in TERM KILL; do
  app_processes | while read -r pid path; do
    in_owner_dirs "$path" && kill -$sig "$pid" 2>/dev/null && echo "stopped ($sig): $path"
  done
  [ $sig = TERM ] && sleep 2
done

# 2. This owner's LaunchServices registrations, by path.
registrations | while read -r app; do
  if in_owner_dirs "$app"; then
    "$lsregister" -u "$app" 2>/dev/null
    echo "unregistered: $app"
  fi
done

# 3. Shared bundle state, only on request and only while no other lane is live.
if [ $reset -eq 1 ]; then
  live=$( {
    app_processes | while read -r pid path; do in_owner_dirs "$path" || echo "process $pid: $path"; done
    registrations | while read -r app; do
      [ -e "$app" ] && ! in_owner_dirs "$app" && echo "registration: $app"
    done
    for app in "$HOME"/work/*/*/build/macos/Build/Products/*/AnJ\ Cloud.app; do
      [ -e "$app" ] && ! in_owner_dirs "$app" && echo "build: $app"
    done
  } )
  if [ -n "$live" ]; then
    echo "mac_test_cleanup: --reset-bundle-state refused; another lane is live:" >&2
    printf '%s\n' "$live" | sed 's/^/  /' >&2
    exit 1
  fi
  command -v tccutil >/dev/null 2>&1 && tccutil reset All "$bundle" >/dev/null 2>&1
  command -v defaults >/dev/null 2>&1 && defaults delete "$bundle" >/dev/null 2>&1
  for f in \
    "$HOME/Library/Application Support/$bundle" \
    "$HOME/Library/Caches/$bundle" \
    "$HOME/Library/HTTPStorages/$bundle" \
    "$HOME/Library/HTTPStorages/$bundle.binarycookies" \
    "$HOME/Library/Preferences/$bundle.plist" \
    "$HOME/Library/Saved Application State/$bundle.savedState" \
    "$HOME/Library/WebKit/$bundle"; do
    [ -e "$f" ] || continue
    safe_rm "$f" && echo "removed: $f"
  done
  echo "reset shared state of $bundle"
fi

# 4. This owner's task directories, last (this script may run from one).
if [ $keep -eq 0 ]; then
  owner_dirs | while read -r d; do
    safe_rm "$d" && echo "removed: $d"
  done
fi
echo "mac_test_cleanup: done for owner $owner"
