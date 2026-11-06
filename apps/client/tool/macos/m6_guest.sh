#!/bin/zsh
# M6 run list, guest part (spec #31 acceptance row 15). Runs ON mac-test in
# the console user's GUI session (tool/macos/gui_run.sh), from the task
# directory, after package_release.sh built and archived the release:
#
#   m6_guest.sh <evidence dir> <release zip>
#
# Installs into <task>/inst (never ~/Applications), so the app copies and
# their LaunchServices registrations stay inside this owner's directory.
# Shared state it touches, and restores: the LaunchAgent
# ~/Library/LaunchAgents/cloud.anj.anj-cloud.plist (uninstall removes it),
# one login-keychain probe item (service cloud.anj.anj-cloud, account
# m6-probe, deleted at the end) and the app's default profile (reset by
# mac_test.sh clean m6 --reset-bundle-state afterwards).
#
# Steps: variants (v2 = same app re-signed with build 2, a new cdhash like a
# real update; v3 = a release whose executable exits at once), then
#  1 wrong SHA-256 refused   2 quarantined zip installs, first launch
#  through the agent, window shown   3 update over a running instance
#  refused without --restart   4 update --restart keeps profile and keychain
#  5 rollback from v3   6 Start at login: off while running, on while
#  stopped = launchd loads the agent as at login (--background, no window)
#  7 the embedded manager (the app's toggle)   8 uninstall, 8b --remove-profile
# The installed app runs with the real HOME, so with M8 (#99) its new profile
# makes ~/anj-cloud and ~/Desktop/AnJ Cloud; m6_run.sh checks they were absent
# before the run and removes them over SSH afterwards.
# Prints pass/FAIL lines and per-step seconds; exit 0 only when all pass.
set -u
ev=${1:?usage: m6_guest.sh <evidence dir> <release zip>}
zip1=${2:?usage}
mkdir -p "$ev"; ev=${ev:A}; zip1=${zip1:A}
M=$PWD/tool/macos/anj-cloud-macos-install.sh
inst=$PWD/inst
APP="$inst/AnJ Cloud.app"; PREV="$inst/AnJ Cloud.previous.app"; EXE="$APP/Contents/MacOS/AnJ Cloud"
AGENT=$HOME/Library/LaunchAgents/cloud.anj.anj-cloud.plist
PROFILE="$HOME/Library/Application Support/cloud.anj.anj-cloud/anj-cloud/default"
uid=$(id -u)
failed=0
pass() { print -r -- "pass  $1"; }
fail() { print -r -- "FAIL  $1"; failed=1; }
expect() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
t0=$SECONDS; tstep=$SECONDS
step() { print -r -- "== $1 (+$((SECONDS - tstep)) s, total $((SECONDS - t0)) s)"; tstep=$SECONDS; }
n=0
mgr() { # manager in this GUI session; rc, json in $ev/<n>.json
  n=$((n + 1))
  sh "$M" "$@" --apps-dir "$inst" > "$ev/$n-$1.json" 2> "$ev/$n-$1.err"
  rc=$?
  print -r -- "info  [$n] manager $* -> $rc $(head -c 300 "$ev/$n-$1.json")"
  [[ -s $ev/$n-$1.err ]] && sed 's/^/      | /' "$ev/$n-$1.err"
}
mgr_noapps() { n=$((n + 1)); sh "$@" > "$ev/$n-x.json" 2> "$ev/$n-x.err"; rc=$?; print -r -- "info  [$n] $* -> $rc $(head -c 300 "$ev/$n-x.json")"; }
js() { grep -q -- "$1" "$ev/$n-"*.json; }
app_pid() { ps -axo pid=,comm= | awk -v e="$EXE" '{ p = $1; sub(/^ *[0-9]+ +/, ""); if ($0 == e) print p }' | tail -1; }
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
job() { launchctl print "gui/$uid/cloud.anj.anj-cloud" 2>/dev/null; }
quit_app() { p=$(app_pid); [[ -n $p ]] || return 0; kill -TERM $p; for i in {1..60}; do kill -0 $p 2>/dev/null || return 0; sleep 0.5; done; return 1; }
windows() { swift "${M:h}/window_check.swift" "$1" 2>/dev/null; }

# Preconditions: nothing of ours is installed or loaded.
[[ ! -e $AGENT ]] || { fail "precondition: $AGENT already exists (another lane?)"; exit 1; }
[[ -z $(ps -axo comm= | grep '/AnJ Cloud.app/Contents/MacOS/AnJ Cloud$') ]] || { fail "precondition: an AnJ Cloud is running"; exit 1; }
rm -rf "$inst"; mkdir -p "$inst"

step "variants"
src="$ev/src"; rm -rf "$src"; mkdir -p "$src"
ditto -x -k "$zip1" "$src" || { fail "extract the release"; exit 1; }
variant() { # name build [broken]
  w="$ev/variant-$1"; rm -rf "$w"; mkdir -p "$w"
  ditto "$src/AnJ Cloud.app" "$w/AnJ Cloud.app"
  plutil -replace CFBundleVersion -string "$2" "$w/AnJ Cloud.app/Contents/Info.plist"
  [[ ${3:-} == broken ]] && cp /usr/bin/false "$w/AnJ Cloud.app/Contents/MacOS/AnJ Cloud"
  codesign --force --sign - --options runtime --timestamp=none \
    --entitlements macos/Runner/Release.entitlements "$w/AnJ Cloud.app" > "$w/sign.log" 2>&1 || return 1
  (cd "$w" && ditto -c -k --keepParent "AnJ Cloud.app" "$ev/$1.zip")
  shasum -a 256 "$ev/$1.zip" | awk '{ print $1 }'
}
sha1=$(shasum -a 256 "$zip1" | awk '{ print $1 }')
sha2=$(variant v2 2) && sha3=$(variant v3 3 broken)
expect "v2 (build 2, re-signed) and v3 (exits at once) made" "[[ -n \$sha2 && -n \$sha3 ]]"
expect "v2 has a new cdhash" "[[ \$(cdhash '$ev/variant-v2/AnJ Cloud.app') != \$(cdhash '$src/AnJ Cloud.app') ]]"

step "1 wrong SHA-256"
mgr install "$zip1" --sha256 "${sha1//[0-9a-f]/0}"
expect "wrong SHA-256 refused (1), nothing in inst" "[[ $rc == 1 && -z \$(ls -A '$inst') ]]"

step "2 quarantined zip, first install"
cp "$zip1" "$ev/v1-downloaded.zip"
xattr -w com.apple.quarantine "0083;$(printf %x $(date +%s));Safari;$(uuidgen)" "$ev/v1-downloaded.zip"
expect "the copy is quarantined like a browser download" "xattr -p com.apple.quarantine '$ev/v1-downloaded.zip' >/dev/null 2>&1"
mgr install "$ev/v1-downloaded.zip" --sha256 "$sha1"
expect "install exits 0 with a launch check" "[[ $rc == 0 ]] && js '\"launch_checked\": true'"
expect "installed app carries no quarantine" "! xattr -r '$APP' 2>/dev/null | grep -q com.apple.quarantine"
expect "seal verifies in place" "codesign --verify --deep --strict '$APP'"
p1=$(app_pid)
expect "app running from the stable path" "[[ -n '$p1' ]]"
expect "one process, started by LaunchServices with its window (not --background); the agent waits for the next login" "[[ \$(ps -axo comm= | grep -c '^$EXE\$') == 1 ]] && ! ps -o args= -p '$p1' | grep -q -- '--background' && ! job >/dev/null"
sleep 2
expect "window shown" "windows '$p1' > '$ev/install-windows.jsonl'"
screencapture -x "$ev/install-screen.png" 2>/dev/null
plutil -lint "$AGENT" > "$ev/agent-lint.txt" 2>&1; cp "$AGENT" "$ev/agent.plist"
expect "LaunchAgent: RunAtLoad, Aqua, stable path, --background" "grep -q '<string>$EXE</string>' '$AGENT' && grep -q LimitLoadToSessionType '$AGENT' && grep -q -- --background '$AGENT'"
job > "$ev/job-after-install.txt"

step "3 update over a running instance, no --restart"
mkdir -p "$PROFILE"; print -r -- "m6 marker $(date +%s)" > "$PROFILE/m6-marker"
security add-generic-password -s cloud.anj.anj-cloud -a m6-probe -l "AnJ Cloud m6 probe" -w "m6-$(uuidgen)" 2> "$ev/keychain-add.err"
expect "keychain probe item added (GUI session)" "security find-generic-password -s cloud.anj.anj-cloud -a m6-probe >/dev/null 2>&1"
mgr update "$ev/v2.zip" --sha256 "$sha2"
expect "refused busy (75); the same process still runs" "[[ $rc == 75 && \$(app_pid) == '$p1' ]]"

step "4 update --restart"
mgr update "$ev/v2.zip" --sha256 "$sha2" --restart
p2=$(app_pid)
expect "update exits 0, launch-checked" "[[ $rc == 0 ]] && js '\"launch_checked\": true'"
expect "old process gone, a new one runs the new cdhash" "! kill -0 '$p1' 2>/dev/null && [[ -n '$p2' ]] && [[ \$(cdhash '$APP') == \$(cdhash '$ev/variant-v2/AnJ Cloud.app') ]]"
expect "relaunched as it ran (with its window, one process)" "! ps -o args= -p '$p2' | grep -q -- '--background' && [[ \$(ps -axo comm= | grep -c '^$EXE\$') == 1 ]]"
expect "previous release kept" "[[ \$(cdhash '$PREV') == \$(cdhash '$src/AnJ Cloud.app') ]]"
expect "profile kept" "[[ -f '$PROFILE/m6-marker' ]]"
expect "keychain probe item kept" "security find-generic-password -s cloud.anj.anj-cloud -a m6-probe >/dev/null 2>&1"

step "5 rollback"
mgr update "$ev/v3.zip" --sha256 "$sha3" --restart
p3=$(app_pid)
expect "update to a release that exits: rolled back (2)" "[[ $rc == 2 ]] && js rolled_back"
expect "v2 back in place and running again" "[[ \$(cdhash '$APP') == \$(cdhash '$ev/variant-v2/AnJ Cloud.app') && -n '$p3' && '$p3' != '$p2' ]]"
mgr status
expect "records name build 2 again" "js '\"build\": \"2\"'"

step "6 Start at login"
mgr autostart off
expect "off: agent removed; the running app (launchd's) is not stopped" "[[ $rc == 0 && ! -e '$AGENT' ]] && kill -0 '$p3' && js '\"enabled\": false'"
job > "$ev/job-after-off-running.txt"
expect "quit the app (SIGTERM, its Quit)" quit_app
mgr autostart off
expect "off while stopped: the job is unloaded" "[[ $rc == 0 ]] && ! job >/dev/null"
mgr autostart on
sleep 3
p4=$(app_pid)
expect "on while stopped: launchd loads the agent and starts the app (the login path)" "[[ $rc == 0 && -n '$p4' ]] && job | grep -q 'pid = $p4'"
expect "  with --background" "ps -o args= -p '$p4' | grep -q -- '--background'"
sleep 2
expect "  and no window (menu bar only)" "! windows '$p4'"
screencapture -x "$ev/autostart-screen.png" 2>/dev/null
job > "$ev/job-after-on.txt"

step "7 embedded manager (the app's toggle)"
mgr_noapps "$APP/Contents/Resources/anj-cloud-macos-install.sh" autostart status
expect "the bundle's copy finds its install: enabled" "[[ $rc == 0 ]] && grep -q '\"enabled\": true' '$ev/$n-x.json'"
expect "it is the reviewed source, byte for byte" "cmp -s '$APP/Contents/Resources/anj-cloud-macos-install.sh' '$M'"

step "8 uninstall"
mgr uninstall
expect "uninstall while running: busy (75), nothing removed" "[[ $rc == 75 && -d '$APP' && -e '$AGENT' ]]"
expect "quit the app" quit_app
mgr uninstall
expect "uninstall: app, previous, agent, job and records gone" "[[ $rc == 0 && ! -e '$APP' && ! -e '$PREV' && ! -e '$AGENT' && ! -e '$inst/.anj-cloud-manager' ]] && ! job >/dev/null"
expect "profile kept by uninstall" "[[ -f '$PROFILE/m6-marker' ]]"

step "8b uninstall --remove-profile (PR #72 review L4)"
# The profile the run's launches made (or a stand-in), and a device-key
# item for its id, as the app would hold after pairing.
pid_=$(sqlite3 -readonly "$PROFILE/manifest.sqlite" "SELECT value FROM settings WHERE key='profileId'" 2>/dev/null)
if [[ -z $pid_ ]]; then
  pid_=anj-test-m6-$$
  sqlite3 "$PROFILE/manifest.sqlite" "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL); INSERT OR REPLACE INTO settings VALUES ('profileId', '$pid_')"
fi
security add-generic-password -U -s cloud.anj.anj-cloud -a "anj-cloud:$pid_:device-key" -w m6-test
mgr uninstall
expect "plain uninstall lists the kept item and the command" "js 'anj-cloud:$pid_:device-key' && js 'uninstall --remove-profile' && [[ -d '$PROFILE' ]]"
mgr uninstall --remove-profile
expect "--remove-profile: the profile and its keychain item are gone" "[[ $rc == 0 && ! -e '$PROFILE' ]] && ! security find-generic-password -s cloud.anj.anj-cloud -a 'anj-cloud:$pid_:device-key' >/dev/null 2>&1"

step "cleanup"
security delete-generic-password -s cloud.anj.anj-cloud -a m6-probe >/dev/null 2>&1
[[ -n ${pid_:-} ]] && security delete-generic-password -s cloud.anj.anj-cloud -a "anj-cloud:$pid_:device-key" >/dev/null 2>&1
expect "keychain probe item deleted" "! security find-generic-password -s cloud.anj.anj-cloud -a m6-probe >/dev/null 2>&1"
rm -f "$PROFILE/m6-marker"
quit_app
[[ -e $AGENT ]] && { launchctl bootout "gui/$uid/cloud.anj.anj-cloud" 2>/dev/null; rm -f "$AGENT"; }
rm -rf "$src" "$ev"/variant-* "$inst"
step "done"
if (( failed )); then print "m6_guest: FAILED"; else print "m6_guest: all steps passed"; fi
exit $failed
