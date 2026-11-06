#!/usr/bin/env bash
# Hermetic tests for anj-cloud-macos-install.sh (spec #31 M6). Runs on the VM host
# (or the guest) without macOS: a mktemp HOME, and fakes first on PATH for
# ditto, xattr, codesign, plutil, launchctl, open, ps and security. App
# processes are real `sleep` processes the fake ps reports under the
# bundle's executable path; the fake launchd starts RunAtLoad jobs the same
# way. Quarantine is a registry the fake xattr keeps; a quarantined bundle
# never starts (Gatekeeper). The manager runs under each shell in $SHELLS
# (default: bash --posix, and zsh in sh emulation when installed; on the
# guest the run list adds macOS's /bin/sh, so BSD userland is covered too).
#
#   bash tool/macos/test_manager.sh        exit 0 = all pass
#   SHELLS='/bin/sh|bash --posix' bash tool/macos/test_manager.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
M="$here/anj-cloud-macos-install.sh"
base=$(cd "$(mktemp -d)" && pwd -P)  # macOS: /var -> /private/var
export FAKE="$base/fake" FAKE_MANAGER="$M" FAKE_HARNESS=$$
trap 'kill_all; rm -rf -- "$base"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok    $*"; }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; [ -f "$base/out" ] && sed 's/^/      | /' "$base/out" | tail -15; }
expect() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
kill_all() { [ -f "$FAKE/procs" ] && for p in $(cut -f1 "$FAKE/procs"); do kill -KILL "$p" 2>/dev/null; done; true; }
B=cloud.anj.anj-cloud

# ---- fakes ------------------------------------------------------------------
bin="$base/bin"; mkdir -p "$bin"
cat > "$bin/_lib.sh" <<'EOF'
# Shared by the fakes. $FAKE holds: procs (pid TAB exe TAB args), xattrs
# (path TAB name), launchd/ (loaded plist, job pid), calls.
alive() { kill -0 "$1" 2>/dev/null; }
quarantined() { # path or anything under it... or any parent
  [ -f "$FAKE/xattrs" ] || return 1
  awk -F'\t' -v p="$1" '$2 == "com.apple.quarantine" && (index($1, p) == 1 || index(p, $1) == 1) { f = 1 } END { exit !f }' "$FAKE/xattrs"
}
running_exe() { # live pid running exe $1
  [ -f "$FAKE/procs" ] || return 1
  while IFS="$(printf '\t')" read -r pid exe args; do
    [ "$exe" = "$1" ] && alive "$pid" && { echo "$pid"; return 0; }
  done < "$FAKE/procs"
  return 1
}
# SIGKILLs the manager that called this fake (every ancestor running the
# manager script: a pipeline stage is a subshell of it). No cleanup runs.
killmgr() {
  p=$PPID victims=
  # Only between this fake and the test harness, and only the manager.
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$p" != "$FAKE_HARNESS" ]; do
    case "$(/bin/ps -o args= -p "$p" 2>/dev/null)" in *"$FAKE_MANAGER"*) victims="$victims $p" ;; esac
    p=$(/bin/ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
  [ -n "$victims" ] && kill -KILL $victims 2>/dev/null
  echo "killed the manager" >> "$FAKE/calls"
}
# Starts the app executable $1 with args; prints the pid (none: not started).
start_exe() {
  exe=$1; shift
  app=${exe%/Contents/MacOS/AnJ Cloud}
  echo "start $exe $*" >> "$FAKE/calls"
  [ -n "${FAKE_KILL_ON_START:-}" ] && { killmgr; exit 1; }
  [ -x "$exe" ] || return 1
  quarantined "$app" && { echo "gatekeeper-blocked $app" >> "$FAKE/calls"; return 1; }
  if [ -e "$app/Contents/FAKE_CRASH" ]; then
    nohup sleep 0.3 >/dev/null 2>&1 &
  elif [ -e "$app/Contents/FAKE_IGNORE_TERM" ]; then
    nohup sh -c 'trap "" TERM; while :; do sleep 1; done' >/dev/null 2>&1 &
  else
    nohup sleep 300 >/dev/null 2>&1 &
  fi
  pid=$!
  printf '%s\t%s\t%s\n' "$pid" "$exe" "$*" >> "$FAKE/procs"
  echo "$pid"
}
EOF
fake() { { echo '#!/usr/bin/env bash'; echo '. "$(dirname "$0")/_lib.sh"'; cat; } > "$bin/$1"; chmod +x "$bin/$1"; }

fake ps <<'EOF'
echo "ps $*" >> "$FAKE/calls.ps"
if [ "$1" = -axo ]; then
  [ -f "$FAKE/procs" ] || exit 0
  while IFS="$(printf '\t')" read -r pid exe args; do alive "$pid" && echo "  $pid $exe"; done < "$FAKE/procs"
elif [ "$1" = -o ] && [ "$2" = args= ] && [ "$3" = -p ]; then
  while IFS="$(printf '\t')" read -r pid exe args; do [ "$pid" = "$4" ] && echo "$exe $args"; done < "$FAKE/procs"
fi
exit 0
EOF
fake open <<'EOF'
echo "open $*" >> "$FAKE/calls"
app=$1; shift
[ "${1:-}" = --args ] && shift
[ -d "$app" ] || exit 1
if running_exe "$app/Contents/MacOS/AnJ Cloud" >/dev/null; then echo "reopen $app" >> "$FAKE/calls"; exit 0; fi
# FAKE_RESULT_AT_OPEN: what the app would read as it starts (apply-update).
[ -n "${FAKE_RESULT_AT_OPEN:-}" ] && { cat "$FAKE_RESULT_AT_OPEN" 2>/dev/null || echo none; } >> "$FAKE/result-at-open"
start_exe "$app/Contents/MacOS/AnJ Cloud" "$@" >/dev/null
exit 0
EOF
fake ditto <<'EOF'
echo "ditto $*" >> "$FAKE/calls"
[ "$1" = -x ] && [ "$2" = -k ] || exit 2
unzip -q "$3" -d "$4" || exit 1
[ -n "${FAKE_DITTO_KILL:-}" ] && { killmgr; exit 1; }
# FAKE_START_DURING_STAGE: the user opens the installed app meanwhile.
[ -n "${FAKE_START_DURING_STAGE:-}" ] && start_exe "$FAKE_START_DURING_STAGE" >/dev/null
# A member named .fake-quarantine stands for xattrs stored in the archive:
# every extracted path comes out quarantined (ditto keeps them).
if find "$4" -name .fake-quarantine | grep -q .; then
  find "$4" -name .fake-quarantine -delete
  find "$4" | while read -r f; do printf '%s\tcom.apple.quarantine\n' "$f" >> "$FAKE/xattrs"; done
fi
EOF
fake xattr <<'EOF'
echo "xattr $*" >> "$FAKE/calls"
touch "$FAKE/xattrs"
case "$1" in
  -dr) [ -n "${FAKE_XATTR_STUCK:-}" ] && exit 1
       awk -F'\t' -v p="$3" '!($2 == "com.apple.quarantine" && index($1, p) == 1)' "$FAKE/xattrs" > "$FAKE/x.tmp"; mv "$FAKE/x.tmp" "$FAKE/xattrs" ;;
  -r) awk -F'\t' -v p="$2" 'index($1, p) == 1 { print $1 ": " $2 }' "$FAKE/xattrs" ;;
  -w) printf '%s\t%s\n' "$4" "$2" >> "$FAKE/xattrs" ;;
esac
exit 0
EOF
fake plutil <<'EOF'
if [ "$1" = -extract ] && [ "$(head -c1 "$6")" = "{" ]; then
  python3 -c 'import json,sys
v = json.load(open(sys.argv[2])).get(sys.argv[1])
if v is None: sys.exit(1)
print(v)' "$2" "$6"
elif [ "$1" = -extract ]; then
  awk -v k="<key>$2</key>" 'found { if (match($0, /<string>[^<]*<\/string>/)) { s = substr($0, RSTART + 8, RLENGTH - 17); print s; exit 0 } }
    index($0, k) { found = 1 } END { if (!found) exit 1 }' "$6"
elif [ "$1" = -lint ]; then
  head -1 "$2" | grep -q '^<?xml' && grep -q '</plist>' "$2"
fi
EOF
fake codesign <<'EOF'
echo "codesign $*" >> "$FAKE/calls"
app=${@: -1}
case "$1" in
  --verify) [ ! -e "$app/Contents/FAKE_BAD_SEAL" ] ;;
  -dvvv)
    id=$(cat "$app/Contents/FAKE_SIGN_ID" 2>/dev/null || plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")
    echo "Executable=$app/Contents/MacOS/AnJ Cloud" >&2
    echo "Identifier=$id" >&2
    if [ -e "$app/Contents/FAKE_NO_RUNTIME" ]; then echo "CodeDirectory v=20400 size=1 flags=0x2(adhoc) hashes=1+1" >&2
    else echo "CodeDirectory v=20500 size=1 flags=0x10002(adhoc,runtime) hashes=1+1" >&2; fi
    echo "CDHash=$(cat "$app/Contents/Info.plist" "$app/Contents/MacOS/AnJ Cloud" | shasum -a 1 | cut -c1-40)" >&2
    echo "Signature=adhoc" >&2 ;;
  -d) [ -e "$app/Contents/FAKE_DEBUG" ] && echo '<key>com.apple.security.get-task-allow</key><true/>'; true ;;
esac
EOF
fake mv <<'EOF'
# FAKE_MV_FAIL_SRC: a glob; a move whose source matches it fails.
# FAKE_MV_KILL_AT=N: the manager is killed at its Nth mv, before the move
# or (FAKE_MV_KILL_WHEN=after) right after it.
src=; for a in "$@"; do case "$a" in --|-f) ;; *) [ -z "$src" ] && src=$a ;; esac; done
n=$(( $(cat "$FAKE/mvcount" 2>/dev/null || echo 0) + 1 )); echo $n > "$FAKE/mvcount"
echo "mv#$n $src" >> "$FAKE/calls"
kill_now() { [ -n "${FAKE_MV_KILL_AT:-}" ] && [ "$n" = "$FAKE_MV_KILL_AT" ] && [ "${FAKE_MV_KILL_WHEN:-before}" = "$1" ]; }
kill_now before && { killmgr; exit 1; }
if [ -n "${FAKE_MV_FAIL_SRC:-}" ]; then case "$src" in $FAKE_MV_FAIL_SRC) echo "mv refused: $src" >> "$FAKE/calls"; exit 1 ;; esac; fi
/bin/mv "$@"; rc=$?
kill_now after && { killmgr; exit $rc; }
exit $rc
EOF
fake security <<'EOF'
echo "security $*" >> "$FAKE/calls.security"
if [ "$1" = delete-generic-password ]; then
  case "$*" in *"${FAKE_SECURITY_REFUSE:-@none@}"*) exit 36 ;; esac
  exit "${FAKE_SECURITY_RC:-0}"
fi
exit 0
EOF
fake sqlite3 <<'EOF'
# The profile id from a manifest (the test manifests are plain text).
echo "sqlite3 $*" >> "$FAKE/calls"
[ -n "${FAKE_PROFILE_ID:-}" ] && echo "$FAKE_PROFILE_ID"
exit 0
EOF
fake launchctl <<'EOF'
echo "launchctl $*" >> "$FAKE/calls"
d="$FAKE/launchd"; mkdir -p "$d"
[ -n "${FAKE_NO_GUI:-}" ] && { echo "Bootstrap failed: 125: Domain does not support specified action" >&2; exit 125; }
job_start() {
  exe=$(awk '/<key>ProgramArguments<\/key>/ { f = 1; next } f && /<string>/ { sub(/^[^>]*>/, ""); sub(/<.*$/, ""); gsub(/&amp;/, "\\&"); print; exit }' "$d/loaded.plist")
  pid=$(start_exe "$exe" --background) && echo "$pid" > "$d/pid"
  true
}
job_pid() { p=$(cat "$d/pid" 2>/dev/null) && alive "$p" && echo "$p"; }
case "$1" in
  print) [ -f "$d/loaded.plist" ] || exit 113
         echo "gui/$(id -u)/cloud.anj.anj-cloud = {"
         p=$(job_pid) && { echo "	state = running"; echo "	pid = $p"; } || echo "	state = not running"
         echo "}" ;;
  bootstrap) [ -f "$d/loaded.plist" ] && { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
             cp "$3" "$d/loaded.plist"; job_start ;;
  bootout) [ -f "$d/loaded.plist" ] || exit 113
           p=$(job_pid) && kill -TERM "$p"; rm -f "$d/loaded.plist" "$d/pid" ;;
  kickstart) [ -f "$d/loaded.plist" ] || exit 113
             job_pid >/dev/null || job_start ;;
esac
EOF

# ---- fixtures ---------------------------------------------------------------
# make_zip <name> <version> [marker...]: an "AnJ Cloud.app" archive; markers
# are files under Contents/ (FAKE_CRASH, FAKE_BAD_SEAL, ...) or the special
# words quarantine (stored xattrs), two-apps, wrong-id, no-manager.
make_zip() {
  name=$1 version=$2; shift 2
  w="$base/build/$name"; rm -rf "$w"; mkdir -p "$w/AnJ Cloud.app/Contents/MacOS" "$w/AnJ Cloud.app/Contents/Resources"
  id=$B
  for m in "$@"; do [ "$m" = wrong-id ] && id=cloud.anj.other; done
  cat > "$w/AnJ Cloud.app/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$id</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>${version##*.}</string>
</dict>
</plist>
PL
  printf '#!/bin/sh\nif [ "$1" = --verify-update ]; then exec "%s" "%s" "$0" "$@"; fi\necho %s\n' \
    "${PY:-python3}" "$VERIFIER" "$version" > "$w/AnJ Cloud.app/Contents/MacOS/AnJ Cloud"
  chmod +x "$w/AnJ Cloud.app/Contents/MacOS/AnJ Cloud"
  cp "$M" "$w/AnJ Cloud.app/Contents/Resources/anj-cloud-macos-install.sh"
  for m in "$@"; do
    case "$m" in
      quarantine) touch "$w/AnJ Cloud.app/.fake-quarantine" ;;
      two-apps) mkdir -p "$w/Other.app" ;;
      wrong-id) ;;
      receipt=*) printf '{"version_code": %s, "version": "%s", "target": "macos-arm64", "platform": "macOS arm64"}\n' \
        "${m#receipt=}" "$version" > "$w/AnJ Cloud.app/Contents/Resources/bundle-receipt.json" ;;
      receipt-target=*) printf '{"version_code": %s, "version": "%s", "target": "%s"}\n' "${version##*.}" "$version" \
        "${m#receipt-target=}" > "$w/AnJ Cloud.app/Contents/Resources/bundle-receipt.json" ;;
      key=*) d="$w/AnJ Cloud.app/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/release"
        mkdir -p "$d"; cp "${m#key=}" "$d/household-release-key.pub" ;;
      no-manager) rm "$w/AnJ Cloud.app/Contents/Resources/anj-cloud-macos-install.sh" ;;
      FAKE_SIGN_ID) echo cloud.anj.impostor > "$w/AnJ Cloud.app/Contents/FAKE_SIGN_ID" ;;
      *) touch "$w/AnJ Cloud.app/Contents/$m" ;;
    esac
  done
  rm -f "$base/$name.zip"
  (cd "$w" && zip -qry "$base/$name.zip" .)
  shasum -a 256 "$base/$name.zip" | cut -d' ' -f1
}

setup() {
  kill_all
  rm -rf -- "$base/home" "$FAKE" "$base/build" "$base"/*.zip
  H="$base/home"; mkdir -p "$H/Library/Application Support/$B/anj-cloud/default" "$FAKE"
  echo "user state" > "$H/Library/Application Support/$B/anj-cloud/default/manifest.sqlite"
  A="$H/Applications"; APP="$A/AnJ Cloud.app"; PREV="$A/AnJ Cloud.previous.app"
  AGENT="$H/Library/LaunchAgents/cloud.anj.anj-cloud.plist"
  EXE="$APP/Contents/MacOS/AnJ Cloud"
}
mgr() { # runs the manager; status in $rc, stdout in $base/json, all output in $base/out
  HOME="$H" PATH="$bin:$PATH" ANJ_MANAGER_LAUNCH_WAIT=3 ANJ_MANAGER_LAUNCH_STABLE=1 ANJ_MANAGER_QUIT_WAIT=2 \
    $SH "$M" "$@" > "$base/json" 2> "$base/err"
  rc=$?
  cat "$base/json" "$base/err" > "$base/out"
  json_check
}
# Every stdout is one JSON object (the app parses autostart's with
# AutostartState.fromJson: enabled, source, problem).
json_check() {
  [ -s "$base/json" ] || return 0
  if ! python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
assert isinstance(d, dict)
a = d.get("autostart", d) if "enabled" not in d else d
if "enabled" in a: assert isinstance(a["enabled"], bool) and isinstance(a["source"], str) and (a["problem"] is None or isinstance(a["problem"], str))
' "$base/json" 2>/dev/null; then
    bad "stdout is not the expected JSON object"
  fi
}
mgr_from() { # runs a copy of the manager at path $1 (the embedded one)
  m=$1; shift
  HOME="$H" PATH="$bin:$PATH" $SH "$m" "$@" > "$base/json" 2> "$base/err"
  rc=$?
  cat "$base/json" "$base/err" > "$base/out"
  json_check
}
js() { grep -q -- "$1" "$base/json"; }
tree_sig() { (cd "$H" && find . -print | LC_ALL=C sort; cat "$A/.anj-cloud-manager/state" 2>/dev/null) | shasum -a 256; }
pid_of() { awk -F'\t' -v e="$1" '$2 == e { print $1 }' "$FAKE/procs" 2>/dev/null | while read -r p; do kill -0 "$p" 2>/dev/null && echo "$p"; done | tail -1; }
app_version() { sed -n 's/^echo //p' "$1/Contents/MacOS/AnJ Cloud"; }
calls() { cat "$FAKE/calls" 2>/dev/null; }

suite() {
echo "## usage"
setup
for args in "" "frobnicate" "install" "install x.zip" "update x.zip --sha256" "autostart" "autostart maybe" "install x.zip --sha256 $(printf 'a%.0s' $(seq 64)) --restart"; do
  eval mgr $args
  expect "usage '$args' exits 64" "[ $rc = 64 ]"
done

echo "## install: refusals change nothing"
setup
v1=$(make_zip v1 0.1.1)
mgr install "$base/v1.zip" --sha256 abc
expect "short --sha256 refused (1)" "[ $rc = 1 ]"
mkdir -p "$A"; before=$(tree_sig)
mgr install "$base/v1.zip" --sha256 "$(printf '0%.0s' $(seq 64))"
expect "wrong SHA-256 refused (1)" "[ $rc = 1 ] && grep -q 'SHA-256 mismatch' '$base/err'"
expect "wrong SHA-256: nothing left in Applications" "[ \"\$(tree_sig)\" = \"$before\" ]"
expect "wrong SHA-256: archive never extracted" "! calls | grep -q ditto"
mgr update "$base/v1.zip" --sha256 "$v1"
expect "update before install refused" "[ $rc = 1 ] && grep -q 'use install' '$base/err'"
for case_ in "wrong-id|bundle id is 'cloud.anj.other'" "two-apps|exactly one" "no-manager|no embedded manager" \
    "FAKE_BAD_SEAL|fails codesign --verify" "FAKE_NO_RUNTIME|not a Release build" \
    "FAKE_DEBUG|get-task-allow" "FAKE_SIGN_ID|names another identifier"; do
  kind=${case_%%|*} why=${case_#*|}
  s=$(make_zip bad 0.1.9 $kind)
  mgr install "$base/bad.zip" --sha256 "$s"
  expect "archive with $kind refused ($why), nothing changed" "[ $rc = 1 ] && grep -qF \"$why\" '$base/err' && [ \"\$(tree_sig)\" = \"$before\" ]"
done
expect "the bad archives hold one app each (no leftovers between cases)" "[ \"\$(unzip -Z1 '$base/bad.zip' | grep -c '^[^/]*\.app/$')\" = 1 ]"
mkdir -p "$APP"
mgr install "$base/v1.zip" --sha256 "$v1"
expect "a foreign AnJ Cloud.app at the target is refused and kept" "[ $rc = 1 ] && grep -q 'not installed by this manager' '$base/err' && [ -d '$APP' ]"
rmdir "$APP"
ln -s "$base" "$H/Apps-link"
mgr install "$base/v1.zip" --sha256 "$v1" --apps-dir "$H/Apps-link"
expect "a symlinked --apps-dir is refused" "[ $rc = 1 ] && [ ! -e '$base/AnJ Cloud.app' ]"
rm "$H/Apps-link"
mgr install "$base/v1.zip" --sha256 "$v1" --apps-dir relative/dir
expect "a relative --apps-dir is usage (64)" "[ $rc = 64 ]"

echo "## install: first install"
setup
v1=$(make_zip v1 0.1.1)
mgr install "$base/v1.zip" --sha256 "$(echo "$v1" | tr a-f A-F)"
expect "install exits 0 (upper-case hash accepted)" "[ $rc = 0 ]"
expect "app in ~/Applications" "[ \"\$(app_version '$APP')\" = 0.1.1 ]"
expect "result JSON" "js '\"result\": \"installed\"' && js '\"version\": \"0.1.1\"' && js '\"launch_checked\": true' && js '\"previous_kept\": false'"
expect "records are private" "[ \"\$(ls -ld '$A/.anj-cloud-manager' | cut -c1-10)\" = drwx------ ]"
expect "staging and lock removed" "! ls -A '$A' | grep -q -e stage -e lock"
expect "LaunchAgent written, on by default" "[ -f '$AGENT' ] && grep -q '<string>$EXE</string>' '$AGENT' && grep -q -- '--background' '$AGENT' && grep -q 'LimitLoadToSessionType' '$AGENT'"
expect "autostart JSON: enabled, default, loads at the next login" "js '\"enabled\": true, \"source\": \"default\", \"state\": \"on\", \"loaded\": false'"
expect "a first install starts once, through LaunchServices, with its window (no agent start: one process)" "[ \"\$(calls | grep -c '^start ')\" = 1 ] && calls | grep -q \"^start $EXE \$\" && ! calls | grep -q 'launchctl bootstrap'"
expect "app running" "[ -n \"\$(pid_of '$EXE')\" ]"
expect "profile untouched" "[ \"\$(cat '$H/Library/Application Support/$B/anj-cloud/default/manifest.sqlite')\" = 'user state' ]"
expect "keychain never touched (no security calls)" "[ ! -e '$FAKE/calls.security' ]"
mgr status
expect "status JSON" "[ $rc = 0 ] && js '\"installed\": true' && js '\"running\": true' && js '\"previous\": null' && js \"$v1\""
mgr install "$base/v1.zip" --sha256 "$v1"
expect "install while running is busy (75)" "[ $rc = 75 ]"

echo "## update over a running instance"
v2=$(make_zip v2 0.1.2)
old=$(pid_of "$EXE"); before=$(tree_sig)
mgr update "$base/v2.zip" --sha256 "$v2"
expect "update while running without --restart: busy (75)" "[ $rc = 75 ] && grep -q 'pass --restart' '$base/err'"
expect "  nothing changed, app still running" "[ \"\$(tree_sig)\" = \"$before\" ] && kill -0 $old"
mgr update "$base/v2.zip" --sha256 "$(printf 'f%.0s' $(seq 64))" --restart
expect "update --restart with a wrong hash: refused before quitting" "[ $rc = 1 ] && kill -0 $old && [ \"\$(tree_sig)\" = \"$before\" ]"
mgr update "$base/v2.zip" --sha256 "$v2" --restart
expect "update --restart exits 0" "[ $rc = 0 ] && js '\"result\": \"updated\"' && js '\"previous_kept\": true'"
expect "  old process quit (SIGTERM)" "! kill -0 $old 2>/dev/null"
expect "  new release installed and running" "[ \"\$(app_version '$APP')\" = 0.1.2 ] && [ -n \"\$(pid_of '$EXE')\" ]"
expect "  previous release kept" "[ \"\$(app_version '$PREV')\" = 0.1.1 ]"
expect "  profile and keychain untouched" "[ \"\$(cat '$H/Library/Application Support/$B/anj-cloud/default/manifest.sqlite')\" = 'user state' ] && [ ! -e '$FAKE/calls.security' ]"
mgr status
expect "  status names the previous release" "js '\"previous\": {' && js '0.1.1' && js \"$v1\""
v3=$(make_zip v3 0.1.3)
mgr update "$base/v3.zip" --sha256 "$v3" --restart
expect "a second update keeps one previous (0.1.2)" "[ $rc = 0 ] && [ \"\$(app_version '$PREV')\" = 0.1.2 ] && [ \"\$(app_version '$APP')\" = 0.1.3 ]"

echo "## a swap that fails puts everything back"
setup
v1=$(make_zip v1 0.1.1); v2=$(make_zip v2 0.1.2); v3=$(make_zip v3 0.1.3)
mgr install "$base/v1.zip" --sha256 "$v1"
mgr update "$base/v2.zip" --sha256 "$v2" --restart
old=$(pid_of "$EXE")
FAKE_MV_FAIL_SRC='*/.anj-cloud-stage.*/x/AnJ Cloud.app' mgr update "$base/v3.zip" --sha256 "$v3" --restart
expect "new app cannot be moved in: refused (1), installed release kept" "[ $rc = 1 ] && [ \"\$(app_version '$APP')\" = 0.1.2 ] && grep -q 'installed release was kept' '$base/err'"
expect "  previous slot restored, no journal or staging left" "[ \"\$(app_version '$PREV')\" = 0.1.1 ] && [ ! -e '$A/.anj-cloud-manager/journal' ] && ! ls -A '$A' | grep -q stage"
expect "  the quit app was started again" "! kill -0 $old 2>/dev/null && [ -n \"\$(pid_of '$EXE')\" ]"
mgr status
expect "  records unchanged (0.1.2, previous 0.1.1)" "js '\"version\": \"0.1.2\"' && js \"$v1\""

echo "## update when the app is not running"
setup
v1=$(make_zip v1 0.1.1); v2=$(make_zip v2 0.1.2)
mgr install "$base/v1.zip" --sha256 "$v1" --no-launch
expect "install --no-launch: not started" "[ $rc = 0 ] && js '\"launch_checked\": false' && [ -z \"\$(pid_of '$EXE')\" ]"
mgr update "$base/v2.zip" --sha256 "$v2"
expect "update starts it hidden (--background) and checks it" "[ $rc = 0 ] && js '\"launch_checked\": true' && calls | grep -q \"start $EXE --background\" && ! calls | grep -q reopen"

echo "## rollback when the new release does not stay running"
setup
v1=$(make_zip v1 0.1.1); bad=$(make_zip v2 0.1.2 FAKE_CRASH)
mgr install "$base/v1.zip" --sha256 "$v1"
old=$(pid_of "$EXE")
mgr update "$base/v2.zip" --sha256 "$bad" --restart
expect "update to a crashing release exits 2" "[ $rc = 2 ] && js '\"result\": \"rolled_back\"' && grep -q 'previous release (0.1.1) was restored' '$base/err'"
expect "  0.1.1 is back in place and running again" "[ \"\$(app_version '$APP')\" = 0.1.1 ] && [ -n \"\$(pid_of '$EXE')\" ] && js '\"relaunched\": true'"
expect "  the failed release is gone, no previous slot" "[ ! -e '$PREV' ] && ! ls -A '$A' | grep -q stage"
mgr status
expect "  records name 0.1.1 again" "js '\"version\": \"0.1.1\"' && js \"$v1\" && js '\"previous\": null'"
expect "  profile untouched" "[ \"\$(cat '$H/Library/Application Support/$B/anj-cloud/default/manifest.sqlite')\" = 'user state' ]"
setup
bad=$(make_zip v1 0.1.1 FAKE_CRASH)
mgr install "$base/v1.zip" --sha256 "$bad"
expect "a first install that crashes is removed (exit 2)" "[ $rc = 2 ] && [ ! -e '$APP' ] && [ ! -e '$A/.anj-cloud-manager' ] && [ ! -e '$AGENT' ] && [ ! -e '$FAKE/launchd/loaded.plist' ]"

echo "## quarantine"
setup
v1=$(make_zip v1 0.1.1)
printf '%s\tcom.apple.quarantine\n' "$base/v1.zip" >> "$FAKE/xattrs"
mgr install "$base/v1.zip" --sha256 "$v1"
expect "a quarantined (downloaded) zip installs; the copy carries no quarantine" "[ $rc = 0 ] && [ -n \"\$(pid_of '$EXE')\" ] && ! calls | grep -q gatekeeper-blocked"
setup
v1=$(make_zip v1 0.1.1 quarantine)
mgr install "$base/v1.zip" --sha256 "$v1"
expect "stored quarantine xattrs are removed before the first launch" "[ $rc = 0 ] && ! grep -q '$APP' '$FAKE/xattrs' && ! calls | grep -q gatekeeper-blocked"
setup
v1=$(make_zip v1 0.1.1 quarantine)
FAKE_XATTR_STUCK=1 mgr install "$base/v1.zip" --sha256 "$v1"
expect "quarantine that cannot be removed: refused, nothing installed" "[ $rc = 1 ] && [ ! -e '$APP' ]"

echo "## quit that does not finish"
setup
v1=$(make_zip v1 0.1.1 FAKE_IGNORE_TERM); v2=$(make_zip v2 0.1.2)
mgr install "$base/v1.zip" --sha256 "$v1"
old=$(pid_of "$EXE"); before=$(tree_sig)
mgr update "$base/v2.zip" --sha256 "$v2" --restart
expect "update --restart when the app does not quit: busy, nothing swapped" "[ $rc = 75 ] && [ \"\$(tree_sig)\" = \"$before\" ] && kill -0 $old"
kill -KILL "$old"

echo "## start at login"
setup
v1=$(make_zip v1 0.1.1); v2=$(make_zip v2 0.1.2)
mgr install "$base/v1.zip" --sha256 "$v1"
kill_all
mgr autostart on
p=$(pid_of "$EXE")
expect "on while stopped after install: launchd starts it hidden" "[ $rc = 0 ] && [ -n \"$p\" ] && js '\"loaded\": true'"
mgr autostart off
expect "off: agent removed, choice is the user's" "[ $rc = 0 ] && [ ! -e '$AGENT' ] && js '\"enabled\": false, \"source\": \"user\"'"
expect "off while launchd runs the app: the job is not unloaded (that would stop it)" "kill -0 $p && [ -f '$FAKE/launchd/loaded.plist' ] && js '\"loaded\": true'"
mgr update "$base/v2.zip" --sha256 "$v2" --restart
expect "an update keeps Start at login off" "[ $rc = 0 ] && [ ! -e '$AGENT' ] && js '\"enabled\": false'"
mgr autostart status
expect "status: off" "[ $rc = 0 ] && js '\"enabled\": false'"
mgr autostart on
expect "on while running: agent written, not loaded again" "[ $rc = 0 ] && [ -f '$AGENT' ] && js '\"enabled\": true, \"source\": \"user\"'"
kill_all; rm -rf "$FAKE/launchd"
mgr autostart off
mgr autostart on
expect "on while not running: loaded now, which starts it hidden (the login path)" "[ $rc = 0 ] && js '\"loaded\": true' && [ -n \"\$(pid_of '$EXE')\" ] && calls | tail -3 | grep -q \"start $EXE --background\""
kill_all
mgr autostart off
expect "off while not running: unloaded" "[ $rc = 0 ] && [ ! -f '$FAKE/launchd/loaded.plist' ] && js '\"loaded\": false'"
mgr autostart on
p=$(pid_of "$EXE")
mgr autostart off
expect "off while launchd's process runs: still loaded, agent file gone, says next login" "[ $rc = 0 ] && [ -f '$FAKE/launchd/loaded.plist' ] && kill -0 $p && [ ! -e '$AGENT' ] && js 'off (takes effect at next login)'"
kill -TERM "$p"; sleep 0.5
mgr autostart off
expect "off again after launchd's app quit: the stale job is unloaded" "[ $rc = 0 ] && [ ! -f '$FAKE/launchd/loaded.plist' ]"
mgr autostart on
expect "on again: loaded, app started hidden" "[ $rc = 0 ] && js '\"loaded\": true' && [ -n \"\$(pid_of '$EXE')\" ]"
kill_all
mgr autostart on
expect "on while loaded but stopped: kicked, app started" "[ $rc = 0 ] && [ -n \"\$(pid_of '$EXE')\" ] && calls | grep -q kickstart"
kill_all
echo '<plist>someone else</plist>' > "$AGENT"
mgr autostart on
expect "a foreign agent at the path is reported and left alone" "[ $rc = 0 ] && js '\"enabled\": false' && js 'not written by this manager' && grep -q 'someone else' '$AGENT'"
rm "$AGENT"
FAKE_NO_GUI=1 mgr autostart on
expect "no GUI session: agent written, problem reported" "[ $rc = 0 ] && [ -f '$AGENT' ] && js 'next login'"

echo "## the embedded manager (the app's toggle)"
emb="$APP/Contents/Resources/anj-cloud-macos-install.sh"
mgr_from "$emb" autostart status
expect "embedded copy finds its install from its own path" "[ $rc = 0 ] && js '\"enabled\": true'"
mkdir -p "$base/dev/AnJ Cloud.app/Contents/Resources"; cp "$M" "$base/dev/AnJ Cloud.app/Contents/Resources/"
mgr_from "$base/dev/AnJ Cloud.app/Contents/Resources/anj-cloud-macos-install.sh" autostart status
expect "a build that was not installed: status fails (toggle hidden)" "[ $rc = 1 ] && ! [ -e '$base/dev/.anj-cloud-manager' ]"

echo "## interrupted swap and the lock"
setup
v1=$(make_zip v1 0.1.1); v2=$(make_zip v2 0.1.2)
mgr install "$base/v1.zip" --sha256 "$v1" --no-launch
mv "$APP" "$PREV"; mkdir "$A/.anj-cloud-stage.XXXXXX"
mkdir -p "$A/.anj-cloud-stage.dead/x/AnJ Cloud.app"; : > "$A/.anj-cloud-stage.dead/.anj-cloud-stage"
mkdir -p "$A/.anj-cloud-stage.unmarked/keep"
mgr status
expect "status alone repairs nothing" "[ ! -e '$APP' ]"
mgr update "$base/v2.zip" --sha256 "$v2" --no-launch
expect "a missing app gets its previous release back (no journal), then the update runs" "[ $rc = 0 ] && grep -q 'previous release was put back' '$base/err' && [ \"\$(app_version '$APP')\" = 0.1.2 ] && [ \"\$(app_version '$PREV')\" = 0.1.1 ]"
expect "  marked and empty staging removed; an unmarked folder is left alone" "[ ! -e '$A/.anj-cloud-stage.dead' ] && [ ! -e '$A/.anj-cloud-stage.XXXXXX' ] && [ -d '$A/.anj-cloud-stage.unmarked/keep' ]"
rm -rf "$A/.anj-cloud-stage.unmarked"
sleep 300 & holder=$!
mkdir "$A/.anj-cloud-manager.lock"; echo $holder > "$A/.anj-cloud-manager.lock/pid"
mgr autostart off
expect "a live lock holder: busy (75)" "[ $rc = 75 ] && grep -q 'Another manager command' '$base/err'"
kill $holder; wait $holder 2>/dev/null
mgr autostart off
expect "a stale lock is taken over" "[ $rc = 0 ] && [ ! -e '$A/.anj-cloud-manager.lock' ]"

echo "## refusals before staging"
setup
v1=$(make_zip v1 0.1.1); v2=$(make_zip v2 0.1.2)
mgr install "$base/v1.zip" --sha256 "$v1" --no-launch
mkdir -p "$PREV/Contents"; before=$(tree_sig)
mgr update "$base/v2.zip" --sha256 "$v2"
expect "a previous slot that is not an AnJ Cloud bundle: refused, left alone" "[ $rc = 1 ] && grep -q 'is not an AnJ Cloud bundle' '$base/err' && [ \"\$(tree_sig)\" = \"$before\" ]"
rm -rf "$PREV"
mgr update "$base/v2.zip" --sha256 "$v2" --no-launch
HOME="$H" PATH="$bin:$PATH" open "$PREV" >/dev/null; before=$(tree_sig)
v3=$(make_zip v3 0.1.3)
mgr update "$base/v3.zip" --sha256 "$v3" --restart
expect "the previous release running: busy (75), nothing changed" "[ $rc = 75 ] && [ \"\$(tree_sig)\" = \"$before\" ]"
kill_all
FAKE_START_DURING_STAGE="$EXE" mgr update "$base/v3.zip" --sha256 "$v3"
expect "the app started while staging: busy (75), nothing swapped, staging gone" "[ $rc = 75 ] && [ \"\$(app_version '$APP')\" = 0.1.2 ] && ! ls -A '$A' | grep -q stage"
kill_all
FAKE_DITTO_KILL=1 mgr update "$base/v3.zip" --sha256 "$v3"
expect "killed while staging: staging left behind" "ls -A '$A' | grep -q stage"
mgr autostart off
expect "  the next command removes it" "[ $rc = 0 ] && ! ls -A '$A' | grep -q stage && [ \"\$(app_version '$APP')\" = 0.1.2 ]"

rm -rf "$APP" "$PREV"
mgr update "$base/v3.zip" --sha256 "$v3"
expect "app and previous both missing: refused, advising uninstall only then" "[ $rc = 1 ] && grep -q 'no previous release is kept; run uninstall' '$base/err'"

echo "## kill or fail at every step: one working app afterwards"
# The end state after the re-run: 0.1.2 installed with matching records,
# 0.1.1 kept as previous, no journal, parked or staged copies. In the
# killed-update cases the re-run is the same update again, which runs to its
# end (0.1.3 if it works, else rolled back to 0.1.2).
one_app() { # expected installed version, expected previous version
  [ "$(app_version "$APP")" = "$1" ] && [ "$(app_version "$PREV")" = "$2" ] &&
  [ "$(sed -n 's/^version=//p' "$A/.anj-cloud-manager/state")" = "$1" ] &&
  [ ! -e "$APP/Contents/FAKE_CRASH" ] &&
  ! ls -A "$A/.anj-cloud-manager" | grep -q -e journal -e old-previous -e state.before -e discard &&
  ! ls -A "$A" | grep -q stage
}
if [ "$SH" = "${list[0]}" ]; then
  for when in before after; do
    for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
      setup
      v1=$(make_zip v1 0.1.1); v2=$(make_zip v2 0.1.2); bad=$(make_zip v3 0.1.3 FAKE_CRASH)
      mgr install "$base/v1.zip" --sha256 "$v1" --no-launch
      mgr update "$base/v2.zip" --sha256 "$v2" --no-launch
      rm -f "$FAKE/mvcount"
      FAKE_MV_KILL_AT=$n FAKE_MV_KILL_WHEN=$when ANJ_MANAGER_LAUNCH_WAIT=1 mgr update "$base/v3.zip" --sha256 "$bad"
      ANJ_MANAGER_LAUNCH_WAIT=1 mgr update "$base/v3.zip" --sha256 "$bad"
      expect "rollback, killed $when mv #$n, then re-run: 0.1.2 installed, 0.1.1 kept" "[ $rc = 2 ] && one_app 0.1.2 0.1.1"
    done
    for n in 1 2 3 4 5 6 7 8; do
      setup
      v1=$(make_zip v1 0.1.1); v2=$(make_zip v2 0.1.2); v3=$(make_zip v3 0.1.3)
      mgr install "$base/v1.zip" --sha256 "$v1" --no-launch
      mgr update "$base/v2.zip" --sha256 "$v2" --no-launch
      rm -f "$FAKE/mvcount"
      FAKE_MV_FAIL_SRC='*/.anj-cloud-stage.*/x/AnJ Cloud.app' FAKE_MV_KILL_AT=$n FAKE_MV_KILL_WHEN=$when \
        mgr update "$base/v3.zip" --sha256 "$v3" --no-launch
      mgr autostart off
      expect "refused swap, killed $when mv #$n, then any command: 0.1.2 installed, 0.1.1 kept" "[ $rc = 0 ] && one_app 0.1.2 0.1.1"
    done
  done
  setup
  v1=$(make_zip v1 0.1.1); v2=$(make_zip v2 0.1.2); v3=$(make_zip v3 0.1.3)
  mgr install "$base/v1.zip" --sha256 "$v1" --no-launch
  mgr update "$base/v2.zip" --sha256 "$v2" --no-launch
  FAKE_KILL_ON_START=1 mgr update "$base/v3.zip" --sha256 "$v3"
  mgr autostart off
  expect "killed during the launch check: the unchecked release is undone" "[ $rc = 0 ] && grep -q 'Undid an interrupted' '$base/err' && one_app 0.1.2 0.1.1"
  setup
  v1=$(make_zip v1 0.1.1); v2=$(make_zip v2 0.1.2)
  mgr install "$base/v1.zip" --sha256 "$v1" --no-launch
  FAKE_KILL_ON_START=1 mgr update "$base/v2.zip" --sha256 "$v2"
  HOME="$H" PATH="$bin:$PATH" open "$APP" >/dev/null; p=$(pid_of "$EXE")
  mgr_from "$APP/Contents/Resources/anj-cloud-macos-install.sh" autostart off
  expect "a pending undo from the app's own toggle (app running): busy (75), nothing changed" "[ $rc = 75 ] && kill -0 $p && [ -f '$A/.anj-cloud-manager/journal' ] && [ \"\$(app_version '$APP')\" = 0.1.2 ]"
  mgr autostart off
  expect "  the next run from outside the app undoes it" "[ $rc = 0 ] && ! kill -0 $p 2>/dev/null && [ \"\$(app_version '$APP')\" = 0.1.1 ] && [ ! -f '$A/.anj-cloud-manager/journal' ]"
  for junk in "" "first=yes"; do
    setup
    v1=$(make_zip v1 0.1.1); v2=$(make_zip v2 0.1.2)
    mgr install "$base/v1.zip" --sha256 "$v1" --no-launch
    mgr update "$base/v2.zip" --sha256 "$v2" --no-launch
    printf '%s' "$junk" > "$A/.anj-cloud-manager/journal"; before=$(tree_sig)
    mgr autostart off
    expect "an unreadable journal ('$junk'): refused, no undo, nothing changed" "[ $rc = 1 ] && grep -q 'journal .* is unreadable' '$base/err' && [ \"\$(tree_sig)\" = \"$before\" ] && [ \"\$(app_version '$APP')\" = 0.1.2 ]"
  done
  for n in 1 2 3 4 5 6; do
    setup
    bad=$(make_zip v1 0.1.1 FAKE_CRASH)
    rm -f "$FAKE/mvcount"
    FAKE_MV_KILL_AT=$n ANJ_MANAGER_LAUNCH_WAIT=1 mgr install "$base/v1.zip" --sha256 "$bad"
    mgr status
    mgr uninstall
    expect "first install killed at mv #$n: afterwards nothing is installed and nothing is left" "[ $rc = 0 ] && [ ! -e '$APP' ] && [ ! -e '$PREV' ] && [ ! -e '$A/.anj-cloud-manager' ] && ! ls -A '$A' | grep -q stage"
  done
fi

echo "## uninstall"
setup
v1=$(make_zip v1 0.1.1); v2=$(make_zip v2 0.1.2)
mgr install "$base/v1.zip" --sha256 "$v1"
mgr update "$base/v2.zip" --sha256 "$v2" --restart
mgr uninstall
expect "uninstall while running: busy, nothing removed" "[ $rc = 75 ] && [ -d '$APP' ] && [ -f '$AGENT' ]"
kill_all
mgr uninstall
expect "uninstall removes the app, the previous release, the agent and the records" "[ $rc = 0 ] && [ ! -e '$APP' ] && [ ! -e '$PREV' ] && [ ! -e '$AGENT' ] && [ ! -e '$A/.anj-cloud-manager' ] && [ ! -f '$FAKE/launchd/loaded.plist' ]"
expect "  and keeps the profile, saying so" "[ -f '$H/Library/Application Support/$B/anj-cloud/default/manifest.sqlite' ] && js 'profile_kept' && js 'keychain_kept'"
mgr status
expect "status after uninstall: not installed" "js '\"installed\": false'"
v1=$(make_zip v1 0.1.1); v2=$(make_zip v2 0.1.2)
mgr install "$base/v1.zip" --sha256 "$v1" --no-launch
mgr update "$base/v2.zip" --sha256 "$v2" --no-launch
rm "$A/.anj-cloud-manager/state"
mgr uninstall
expect "without records, uninstall keeps the bundles (the installed guard)" "[ $rc = 0 ] && [ -d '$APP' ] && [ -d '$PREV' ] && js 'not installed by this manager'"
rm -rf "$APP"
mgr uninstall
expect "uninstall never deletes a previous release when the app is missing" "[ $rc = 1 ] && [ -d '$PREV' ] && grep -q 'only copy left' '$base/err'"
rm -rf "$PREV"
mkdir -p "$APP"
mgr uninstall
expect "uninstall never removes a bundle it did not install" "[ $rc = 0 ] && [ -d '$APP' ] && js 'not installed by this manager'"

echo "## uninstall --remove-profile (PR #72 review L4)"
setup
P="$H/Library/Application Support/$B/anj-cloud/default"
mkdir -p "$H/anj-cloud/Documents" && echo mine > "$H/anj-cloud/Documents/keep.txt"
v1=$(make_zip v1 0.1.1)
mgr install "$base/v1.zip" --sha256 "$v1" --no-launch
export FAKE_PROFILE_ID=1a2b3c4d-0000-4000-8000-00000000abcd
mgr uninstall
expect "plain uninstall lists the kept keychain accounts and the command that removes them" "[ $rc = 0 ] && js 'anj-cloud:$FAKE_PROFILE_ID:device-key' && js 'anj-cloud:$FAKE_PROFILE_ID:invitation' && js 'uninstall --remove-profile' && [ -f '$P/manifest.sqlite' ] && [ ! -e '$FAKE/calls.security' ]"
mgr install "$base/v1.zip" --sha256 "$v1" --no-launch
FAKE_SECURITY_RC=36 mgr uninstall --remove-profile
expect "a keychain that refuses (locked over SSH): refused, nothing removed" "[ $rc = 1 ] && [ -d '$APP' ] && [ -f '$P/manifest.sqlite' ] && grep -q 'logged-in desktop session' '$base/err'"
rm -f "$FAKE/calls.security"
FAKE_SECURITY_REFUSE=":device-key" mgr uninstall --remove-profile
first=$(head -1 "$FAKE/calls.security" 2>/dev/null)
expect "the invitation goes first; a refused device key names what was already removed (delta review L5)" "[ $rc = 1 ] && [ -d '$APP' ] && [ -f '$P/manifest.sqlite' ] && case '$first' in *:invitation) true ;; *) false ;; esac && grep -q 'Already removed: anj-cloud:$FAKE_PROFILE_ID:invitation' '$base/err'"
rm -f "$FAKE/calls.security"
mgr uninstall --remove-profile
deletes=$(grep -c "delete-generic-password -s $B -a anj-cloud:$FAKE_PROFILE_ID:" "$FAKE/calls.security" 2>/dev/null)
expect "--remove-profile deletes both keychain items, the profile and the app" "[ $rc = 0 ] && [ ! -e '$APP' ] && [ ! -e '$P' ] && [ '$deletes' = 2 ]"
kept=$(cat "$H/anj-cloud/Documents/keep.txt")
expect "  and never touches the synced folder" "[ '$kept' = mine ] && js 'root_kept'"
mkdir -p "$P" && echo "user state" > "$P/manifest.sqlite"
mgr install "$base/v1.zip" --sha256 "$v1" --no-launch
FAKE_SECURITY_RC=44 mgr uninstall --remove-profile
expect "items already gone (errSecItemNotFound): the profile is still removed" "[ $rc = 0 ] && [ ! -e '$P' ]"
mgr install "$base/v1.zip" --sha256 "$v1" --remove-profile
expect "--remove-profile is for uninstall only" "[ $rc = 64 ]"
unset FAKE_PROFILE_ID

echo "## apply-update (spec #40 R2)"
if [ -z "$APPLY_TOOLS" ]; then
  echo "skip  apply-update: the reference verifier needs Python 3.11+ and an OpenSSL with Ed25519 (base macOS has neither; tool/macos/check_r2.sh proves the app's own verifier there)"
else
running() { [ -n "$(pid_of "$EXE")" ]; }
setup
UP="$H/Library/Application Support/$B/anj-cloud/default/updates"
mkdir -p "$UP"; chmod 700 "$UP"
K="$base/keys"; rm -rf "$K"; mkdir -p "$K"
"$OPENSSL" genpkey -algorithm ed25519 -out "$K/k.pem" 2>/dev/null
"$OPENSSL" genpkey -algorithm ed25519 -out "$K/other.pem" 2>/dev/null
pubfile() { # pem -> the app's key file (ed25519 <base64 raw>)
  raw=$("$OPENSSL" pkey -in "$1" -pubout -outform DER 2>/dev/null | tail -c 32 | base64)
  printf '# test key\ned25519 %s\n' "$raw" > "$2"
}
pubfile "$K/k.pem" "$K/k.pub"
kid=$("$OPENSSL" pkey -in "$K/k.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | shasum -a 256 | cut -c1-16)
# sign <pem> <zip> <target> <version> <code> [size] [sha] [key_id]: a manifest in $UP
sign() {
  size=${6:-$(wc -c < "$2" | tr -d ' ')}; sha=${7:-$(shasum -a 256 "$2" | cut -d' ' -f1)}; key=${8:-$kid}
  printf 'anj-cloud release v1\ntarget %s\nversion %s\nversion_code %s\nsize %s\nsha256 %s\nkey_id %s\n' \
    "$3" "$4" "$5" "$size" "$sha" "$key" > "$K/msg"
  "$OPENSSL" pkeyutl -sign -inkey "$1" -rawin -in "$K/msg" -out "$K/sig" 2>/dev/null
  printf '{"target": "%s", "version": "%s", "version_code": %s, "size": %s, "sha256": "%s", "key_id": "%s", "signature": "%s"}\n' \
    "$3" "$4" "$5" "$size" "$sha" "$key" "$(base64 < "$K/sig" | tr -d '\n')" > "$UP/manifest.json"
}
v1=$(make_zip v1 2026.11.06.100 receipt=100 "key=$K/k.pub")
mgr install "$base/v1.zip" --sha256 "$v1"
expect "apply-update setup: N installed and running" "[ $rc = 0 ] && running"
v2=$(make_zip v2 2026.11.06.101 receipt=101 "key=$K/k.pub")
stage() { cp "$base/v2.zip" "$UP/update.zip"; }

stage; sign "$K/k.pem" "$UP/update.zip" macos-arm64 2026.11.06.101 101
mgr apply-update "$UP/update.zip" --manifest "$UP/manifest.json" --check
expect "--check: a signed, newer release verifies; nothing changes or is deleted" "[ $rc = 0 ] && js '\"check\": true' && [ -f '$UP/update.zip' ] && [ \"\$(app_version '$APP')\" = 2026.11.06.100 ]"

for case_ in "signature|signature does not verify" "hash|SHA-256" "size|SHA-256" "key_id|different key" \
    "downgrade|not newer" "target|another platform" "otherkey|signature does not verify" \
    "receipt|receipt does not match"; do
  kind=${case_%%|*} why=${case_#*|}
  stage
  case $kind in
    signature) sign "$K/k.pem" "$UP/update.zip" macos-arm64 2026.11.06.101 101
      sed -i.bak 's/"version": "2026.11.06.101"/"version": "2026.11.06.109"/' "$UP/manifest.json" ;;
    hash) sign "$K/k.pem" "$UP/update.zip" macos-arm64 2026.11.06.101 101 "" "$(printf '0%.0s' $(seq 64))" ;;
    size) sign "$K/k.pem" "$UP/update.zip" macos-arm64 2026.11.06.101 101 7 ;;
    key_id) sign "$K/k.pem" "$UP/update.zip" macos-arm64 2026.11.06.101 101 "" "" 0123456789abcdef ;;
    downgrade) sign "$K/k.pem" "$UP/update.zip" macos-arm64 2026.11.06.100 100 ;;
    target) sign "$K/k.pem" "$UP/update.zip" linux-x86_64 2026.11.06.101 101 ;;
    otherkey) sign "$K/other.pem" "$UP/update.zip" macos-arm64 2026.11.06.101 101 ;;
    receipt) bad=$(make_zip v2r 2026.11.06.101 receipt=102 "key=$K/k.pub"); cp "$base/v2r.zip" "$UP/update.zip"
      sign "$K/k.pem" "$UP/update.zip" macos-arm64 2026.11.06.101 101 ;;
  esac
  rm -f "$UP/manifest.json.bak"
  mgr apply-update "$UP/update.zip" --manifest "$UP/manifest.json" --check
  expect "--check refuses a tampered $kind ($why)" "[ $rc = 1 ] && grep -qF \"$why\" '$base/err'"
  kill_all
  mgr apply-update "$UP/update.zip" --manifest "$UP/manifest.json" --result "$UP/result.json"
  expect "apply-update refuses a tampered $kind: nothing installed" "[ $rc = 1 ] && [ \"\$(app_version '$APP')\" = 2026.11.06.100 ]"
  expect "  download deleted" "[ ! -e '$UP/update.zip' ] && [ ! -e '$UP/manifest.json' ]"
  expect "  outcome written" "grep -q '\"ok\": false' '$UP/result.json'"
  expect "  app started again" "running"
  rm -f "$UP/result.json"
done

stage; sign "$K/k.pem" "$UP/update.zip" macos-arm64 2026.11.06.101 101
ln -s "$UP/update.zip" "$base/outside.zip"
mgr apply-update "$base/outside.zip" --manifest "$UP/manifest.json" --check
expect "update files outside the profile's updates folder are refused" "[ $rc = 1 ] && grep -q 'private updates folder' '$base/err'"
chmod 755 "$UP"
mgr apply-update "$UP/update.zip" --manifest "$UP/manifest.json" --check
expect "an updates folder others can read is refused" "[ $rc = 1 ] && grep -q 'private updates folder' '$base/err'"
chmod 700 "$UP"
mgr apply-update "$UP/update.zip" --manifest "$UP/manifest.json" --check --result "$UP/result.json"
expect "--check takes no --result" "[ $rc = 64 ]"

kill_all
pid_before=$(pid_of "$EXE")
rm -f "$FAKE/result-at-open"
FAKE_RESULT_AT_OPEN=$UP/result.json mgr apply-update "$UP/update.zip" --manifest "$UP/manifest.json" --result "$UP/result.json"
expect "apply-update installs N+1 from the verified copy" "[ $rc = 0 ] && [ \"\$(app_version '$APP')\" = 2026.11.06.101 ] && [ \"\$(app_version '$PREV')\" = 2026.11.06.100 ]"
expect "  writes ok with the version" "grep -q '\"ok\": true.*2026.11.06.101' '$UP/result.json'"
expect "  before N+1 starts (the app reads it as it starts)" "grep -q '\"ok\": true.*2026.11.06.101' '$FAKE/result-at-open'"
expect "  deletes the download" "[ ! -e '$UP/update.zip' ] && [ ! -e '$UP/manifest.json' ]"
expect "  and starts N+1 with its window (not --background)" "running && ! grep '$EXE' '$FAKE/procs' | tail -1 | grep -q -- --background"
expect "  and leaves no private copy or staging behind" "! ls -A '$A/.anj-cloud-manager' | grep -q '^apply' && ! ls -A '$A' | grep -q 'anj-cloud-stage\|apply.lock'"

# The app is still running when the manager starts: it waits for the quit.
rm -f "$UP/result.json"
v3=$(make_zip v3 2026.11.06.102 receipt=102 "key=$K/k.pub")
cp "$base/v3.zip" "$UP/update.zip"; sign "$K/k.pem" "$UP/update.zip" macos-arm64 2026.11.06.102 102
app=$(pid_of "$EXE")
( sleep 1; kill "$app" ) &
ANJ_MANAGER_APPLY_WAIT=10 mgr apply-update "$UP/update.zip" --manifest "$UP/manifest.json" --result "$UP/result.json" --app-pid "$app"
expect "apply-update waits for the app that handed over to quit, then installs" "[ $rc = 0 ] && [ \"\$(app_version '$APP')\" = 2026.11.06.102 ]"

# A release that does not stay running is rolled back; the previous runs again.
rm -f "$UP/result.json"; kill_all
v4=$(make_zip v4 2026.11.06.103 receipt=103 "key=$K/k.pub" FAKE_CRASH)
cp "$base/v4.zip" "$UP/update.zip"; sign "$K/k.pem" "$UP/update.zip" macos-arm64 2026.11.06.103 103
rm -f "$FAKE/result-at-open"
FAKE_RESULT_AT_OPEN=$UP/result.json mgr apply-update "$UP/update.zip" --manifest "$UP/manifest.json" --result "$UP/result.json"
expect "a failed launch rolls back: the release before is restored and started" "[ $rc = 1 ] && [ \"\$(app_version '$APP')\" = 2026.11.06.102 ] && running"
expect "  the outcome says so" "grep -q '\"ok\": false.*restored' '$UP/result.json'"
expect "  and the restored release starts with that outcome, not the new one's" "tail -1 '$FAKE/result-at-open' | grep -q '\"ok\": false.*restored'"

# The app still running past the wait: nothing installed, said so.
rm -f "$UP/result.json"
cp "$base/v4.zip" "$UP/update.zip"; sign "$K/k.pem" "$UP/update.zip" macos-arm64 2026.11.06.103 103
app=$(pid_of "$EXE")
ANJ_MANAGER_APPLY_WAIT=1 mgr apply-update "$UP/update.zip" --manifest "$UP/manifest.json" --result "$UP/result.json" --app-pid "$app"
expect "an app that does not quit in time: nothing installed, outcome says so" \
  "[ $rc = 1 ] && [ \"\$(app_version '$APP')\" = 2026.11.06.102 ] && grep -q 'did not quit in time' '$UP/result.json'"

# A release with no receipt cannot vouch for updates.
kill_all; setup
mkdir -p "$UP"; chmod 700 "$UP"
v0=$(make_zip v0 2026.11.06.099 "key=$K/k.pub")
mgr install "$base/v0.zip" --sha256 "$v0" --no-launch
v2=$(make_zip v2 2026.11.06.101 receipt=101 "key=$K/k.pub")
cp "$base/v2.zip" "$UP/update.zip"; sign "$K/k.pem" "$UP/update.zip" macos-arm64 2026.11.06.101 101
mgr apply-update "$UP/update.zip" --manifest "$UP/manifest.json" --check
expect "an installed release without a receipt refuses (install updates by hand)" "[ $rc = 1 ] && grep -q 'no release receipt' '$base/err'"
fi
}

VERIFIER="$here/verify_update_reference.py"
# apply-update's cases run the app's verifier as tool/macos/
# verify_update_reference.py (linux_install.py's Ed25519: Python 3.11+) and
# sign with a throwaway key (an OpenSSL with Ed25519).
PY= OPENSSL= APPLY_TOOLS=
for c in python3.14 python3.13 python3.12 python3.11 python3; do
  command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null &&
    { PY=$(command -v "$c"); break; }
done
for c in openssl /opt/homebrew/opt/openssl@3/bin/openssl /opt/homebrew/bin/openssl; do
  command -v "$c" >/dev/null 2>&1 && "$c" genpkey -algorithm ed25519 >/dev/null 2>&1 &&
    { OPENSSL=$(command -v "$c"); break; }
done
[ -n "$PY" ] && [ -n "$OPENSSL" ] && APPLY_TOOLS=1
shells=${SHELLS:-"bash --posix|zsh --emulate sh"}
IFS='|' read -r -a list <<< "$shells"
for SH in "${list[@]}"; do
  command -v ${SH%% *} >/dev/null 2>&1 || { echo "skip  shell ${SH%% *} (not installed)"; continue; }
  echo "# manager under: $SH"
  suite
done
echo "test_manager: $pass passed, $fail failed"
[ $fail = 0 ]
