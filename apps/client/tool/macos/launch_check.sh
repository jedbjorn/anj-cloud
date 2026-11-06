#!/bin/zsh
# Launch check for a built "AnJ Cloud.app" (spec #31 M0). Runs ON the guest
# as the console user. Launches through LaunchServices with a private
# profile inside <out>, never ~/Library/Application Support, and records:
#
#   - first frame (debug: the VM service's didSendFirstFrameRasterizedEvent
#     and the widget tree; release: a visible window), the window list and
#     a screenshot;
#   - that a second direct launch on the same profile exits 73 ("already
#     running"), through the embedded dylib's profile lock, and (Release
#     only) ignores DYLD_* insertion (hardened runtime);
#   - that SIGTERM quits cleanly (Dart's DesktopLifecycle.quit).
#
#   launch_check.sh <AnJ Cloud.app> <out dir> debug|profile|release
# Exit 0 only when every check passes. The app is always stopped.
set -u
app=${1:?usage}; out=${2:?usage}; mode=${3:?usage}
here=${0:A:h}
exe="$app/Contents/MacOS/AnJ Cloud"
profile="$out/profile"
# A disposable HOME: since M8 (decision #164) a new profile makes
# ~/anj-cloud and a Desktop link, which a launch check must not leave on
# the guest. tool/macos/check_m8.sh covers the real HOME.
home="$out/home"
mkdir -p "$out"; rm -rf "$profile" "$home"; mkdir -p "$home"
failed=0
pass() { echo "pass  $1"; }
fail() { echo "FAIL  $1"; failed=1; }
pid=
stop_app() {
  [[ -n $pid ]] || return 0
  kill -TERM $pid 2>/dev/null
  for i in {1..40}; do kill -0 $pid 2>/dev/null || return 0; sleep 0.5; done
  kill -KILL $pid 2>/dev/null
}
trap stop_app EXIT

open -n -F --env HOME="$home" --stdout "$out/stdout.log" --stderr "$out/stderr.log" "$app" --args --profile-dir "$profile"
for i in {1..60}; do
  pid=$(pgrep -n -f "^$exe --profile-dir $profile\$")
  [[ -n $pid ]] && break; sleep 0.5
done
if [[ -z $pid ]]; then fail "app process started"; exit 1; fi
sleep 3
if ! kill -0 $pid 2>/dev/null; then
  fail "app still running 3 s after launch"; tail -5 "$out/stderr.log"; pid=; exit 1
fi
pass "app process started through LaunchServices (pid $pid)"

if [[ $mode == debug ]]; then
  url=
  for i in {1..60}; do
    url=$(grep -ohE 'http://127\.0\.0\.1:[0-9]+/[^ ]*/' "$out/stdout.log" "$out/stderr.log" 2>/dev/null | head -1)
    [[ -n $url ]] && break; sleep 0.5
  done
  if [[ -z $url ]]; then
    fail "VM service announced"
  else
    pass "VM service announced"
    iso=
    for i in {1..40}; do
      iso=$(curl -s "${url}_flutter.listViews" | /usr/bin/python3 -c 'import json,sys; v=json.load(sys.stdin)["result"]["views"]; print(v[0]["isolate"]["id"] if v and v[0].get("isolate") else "")' 2>/dev/null)
      [[ -n $iso ]] && break; sleep 0.5
    done
    raster=
    for i in {1..60}; do
      raster=$(curl -s "${url}ext.flutter.didSendFirstFrameRasterizedEvent?isolateId=$iso")
      [[ $raster == *'"enabled":"true"'* ]] && break; sleep 0.5
    done
    echo "$raster" > "$out/first-frame.json"
    if [[ $raster == *'"enabled":"true"'* ]]; then pass "first frame rasterized"; else fail "first frame rasterized"; fi
    curl -s "${url}ext.flutter.debugDumpApp?isolateId=$iso" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["data"])' > "$out/widget-tree.txt" 2>/dev/null
    if grep -q 'CloudApp' "$out/widget-tree.txt"; then pass "widget tree holds CloudApp"; else fail "widget tree holds CloudApp"; fi
  fi
fi

windows=
for i in {1..40}; do
  windows=$(swift "$here/window_check.swift" $pid 2>/dev/null) && break; sleep 0.5
done
echo "$windows" > "$out/windows.jsonl"
if [[ -n $windows ]]; then pass "visible window: $(echo "$windows" | head -1)"; else fail "visible window"; fi
sleep 2
wid=$(echo "$windows" | head -1 | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' 2>/dev/null)
if [[ -n $wid ]] && screencapture -x -o -l$wid "$out/window.png" 2>/dev/null; then
  pass "window screenshot $out/window.png"
else
  fail "window screenshot"
fi
screencapture -x "$out/screen.png" 2>/dev/null || true

if [[ -d $profile && $(stat -f %Lp "$profile") == 700 ]]; then pass "profile created private (0700)"; else fail "profile created private (0700)"; fi

# Second direct launch on the held profile, with DYLD insertion attempted.
DYLD_PRINT_LIBRARIES=1 DYLD_INSERT_LIBRARIES=/usr/lib/libz.dylib \
  # A held profile: the lock refuses before any root is made, real HOME.
  "$exe" --profile-dir "$profile" > "$out/second.stdout.log" 2> "$out/second.stderr.log"
code=$?
echo "exit=$code" >> "$out/second.stdout.log"
if [[ $code == 73 ]] && grep -q 'already running' "$out/second.stderr.log"; then
  pass "second launch exits 73 (already running)"
else
  fail "second launch exits 73 (got $code)"
fi
# Only Release ignores DYLD_*: Debug has no hardened runtime, and Profile
# carries get-task-allow, which lets dyld honour DYLD_* under the runtime.
if [[ $mode == release ]]; then
  if grep -q 'dyld\[' "$out/second.stderr.log"; then fail "DYLD_* ignored (hardened runtime)"; else pass "DYLD_* ignored (hardened runtime)"; fi
elif grep -q 'dyld\[' "$out/second.stderr.log"; then
  echo "info  $mode build honours DYLD_* (never handed out)"
fi
kill -TERM $pid
gone=0
for i in {1..40}; do kill -0 $pid 2>/dev/null || { gone=1; break; }; sleep 0.5; done
if [[ $gone == 1 ]]; then pass "SIGTERM quits within 20 s"; pid=; else fail "SIGTERM quits within 20 s"; fi

# Quit released the lock: a fresh acquisition by a direct launch would now
# start the app, so check the lock file is free instead.
if /usr/bin/python3 -c 'import fcntl,sys; f=open(sys.argv[1],"r+"); fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB)' "$profile/.instance.lock" 2>/dev/null; then
  pass "profile lock released after quit"
else
  fail "profile lock released after quit"
fi
exit $failed
