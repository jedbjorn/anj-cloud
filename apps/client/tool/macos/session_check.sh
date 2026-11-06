#!/bin/zsh
# Desktop session check for a Debug "AnJ Cloud.app" (spec #31 M3, acceptance
# rows 8 and 11). Runs ON mac-test as the console user, from SSH. Drives the
# runner's real controls through the Debug-only `ext.anj.desktop` service
# extension (lib/platform/macos/macos_desktop_session.dart,
# macos/Runner/DesktopIntegration.swift), with private profiles in <out>:
#
#   1. menu-bar item: on screen, template icon, the Linux tray's menu;
#      Pause and Resume through the item's own menu
#   2. Close hides the window and the Dock icon (accessory policy)
#   3. reopen through `open -a` shows the window and the Dock icon again
#   4. a second direct launch on the held profile exits 73
#   5. the item's Quit, the app menu's Quit (Cmd-Q) and a quit Apple event
#      (the Dock's Quit, logout) each stop the app and release the lock
#   6. a login start (--background) shows no window and no Dock icon
#   7. a directly launched app (an SSH session: no login keychain) with an
#      enrolled profile shows "Keychain unavailable" and Retry, and starts
#      no worker
#   8. with --idle <minutes>: CPU of a closed-to-menu-bar app (row 12)
#
#   session_check.sh <AnJ Cloud.app (Debug)> <out dir> [--idle <minutes>]
# Exit 0 only when every check passes. Every app it starts is stopped.
set -u
app=${1:?usage: session_check.sh <app> <out> [--idle <minutes>]}
out=${2:?usage}
idle=0
[[ ${3:-} == --idle ]] && idle=${4:?minutes}
app=${app:A}
here=${0:A:h}
exe="$app/Contents/MacOS/AnJ Cloud"
mkdir -p "$out"; out=${out:A}
failed=0
pass() { print -r -- "pass  $1"; }
fail() { print -r -- "FAIL  $1"; failed=1; }
info() { print -r -- "info  $1"; }
pid=; url=; iso=; tag=
stop_app() {
  [[ -n $pid ]] || return 0
  kill -TERM $pid 2>/dev/null
  for i in {1..40}; do kill -0 $pid 2>/dev/null || { pid=; return 0; }; sleep 0.5; done
  kill -KILL $pid 2>/dev/null; pid=
}
trap stop_app EXIT

# `open -a` reaches whichever instance of the bundle is running: refuse to
# run beside another lane's AnJ Cloud.
others=$(pgrep -f '/AnJ Cloud[^/]*\.app/Contents/MacOS/' | tr '\n' ' ')
if [[ -n $others ]]; then
  echo "FAIL  another AnJ Cloud is running (pids $others); stop it first"; exit 1
fi

# launch <tag> <profile> [args...]: through LaunchServices, then find the
# process, its VM service and its root isolate.
launch() {
  tag=$1; local profile=$2; shift 2
  # A disposable HOME, only for launches of a fresh profile (M8: a new
  # profile makes ~/anj-cloud and a Desktop link; tool/macos/check_m8.sh
  # covers the real HOME). Direct launches of a held or seeded profile keep
  # the real HOME: the lock refuses before any root is made, and step 7's
  # "Keychain unavailable" must come from the SSH session, not a fake HOME.
  mkdir -p "$out/home"
  open -n -F --env HOME="$out/home" --stdout "$out/$tag.stdout.log" --stderr "$out/$tag.stderr.log" "$app" \
    --args --profile-dir "$profile" "$@"
  attach "$profile"
}
attach() {
  local profile=$1
  pid=; url=; iso=
  for i in {1..60}; do
    pid=$(pgrep -n -f "^$exe --profile-dir $profile( |\$)")
    [[ -n $pid ]] && break; sleep 0.5
  done
  [[ -n $pid ]] || { fail "$tag: app process started"; return 1; }
  for i in {1..80}; do
    url=$(grep -ohE 'http://127\.0\.0\.1:[0-9]+/[^ ]*/' "$out/$tag.stdout.log" "$out/$tag.stderr.log" 2>/dev/null | head -1)
    [[ -n $url ]] && break; sleep 0.5
  done
  [[ -n $url ]] || { fail "$tag: VM service announced"; return 1; }
  for i in {1..60}; do
    iso=$(curl -s "${url}_flutter.listViews" | /usr/bin/python3 -c 'import json,sys; v=json.load(sys.stdin)["result"]["views"]; print(v[0]["isolate"]["id"] if v and v[0].get("isolate") else "")' 2>/dev/null)
    [[ -n $iso ]] && break; sleep 0.5
  done
  [[ -n $iso ]] || { fail "$tag: root isolate"; return 1; }
}
# desk <action>: the runner's reply as JSON ("null" when the extension is
# not registered yet).
desk() {
  curl -s "${url}ext.anj.desktop?isolateId=$iso&action=$1" |
    /usr/bin/python3 -c 'import json,sys; r=json.load(sys.stdin); print(json.dumps(r.get("result",{}).get("reply")))' 2>/dev/null
}
# field <json> <python expression on s>
field() { /usr/bin/python3 -c "import json,sys; s=json.loads(sys.argv[1]); print($2)" "$1" 2>/dev/null; }
# wait_state <python condition on s> <seconds>: polls the state.
wait_state() {
  local i state
  for i in {1..$(( $2 * 2 ))}; do
    state=$(desk state)
    [[ $(field "$state" "bool(s) and bool($1)") == True ]] && { print -r -- "$state"; return 0; }
    sleep 0.5
  done
  print -r -- "$state"; return 1
}
lock_free() {
  /usr/bin/python3 -c 'import fcntl,sys; f=open(sys.argv[1],"r+"); fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB)' "$1/.instance.lock" 2>/dev/null
}
# gone_and_free <what> <profile>: the process ends within 25 s and the
# profile lock is free afterwards.
gone_and_free() {
  local gone=0
  for i in {1..50}; do kill -0 $pid 2>/dev/null || { gone=1; break; }; sleep 0.5; done
  if (( gone )) && lock_free "$2"; then pass "$1 stops the app and releases the profile lock"; pid=
  else fail "$1 stops the app and releases the profile lock (gone=$gone)"; fi
}
windows() { swift "$here/window_check.swift" $pid 2>/dev/null; }

# 1. Menu-bar item and its menu.
profile=$out/profile-a
if launch a "$profile"; then
  state=$(wait_state "s['statusItem'] and s['windowVisible']" 30)
  print -r -- "$state" > "$out/a.state-open.json"
  if [[ $(field "$state" "s['statusImage'] and s['menu'][2:] == ['Open AnJ Cloud','Pause sync','','Quit AnJ Cloud'] and s['menu'][0].startswith('AnJ Cloud')") == True ]]; then
    pass "menu-bar item with a template icon and the Linux menu: $(field "$state" "s['menu']")"
  else
    fail "menu-bar item and menu: $state"
  fi
  # The item's own window, as AppKit reports it (on macOS 26 the window
  # list does not show status items at the status level; recorded only).
  # The item may report a zero-size frame until the menu bar lays it out.
  # The button's frame must lie in the menu-bar strip at the top of its
  # screen (PR #72 review L2: the window frame alone passed at the bottom
  # left, and the crop then showed the Apple menu).
  ok="s['statusOnScreen'] and s.get('statusInMenuBar') and len(s['statusFrame']) == 4 and s['statusFrame'][3] > 0 and s['statusFrame'][0] > 0"
  state=$(wait_state "$ok" 10)
  print -r -- "$state" > "$out/a.state-status.json"
  if [[ $(field "$state" "$ok") == True ]]; then
    pass "status item in the menu bar at $(field "$state" "s['statusFrame']")"
    rect=$(field "$state" "'%d,%d,%d,%d' % (max(0, s['statusFrame'][0]-24), max(0, s['statusFrame'][1]), s['statusFrame'][2]+48, s['statusFrame'][3])")
    if screencapture -x -R"$rect" "$out/menu-bar.png" 2>/dev/null && [[ -s $out/menu-bar.png ]]; then
      info "menu bar crop $out/menu-bar.png ($rect)"
    else
      fail "menu bar crop"
    fi
  else
    fail "status item on screen: $state"
  fi
  swift "$here/status_item_check.swift" $pid > "$out/a.status-item.jsonl" 2>/dev/null ||
    info "window list shows no status-level window for the app (recorded only)"
  screencapture -x -t jpg "$out/screen-open.jpg" 2>/dev/null
  [[ $(desk statusMenu:togglePause) == true ]] &&
    wait_state "s['menu'][3] == 'Resume sync'" 10 > /dev/null &&
    [[ $(desk statusMenu:togglePause) == true ]] &&
    wait_state "s['menu'][3] == 'Pause sync'" 10 > /dev/null &&
    pass "Pause and Resume through the item's menu" || fail "Pause and Resume through the item's menu"

  # 2. Close hides the window and the Dock icon.
  [[ $(desk window:close) == true ]] || fail "window close button performed"
  state=$(wait_state "not s['windowVisible'] and s['activationPolicy'] == 'accessory'" 10)
  if (( $? == 0 )) && ! windows > /dev/null && kill -0 $pid 2>/dev/null; then
    pass "Close hides the window and the Dock icon; the app keeps running"
  else
    fail "Close hides the window and the Dock icon: $state"
  fi
  lsappinfo info -only ApplicationType "$(lsappinfo find pid=$pid 2>/dev/null)" > "$out/a.lsappinfo-closed.txt" 2>&1
  screencapture -x -t jpg "$out/screen-closed.jpg" 2>/dev/null

  # 3. Reopen through LaunchServices.
  open -a "$app"
  state=$(wait_state "s['windowVisible'] and s['activationPolicy'] == 'regular'" 15)
  if (( $? == 0 )) && windows > /dev/null; then
    pass "open -a reopens the running instance: window and Dock icon shown"
  else
    fail "open -a reopens the running instance: $state"
  fi
  [[ $(pgrep -f "^$exe --profile-dir" | wc -l | tr -d ' ') == 1 ]] && pass "still one process after reopen" || fail "still one process after reopen"

  # 4. Second direct launch.
  "$exe" --profile-dir "$profile" > "$out/a.second.stdout.log" 2> "$out/a.second.stderr.log"
  code=$?
  if [[ $code == 73 ]] && grep -q 'already running' "$out/a.second.stderr.log"; then
    pass "a second direct launch exits 73 (already running)"
  else
    fail "a second direct launch exits 73 (got $code)"
  fi

  # 5a. The item's Quit.
  [[ $(desk statusMenu:quit) == true ]] || fail "menu-bar Quit performed"
  gone_and_free "menu-bar Quit" "$profile"
fi

# 5b. The app menu's Quit (the item Cmd-Q triggers).
if launch b "$profile"; then
  wait_state "s['statusItem']" 30 > /dev/null
  # The app quits before the VM service can answer: the reply is not a
  # result, the process ending is.
  desk appMenu:quit > /dev/null
  gone_and_free "app menu Quit (Cmd-Q)" "$profile"
fi

# 5c. A quit Apple event, as the Dock's Quit and logout send.
if launch c "$profile"; then
  wait_state "s['statusItem']" 30 > /dev/null
  if "$here/gui_run.sh" "$out/c-quit" 60 swift "$here/app_quit.swift" $pid > /dev/null; then
    gone_and_free "a quit Apple event (Dock Quit, logout)" "$profile"
  else
    info "macOS refused to send a quit Apple event from this session; not checked"
    stop_app
  fi
fi

# 6. Login start.
profile_b=$out/profile-b
if launch d "$profile_b" --background; then
  state=$(wait_state "s['statusItem']" 30)
  sleep 2
  state=$(desk state)
  [[ $(field "$state" "s['statusItem']") == True ]] && pass "--background: the engine runs (menu-bar item added)"
  screencapture -x -t jpg "$out/screen-background.jpg" 2>/dev/null
  print -r -- "$state" > "$out/d.state-background.json"
  if [[ $(field "$state" "not s['windowVisible'] and s['activationPolicy'] == 'accessory'") == True ]] && ! windows > /dev/null; then
    pass "--background starts in the menu bar: no window, no Dock icon"
  else
    fail "--background starts in the menu bar: $state"
  fi
  kill -TERM $pid
  gone_and_free "SIGTERM" "$profile_b"
fi

# 7. Keychain unavailable, from a direct (SSH-session) launch.
profile_c=$out/profile-c
if launch e "$profile_c"; then
  wait_state "s['statusItem']" 30 > /dev/null
  [[ $(desk statusMenu:quit) == true ]] && gone_and_free "menu-bar Quit (profile setup)" "$profile_c"
fi
mkdir -p "$out/root-c/anj-cloud"
expires=$(date -u -v+30d +%Y-%m-%dT%H:%M:%S.000Z)
# An enrolled profile whose device key exists in the login keychain (made
# in the GUI session by /usr/bin/security; the test profile id keeps it
# under keychain_items.sh clean anj-test-m3).
ssh_profile_id="anj-test-m3-ssh-$$"
sqlite3 "$profile_c/manifest.sqlite" \
  "insert or replace into settings(key, value) values ('profileId', '$ssh_profile_id'), ('root', '$out/root-c/anj-cloud'), ('staging', '$out/root-c/.anj-cloud-staging'), ('certificate', 'not used: the key read fails first'), ('certificateExpires', '$expires');" ||
  fail "enrolled profile seeded"
"$here/keychain_items.sh" add "anj-cloud:$ssh_profile_id:device-key" "not a key" > /dev/null ||
  fail "device-key item for the SSH launch"
tag=f
"$exe" --profile-dir "$profile_c" > "$out/f.stdout.log" 2> "$out/f.stderr.log" &
if attach "$profile_c"; then
  tree=
  for i in {1..40}; do
    tree=$(curl -s "${url}ext.flutter.debugDumpApp?isolateId=$iso" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["data"])' 2>/dev/null)
    [[ $tree == *'Keychain unavailable'* ]] && break; sleep 0.5
  done
  print -r -- "$tree" > "$out/f.widget-tree.txt"
  if [[ $tree == *'Keychain unavailable'* && $tree == *'retry-secrets'* ]]; then
    pass "an SSH-launched app shows Keychain unavailable with Retry"
  else
    fail "an SSH-launched app shows Keychain unavailable with Retry"
  fi
  if [[ -z $(ls -A "$out/root-c/anj-cloud") && ! -e $out/root-c/.anj-cloud-staging ]]; then
    pass "no worker ran: the root and staging are untouched"
  else
    fail "no worker ran: $(ls -A "$out/root-c")"
  fi
  kill -TERM $pid
  gone_and_free "SIGTERM (keychain unavailable)" "$profile_c"
fi

# 8. Idle cost with the window closed (row 12).
if (( idle > 0 )); then
  profile_d=$out/profile-d
  if launch g "$profile_d"; then
    wait_state "s['statusItem']" 30 > /dev/null
    desk window:close > /dev/null
    wait_state "not s['windowVisible']" 10 > /dev/null
    print -r -- "seconds,cputime" > "$out/idle.csv"
    start=$(date +%s)
    while (( $(date +%s) - start < idle * 60 )); do
      print -r -- "$(( $(date +%s) - start )),$(ps -o cputime= -p $pid | tr -d ' ')" >> "$out/idle.csv"
      sleep 15
    done
    print -r -- "$(( $(date +%s) - start )),$(ps -o cputime= -p $pid | tr -d ' ')" >> "$out/idle.csv"
    /usr/bin/python3 - "$out/idle.csv" <<'EOF'
import csv, sys
def secs(t):
    parts = [float(p) for p in t.replace('-', ':').split(':')]
    total = 0.0
    for p in parts:
        total = total * 60 + p
    return total
rows = list(csv.DictReader(open(sys.argv[1])))
first, last = rows[0], rows[-1]
wall = float(last['seconds']) - float(first['seconds'])
cpu = secs(last['cputime']) - secs(first['cputime'])
print(f"info  idle with the window closed: {cpu:.2f} s CPU over {wall:.0f} s ({100 * cpu / wall:.2f}% of one core)")
EOF
    [[ $(desk statusMenu:quit) == true ]] && gone_and_free "menu-bar Quit (idle run)" "$profile_d"
  fi
fi

if (( failed )); then echo "session_check: FAILED"; else echo "session_check: all checks passed"; fi
exit $failed
