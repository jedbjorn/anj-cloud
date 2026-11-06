#!/bin/zsh
# Spec #40 R2 in-app update, guest part. Runs ON mac-test in the console
# user's GUI session (tool/macos/gui_run.sh), from the task directory:
#
#   r2_guest.sh <evidence dir> <release N zip> <release N+1 zip> <N+1 manifest> <N manifest>
#
# Both releases come from tool/macos/release_macos.sh (receipt stamped,
# re-signed) with the same built-in key; the manifests are the ones the
# review stack's feed served after deploy/release.py publish. Installs into
# <task>/inst (never ~/Applications). The installed app runs with the real
# HOME: its default profile (its private updates folder is where the app
# stages a download) and, with M8, ~/anj-cloud and ~/Desktop/AnJ Cloud;
# The VM host driver checks they were absent and removes them afterwards, and
# mac_test.sh clean <owner> --reset-bundle-state resets the profile.
#
# Every apply-update below runs the INSTALLED release's embedded manager,
# as the app's MacosManagerSelfUpdate does, on files in the updates folder:
#  1 install N
#  2 --check (the app's check before it offers): N+1 verifies
#  3 --check refusals by the installed N: a tampered manifest (signature),
#    a tampered archive (size and SHA-256), N's own release (not newer)
#  4 the hand-over with a tampered archive: the app quits, the manager
#    refuses, writes the reason, deletes the download, restarts N
#  5 failed launch: N+1 cannot start (its profile is held, exit 73), the
#    manager rolls back to N and writes why
#  6 the hand-over: the app quits, N+1 is installed and runs with its
#    window, N kept as the previous release, the result names N+1
# After each hand-over the release that runs reads the outcome as it
# starts (its updates folder is cleared): the outcome is written before it
# starts, and a failed launch's before the restored release starts.
# Prints pass/FAIL lines; exit 0 only when all pass.
set -u
ev=${1:?usage: r2_guest.sh <evidence dir> <N zip> <N+1 zip> <N+1 manifest> <N manifest>}
zipN=${2:?usage} zipN1=${3:?usage} manN1=${4:?usage} manN=${5:?usage}
mkdir -p "$ev"; ev=${ev:A}; zipN=${zipN:A}; zipN1=${zipN1:A}; manN1=${manN1:A}; manN=${manN:A}
M=$PWD/tool/macos/anj-cloud-macos-install.sh
inst=$PWD/inst
APP="$inst/AnJ Cloud.app"; PREV="$inst/AnJ Cloud.previous.app"; EXE="$APP/Contents/MacOS/AnJ Cloud"
EMB="$APP/Contents/Resources/anj-cloud-macos-install.sh"
AGENT=$HOME/Library/LaunchAgents/cloud.anj.anj-cloud.plist
PROFILE="$HOME/Library/Application Support/cloud.anj.anj-cloud/anj-cloud/default"
UP="$PROFILE/updates"
failed=0
pass() { print -r -- "pass  $1"; }
fail() { print -r -- "FAIL  $1"; failed=1; }
expect() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
t0=$SECONDS
step() { print -r -- "== $1 (total $((SECONDS - t0)) s)"; }
app_pid() { ps -axo pid=,comm= | awk -v e="$EXE" '{ p = $1; sub(/^ *[0-9]+ +/, ""); if ($0 == e) print p }' | tail -1; }
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
code_of() { plutil -extract version_code raw -o - "$1/Contents/Resources/bundle-receipt.json" 2>/dev/null; }
quit_app() { p=$(app_pid); [[ -n $p ]] || return 0; kill -TERM $p; for i in {1..60}; do kill -0 $p 2>/dev/null || return 0; sleep 0.5; done; return 1; }
windows() { swift "${M:h}/window_check.swift" "$1" 2>/dev/null; }
wait_pid() { for i in {1..80}; do p=$(app_pid); [[ -n $p && $p != ${1:-} ]] && { sleep 3; [[ $(app_pid) == $p ]] && return 0; }; sleep 0.5; done; return 1; }
# The app reads result.json and clears its updates folder as it starts
# (DesktopUpdater.start): the outcome reached the release that runs.
read_by_app() { for i in {1..60}; do [[ ! -e $UP/result.json ]] && return 0; sleep 0.5; done; return 1; }
stage() { # zip manifest: the download as the app leaves it
  mkdir -p "$UP"; chmod 700 "$UP"; rm -f "$UP/result.json"
  cp "$1" "$UP/update.zip"; cp "$2" "$UP/manifest.json"
}
check() { "$EMB" apply-update "$UP/update.zip" --manifest "$UP/manifest.json" --check > "$ev/$1.json" 2> "$ev/$1.err"; rc=$?
  print -r -- "info  check $1 -> $rc $(cat "$ev/$1.json") $(tail -1 "$ev/$1.err")"; }
hand_over() { # name: start the manager as the app does (detached, --result, --app-pid), then the app quits
  local p=$(app_pid)
  nohup "$EMB" apply-update "$UP/update.zip" --manifest "$UP/manifest.json" --result "$UP/result.json" --app-pid "$p" \
    > "$ev/$1.json" 2> "$ev/$1.err" < /dev/null &
  mpid=$!
  sleep 1; kill -TERM "$p"
  # The restarted app reads result.json (its Updated / install failed
  # notice) and clears the folder as it starts: keep a copy when it lands.
  # Every version is kept in order ($1.results); $1.result.json is the last.
  rm -f "$ev/$1.result.json" "$ev/$1.results"
  local seen= now=
  for i in {1..1800}; do
    now=$(cat "$UP/result.json" 2>/dev/null)
    [[ -n $now && $now != "$seen" ]] && { print -r -- "$now" >> "$ev/$1.results"; print -r -- "$now" > "$ev/$1.result.json"; seen=$now; }
    kill -0 $mpid 2>/dev/null || break; sleep 0.1
  done
  now=$(cat "$UP/result.json" 2>/dev/null)
  [[ -n $now && $now != "$seen" ]] && { print -r -- "$now" >> "$ev/$1.results"; print -r -- "$now" > "$ev/$1.result.json"; }
  wait $mpid 2>/dev/null; rc=$?
  print -r -- "info  hand-over $1 (app pid $p) -> manager $rc $(cat "$ev/$1.json")"
  sed 's/^/      | /' "$ev/$1.err"
  print -r -- "info  result.json as written, in order: $(tr '\n' ' ' < "$ev/$1.results" 2>/dev/null); left in the folder: $([[ -e $UP/result.json ]] && echo yes || echo 'no (read by the restarted app)')"
}

[[ ! -e $AGENT ]] || { fail "precondition: $AGENT already exists (another lane?)"; exit 1; }
[[ -z $(ps -axo comm= | grep '/AnJ Cloud.app/Contents/MacOS/AnJ Cloud$') ]] || { fail "precondition: an AnJ Cloud is running"; exit 1; }
rm -rf "$inst"; mkdir -p "$inst"
shaN=$(shasum -a 256 "$zipN" | awk '{ print $1 }')
src="$ev/src"; rm -rf "$src"; mkdir -p "$src/n1"; ditto -x -k "$zipN1" "$src/n1"

step "1 install N"
sh "$M" install "$zipN" --sha256 "$shaN" --apps-dir "$inst" > "$ev/install.json" 2> "$ev/install.err"; rc=$?
p1=$(app_pid)
expect "N installed and running (launch-checked)" "[[ $rc == 0 && -n '$p1' ]] && grep -q '\"launch_checked\": true' '$ev/install.json'"
cN=$(cdhash "$APP"); cN1=$(cdhash "$src/n1/AnJ Cloud.app")
kN=$(code_of "$APP"); kN1=$(code_of "$src/n1/AnJ Cloud.app")
expect "N's receipt says $kN, N+1's $kN1; different cdhashes" "[[ -n '$kN' && -n '$kN1' ]] && (( kN1 > kN )) && [[ '$cN' != '$cN1' ]]"
expect "the embedded manager is the reviewed source" "cmp -s '$EMB' '$M'"

step "2 --check: the served N+1 verifies"
stage "$zipN1" "$manN1"; check check-good
expect "N's manager and N's verifier accept N+1 (version_code $kN1)" "[[ $rc == 0 ]] && grep -q '\"check\": true' '$ev/check-good.json' && grep -q '\"version_code\": $kN1' '$ev/check-good.json'"
expect "--check leaves the download in place" "[[ -f '$UP/update.zip' && -f '$UP/manifest.json' ]]"

step "3 --check refusals"
sed -E 's/"version": "[^"]*"/"version": "tampered.1"/' "$manN1" > "$ev/manifest-tampered.json"
expect "tampered manifest made" "! cmp -s '$manN1' '$ev/manifest-tampered.json'"
stage "$zipN1" "$ev/manifest-tampered.json"; check check-manifest
expect "tampered manifest refused: signature" "[[ $rc == 1 ]] && grep -q 'signature does not verify' '$ev/check-manifest.err'"
cp "$zipN1" "$ev/archive-tampered.zip"; printf 'x' >> "$ev/archive-tampered.zip"
stage "$ev/archive-tampered.zip" "$manN1"; check check-archive
expect "tampered archive refused: size and SHA-256" "[[ $rc == 1 ]] && grep -q 'signed size and SHA-256' '$ev/check-archive.err'"
stage "$zipN" "$manN"; check check-downgrade
expect "N's own release refused: not newer" "[[ $rc == 1 ]] && grep -q 'not newer' '$ev/check-downgrade.err'"

step "4 hand-over with a tampered archive"
stage "$ev/archive-tampered.zip" "$manN1"; p=$(app_pid)
hand_over apply-tampered
expect "refused (1); the result carries the reason" "[[ $rc == 1 ]] && grep -q '\"ok\": false' '$ev/apply-tampered.result.json' && grep -q 'signed size and SHA-256' '$ev/apply-tampered.result.json'"
expect "the download is deleted" "[[ ! -e '$UP/update.zip' && ! -e '$UP/manifest.json' ]]"
expect "N is unchanged and started again (new process)" "[[ \$(cdhash '$APP') == '$cN' ]] && wait_pid '$p'"
expect "the restarted N read the outcome" read_by_app

step "5 failed launch rolls back"
stage "$zipN1" "$manN1"; p=$(app_pid)
# Holds the profile once N has quit, so N+1 exits 73 (profile in use).
perl -MFcntl=:flock -e 'open(my $f, "+<", $ARGV[0]) or die "open: $!"; flock($f, LOCK_EX) or die "flock: $!"; open(my $o, ">", $ARGV[1]); print $o "held\n"; close $o; sleep 900' \
  "$PROFILE/.instance.lock" "$ev/lock-held" &
holder=$!
hand_over apply-rollback
kill $holder 2>/dev/null; wait $holder 2>/dev/null
expect "the profile was held while N+1 started" "[[ -f '$ev/lock-held' ]]"
expect "rolled back; the result says the previous release was restored" "grep -q 'rolled_back' '$ev/apply-rollback.json' && grep -q 'previous release was restored' '$ev/apply-rollback.result.json'"
expect "N is back in place" "[[ \$(cdhash '$APP') == '$cN' && \$(code_of '$APP') == '$kN' ]]"
expect "the download is deleted" "[[ ! -e '$UP/update.zip' ]]"
[[ -z $(app_pid) ]] && open -a "$APP"
expect "N starts again once the profile is free" "wait_pid ''"
expect "and reads the outcome" read_by_app

step "6 hand-over: N -> N+1"
stage "$zipN1" "$manN1"; p=$(app_pid)
hand_over apply-good
p2=$(app_pid)
expect "installed (0); the result says $kN1" "[[ $rc == 0 ]] && grep -q '\"ok\": true' '$ev/apply-good.result.json' && grep -q '\"version_code\": $kN1' '$ev/apply-good.result.json'"
expect "N+1 is installed and running in a new process" "[[ \$(cdhash '$APP') == '$cN1' && \$(code_of '$APP') == '$kN1' ]] && wait_pid '$p'"
p2=$(app_pid)
sleep 2
expect "with its window shown" "windows '$p2' > '$ev/n1-windows.jsonl'"
expect "N+1 read the outcome as it started (its Updated notice)" read_by_app
screencapture -x "$ev/n1-screen.png" 2>/dev/null
expect "N kept as the previous release" "[[ \$(cdhash '$PREV') == '$cN' ]]"
expect "seal verifies in place" "codesign --verify --deep --strict '$APP'"
expect "the download is deleted, no lock or private copy left" "[[ ! -e '$UP/update.zip' && ! -e '$UP/manifest.json' && ! -e '$inst/.anj-cloud-apply.lock' ]] && [[ -z \$(ls '$inst/.anj-cloud-manager' | grep -E '^apply') ]]"
sh "$M" status --apps-dir "$inst" > "$ev/status.json" 2>&1
cp "$inst/.anj-cloud-manager/log" "$ev/manager.log" 2>/dev/null

step "cleanup"
quit_app
sh "$M" uninstall --remove-profile --apps-dir "$inst" > "$ev/uninstall.json" 2> "$ev/uninstall.err"
expect "uninstall --remove-profile" "[[ $? == 0 && ! -e '$APP' && ! -e '$PROFILE' ]]"
[[ -e $AGENT ]] && { launchctl bootout "gui/$(id -u)/cloud.anj.anj-cloud" 2>/dev/null; rm -f "$AGENT"; }
rm -rf "$src" "$inst"
step "done"
if (( failed )); then print "r2_guest: FAILED"; else print "r2_guest: all steps passed"; fi
exit $failed
