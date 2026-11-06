#!/bin/sh
# mac-test guest hygiene (spec #31): lists what a run left on the guest.
# Runs ON the guest, without sudo; it only reads.
#
#   mac_test_inventory.sh --owner <TAG> [--strict]
#
# From the VM host:  tailscale ssh "<[lab] mac_test_host>" 'sh -s -- --owner <TAG>' \
#               < tool/macos/mac_test_inventory.sh
#
# Owner section (decides the exit code): this owner's task directories,
# exactly ~/work/<lane>/<TAG> and ~/work/<lane>/<TAG>-* (letters, digits
# and '_' in a TAG; '-' is the separator), app processes running from them
# and LaunchServices registrations inside them.
# Shared section (reported, and decides the exit code only with --strict):
# state every lane shares for the test bundle id cloud.anj.anj-cloud. That
# is other app processes and registrations, cloud.anj.* LaunchAgents and
# launchd jobs, TCC rows, keychain items, per-app Library state, copies in
# ~/Applications and the install manager's records there (M6). Use --strict when no other lane is on the guest.
# Exit 0 = clean, 1 = residue, 64 = usage. Baseline restores stay with the operator.
set -u
owner=
strict=0
bundle=cloud.anj.anj-cloud
while [ $# -gt 0 ]; do
  case "$1" in
    --owner) [ $# -ge 2 ] || { echo "mac_test_inventory.sh: --owner needs a value" >&2; exit 64; }
             owner=$2; shift 2 ;;
    --strict) strict=1; shift ;;
    *) echo "usage: mac_test_inventory.sh --owner <TAG> [--strict]" >&2; exit 64 ;;
  esac
done
case "$owner" in
  ''|*[!A-Za-z0-9_]*) echo "mac_test_inventory.sh: --owner <TAG> is required: letters, digits and '_' only" >&2; exit 64 ;;
esac
# Keychain services a client build may write (M3 pins its own service to
# the bundle id; the plugin default is listed so a stray default is seen).
services="$bundle flutter_secure_storage_service"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
uid=$(id -u)
owned=0
shared=0
report() { owned=1; echo "LEFT    $1: $2"; }
share() { shared=1; echo "shared  $1: $2"; }
note() { echo "note    $1: $2"; }
owner_dirs() {
  for d in "$HOME"/work/*/"$owner" "$HOME"/work/*/"$owner"-*; do
    [ -e "$d" ] && printf '%s\n' "$d"
  done
}
in_owner_dirs() {
  owner_dirs | {
    while read -r d; do
      case "$1" in "$d"/*) exit 0 ;; esac
    done
    exit 1
  }
}
app_processes() {
  ps -axo pid=,comm= 2>/dev/null | awk '/\/AnJ Cloud[^\/]*\.app\/Contents\/MacOS\// { pid = $1; sub(/^ *[0-9]+ +/, ""); print pid " " $0 }'
}
registrations() {
  [ -x "$lsregister" ] || return 0
  "$lsregister" -dump 2>/dev/null | awk -v id="$bundle" '
    /^path:/ { sub(/^path: +/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0 }
    /^identifier:/ { if ($2 == id) print path }' | sort -u
}

echo "== owner $owner"
# 1. Task directories of this owner.
dirs=$(owner_dirs)
[ -n "$dirs" ] && printf '%s\n' "$dirs" | while read -r d; do echo "LEFT    workdir: $d"; done
[ -n "$dirs" ] && owned=1

# 2. App processes and registrations: this owner's, then other lanes'.
procs=$(app_processes)
regs=$(registrations)
[ -x "$lsregister" ] || note launchservices "lsregister not found; not checked"
own_left=$( {
  [ -n "$procs" ] && printf '%s\n' "$procs" | while read -r pid path; do
    in_owner_dirs "$path" && echo "process $pid: $path"; done
  [ -n "$regs" ] && printf '%s\n' "$regs" | while read -r r; do
    in_owner_dirs "$r" && echo "launchservices: $r"; done
} )
[ -n "$own_left" ] && { owned=1; printf '%s\n' "$own_left" | sed 's/^/LEFT    /'; }

echo "== shared bundle $bundle (other lanes too)"
other=$( {
  [ -n "$procs" ] && printf '%s\n' "$procs" | while read -r pid path; do
    in_owner_dirs "$path" || echo "process $pid: $path"; done
  [ -n "$regs" ] && printf '%s\n' "$regs" | while read -r r; do
    in_owner_dirs "$r" || echo "launchservices: $r"; done
} )
[ -n "$other" ] && { shared=1; printf '%s\n' "$other" | sed 's/^/shared  /'; }

# 3. LaunchAgents and launchd jobs.
for f in "$HOME"/Library/LaunchAgents/cloud.anj.*; do
  [ -e "$f" ] && share launchagent "$f"
done
jobs=$(launchctl print "gui/$uid" 2>/dev/null | grep -oE 'cloud\.anj\.[A-Za-z0-9._-]+|local\.anj-test\.[A-Za-z0-9._-]+' | sort -u)
for j in $jobs; do share launchd-job "gui/$uid/$j"; done

# 4. Privacy rows (user TCC database; readable with the Full Disk Access
#    the operator granted to tailscaled).
tcc="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
if rows=$(sqlite3 -readonly "$tcc" "select service from access where client = '$bundle' or client like '$bundle.%'" 2>/dev/null); then
  for r in $rows; do share tcc "$r ($bundle; tccutil reset All $bundle)"; done
else
  note tcc "user TCC database not readable from this session; not checked"
fi

# 5. Keychain items. Only a GUI-session process sees the login keychain, so
#    a one-shot gui/<uid> launchd job counts matching items. Attributes only
#    (dump-keychain without -d): no secret is read or printed.
tmp_base=${TMPDIR:-/tmp}
tmp_base=${tmp_base%/}
job_dir=$(mktemp -d "$tmp_base/anj-inventory.XXXXXX" 2>/dev/null) || job_dir=
case "$job_dir" in
  "$tmp_base"/anj-inventory.??????) ;;
  *) job_dir= ;;
esac
label="local.anj-test.inventory.$$"
pattern=$(echo "$services" | sed 's/\./\\./g; s/ /|/g')
[ -n "$job_dir" ] && cat > "$job_dir/run.sh" <<EOF
#!/bin/sh
security dump-keychain login.keychain-db 2>/dev/null | grep -cE '"svce"<blob>="($pattern)' > "$job_dir/count"
echo done > "$job_dir/finished"
EOF
[ -n "$job_dir" ] && cat > "$job_dir/job.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>/bin/sh</string><string>$job_dir/run.sh</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
EOF
if [ -z "$job_dir" ]; then
  note keychain "no private scratch directory; not checked"
elif launchctl bootstrap "gui/$uid" "$job_dir/job.plist" 2>/dev/null; then
  i=0
  while [ ! -e "$job_dir/finished" ] && [ $i -lt 60 ]; do sleep 0.5; i=$((i + 1)); done
  launchctl bootout "gui/$uid/$label" 2>/dev/null
  count=$(cat "$job_dir/count" 2>/dev/null)
  if [ ! -e "$job_dir/finished" ]; then
    note keychain "gui/$uid job did not finish; not checked"
  elif [ "${count:-0}" -gt 0 ]; then
    share keychain "$count login-keychain item(s) with service in: $services"
  fi
else
  note keychain "no GUI session for gui/$uid (nobody logged in at the console?); not checked"
fi
# Only the mktemp directory created above (pattern checked when made).
[ -n "$job_dir" ] && rm -rf -- "$job_dir"

# 6. Per-app Library state and installed copies.
for f in \
  "$HOME/Library/Application Support/$bundle" \
  "$HOME/Library/Caches/$bundle" \
  "$HOME/Library/HTTPStorages/$bundle" \
  "$HOME/Library/HTTPStorages/$bundle.binarycookies" \
  "$HOME/Library/Preferences/$bundle.plist" \
  "$HOME/Library/Saved Application State/$bundle.savedState" \
  "$HOME/Library/WebKit/$bundle" \
  "$HOME/Library/Containers/$bundle" \
  "$HOME"/Applications/AnJ\ Cloud*.app \
  "$HOME/Applications/.anj-cloud-manager" \
  "$HOME/Applications/.anj-cloud-manager.lock" \
  "$HOME"/Applications/.anj-cloud-stage.*; do
  [ -e "$f" ] && share library "$f"
done
# What a new profile of the app makes in the real home (spec #31 M8): no
# lane keeps these on the guest, so either one is a leftover (delta review
# L3).
for f in "$HOME/anj-cloud" "$HOME/Desktop/AnJ Cloud"; do
  { [ -e "$f" ] || [ -L "$f" ]; } && report home "$f (made by an app launch with the real HOME; remove it)"
done

if [ $owned -eq 0 ] && { [ $strict -eq 0 ] || [ $shared -eq 0 ]; }; then
  if [ $shared -eq 0 ]; then
    echo "mac_test_inventory: clean for owner $owner and bundle $bundle"
  else
    echo "mac_test_inventory: clean for owner $owner; shared bundle state listed above (not counted without --strict)"
  fi
  exit 0
fi
echo "mac_test_inventory: residue listed above (owner $owner$( [ $strict -eq 1 ] && echo ', strict'))"
exit 1
