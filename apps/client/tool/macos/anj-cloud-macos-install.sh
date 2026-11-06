#!/bin/sh
# AnJ Cloud for macOS: the trusted, local-only install and update manager
# (spec #31 M6, decision #42), the counterpart of tool/linux_install.py and
# tool/windows_manager. POSIX sh and base-macOS tools only (shasum, ditto,
# xattr, codesign, launchctl, plutil, open, ps); no Python, no developer
# tools, no network and no sudo.
#
# Obtain this script from reviewed source. An archive checksum cannot vouch
# for the program that checks it: never run a copy merely because it came
# with the archive. A manager install also embeds it in the app bundle
# (Contents/Resources, sealed by the bundle signature); the app runs that
# copy for its Start at login toggle.
#
#   anj-cloud-macos-install.sh install <zip> --sha256 <hex> [options]
#   anj-cloud-macos-install.sh update  <zip> --sha256 <hex> [--restart] [options]
#   anj-cloud-macos-install.sh autostart on|off|status      (also enable|disable)
#   anj-cloud-macos-install.sh status
#   anj-cloud-macos-install.sh uninstall [--remove-profile]
#   anj-cloud-macos-install.sh apply-update <zip> --manifest <file> [--check]
#                                  [--result <file>] [--app-pid <pid>]
#
#   --apps-dir <dir>  install location (default ~/Applications; the embedded
#                     copy uses the folder its bundle is in)
#   --restart         update: quit a running AnJ Cloud first (SIGTERM, its
#                     normal Quit), then relaunch it. Without it a running
#                     app refuses the update and nothing changes.
#   --no-launch       install/update: skip the launch check (and so the
#                     automatic rollback)
#   --window          update: start the new release with its window shown
#                     (apply-update's relaunch; otherwise hidden, #40)
#
# Layout:
#   <apps>/AnJ Cloud.app            the installed app (stable path)
#   <apps>/AnJ Cloud.previous.app   the release it replaced (one kept)
#   <apps>/.anj-cloud-manager/      private records: state, autostart, log
#   ~/Library/LaunchAgents/cloud.anj.anj-cloud.plist   Start at login
# Never touched: the profile (~/Library/Application Support/cloud.anj.anj-cloud),
# the login keychain items, the synced root (~/anj-cloud). The one exception
# is uninstall --remove-profile, which also deletes the default profile and
# its two login keychain items (PR #72 review L4); the synced root and the
# files in it are never touched. Plain uninstall lists the kept items and
# the command that removes them.
#
# install and update: the archive is copied into private staging under
# <apps>, its SHA-256 checked against --sha256 before anything is extracted,
# the bundle extracted with ditto, quarantine removed, and the bundle checked
# (one "AnJ Cloud.app", bundle id cloud.anj.anj-cloud, codesign --verify
# --deep --strict, a Release build: hardened runtime, no get-task-allow,
# the embedded manager). Only then is a running app quit (update --restart),
# the bundles swapped (journalled; an interrupted swap is repaired by the
# next command) and the app launched. If it does not stay running, the
# previous release is put back (a first install is removed) and the
# command exits 2.
#
# apply-update (spec #40 R2, the in-app update; linux_install.py's
# contract): the app has downloaded <zip> and its signed <manifest> into its
# private <profile>/updates folder and quit (or, with --check, asks before
# offering it). This script never trusts the archive by itself: the
# INSTALLED release's executable, sealed by its code signature, verifies it
# (`--verify-update`: the Ed25519 signature by the key built into that
# release, key id, target macos-arm64, version_code above its own, size and
# SHA-256, CryptoKit; base macOS has no Ed25519 tool) on a private copy,
# and the archive's own receipt must name the same version. Only then does
# the update transaction above run, from that copy, with the window shown.
# Installed or refused, the download is deleted, the outcome is written to
# <result> for the app and the app is started again (a failed launch rolls
# back to the release it replaced, which is started instead).
#
# Output: one JSON object on stdout; messages on stderr.
# Exit: 0 done, 1 refused (nothing changed), 2 launch failed and rolled
# back, 64 usage, 75 busy (AnJ Cloud is running, or another manager command).
set -u
umask 077
PATH=$PATH:/usr/bin:/bin:/usr/sbin:/sbin

OWNER=anj-cloud-macos-manager-v1
BUNDLE_ID=cloud.anj.anj-cloud
APP_NAME="AnJ Cloud.app"
PREV_NAME="AnJ Cloud.previous.app"
EXE_REL="Contents/MacOS/AnJ Cloud"
MANAGER_REL="Contents/Resources/anj-cloud-macos-install.sh"
LABEL=cloud.anj.anj-cloud
MAX_BYTES=2147483648
# Launch check: the app must appear within LAUNCH_WAIT seconds and still be
# running LAUNCH_STABLE seconds later. A Quit gets QUIT_WAIT seconds (the
# app's own cap is 30 s). Overridable for the hermetic tests only.
LAUNCH_WAIT=${ANJ_MANAGER_LAUNCH_WAIT:-30}
LAUNCH_STABLE=${ANJ_MANAGER_LAUNCH_STABLE:-5}
QUIT_WAIT=${ANJ_MANAGER_QUIT_WAIT:-40}
# apply-update: how long the app gets to quit after handing over.
APPLY_WAIT=${ANJ_MANAGER_APPLY_WAIT:-120}
RECEIPT_REL="Contents/Resources/bundle-receipt.json"
RELEASE_TARGET=macos-arm64
BUSY="AnJ Cloud is running. Quit it from its menu-bar item (or pass --restart to update) and retry; nothing was changed."

say() { printf 'anj-cloud: %s\n' "$*" >&2; }
refuse() { say "$*"; exit 1; }
usage() { sed -n '14,26p' "$0" >&2; exit 64; }
busy() { say "$*"; exit 75; }

# ---- small helpers ---------------------------------------------------------

json_str() { # JSON string literal; paths with control characters are refused earlier
  printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}
json_opt() { if [ -n "$1" ]; then json_str "$1"; else printf null; fi; }
json_bool() { if [ "$1" = 1 ]; then printf true; else printf false; fi; }
no_controls() {
  case "$1" in *[[:cntrl:]]*) refuse "Control characters in paths are not supported: no changes were made." ;; esac
}
is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
for v in "$LAUNCH_WAIT" "$LAUNCH_STABLE" "$QUIT_WAIT"; do is_uint "$v" || { say "bad timing override"; exit 64; }; done
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
sha_of() { shasum -a 256 "$1" 2>/dev/null | awk '{ print $1 }'; }
owner_uid() { ls -ldn "$1" 2>/dev/null | awk '{ print $3 }'; }
# A real directory (not a symlink) owned by this user.
own_dir() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(owner_uid "$1")" = "$(id -u)" ]; }
private_dir() { own_dir "$1" && case "$(ls -ld "$1" | cut -c1-10)" in drwx------) true ;; *) false ;; esac; }
plist_value() { plutil -extract "$1" raw -o - "$2" 2>/dev/null; }
bundle_id_of() { plist_value CFBundleIdentifier "$1/Contents/Info.plist"; }
ours_bundle() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(bundle_id_of "$1")" = "$BUNDLE_ID" ]; }
cdhash_of() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -1; }

# ---- locations --------------------------------------------------------------

case "${HOME:-}" in /*) ;; *) say "HOME must be an absolute path"; exit 64 ;; esac
no_controls "$HOME"
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT="$AGENT_DIR/$LABEL.plist"
PROFILE="$HOME/Library/Application Support/$BUNDLE_ID/anj-cloud/default"
UID_=$(id -u)

# The folder holding this script's bundle, when this is the embedded copy.
embedded_apps_dir() {
  here=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P) || return 1
  case "$here" in
    */"$APP_NAME"/Contents/Resources) printf '%s\n' "${here%/"$APP_NAME"/Contents/Resources}" ;;
    *) return 1 ;;
  esac
}

set_layout() { # $1 = --apps-dir value or empty
  EMBEDDED=0
  if [ -n "$1" ]; then
    APPS=$1
  elif APPS=$(embedded_apps_dir); then
    EMBEDDED=1
  else
    APPS="$HOME/Applications"
  fi
  case "$APPS" in /*) ;; *) say "--apps-dir must be an absolute path"; exit 64 ;; esac
  APPS=${APPS%/}
  no_controls "$APPS"
  # One spelling of the folder (macOS temporary folders sit behind /var ->
  # /private/var): the LaunchAgent and the process match use exact paths.
  if [ -d "$APPS" ] && [ ! -L "$APPS" ]; then APPS=$(cd -P -- "$APPS" && pwd -P) || exit 64; fi
  TARGET="$APPS/$APP_NAME"
  PREVIOUS="$APPS/$PREV_NAME"
  STATE_DIR="$APPS/.anj-cloud-manager"
  STATE="$STATE_DIR/state"
  CHOICE="$STATE_DIR/autostart"
  JOURNAL="$STATE_DIR/journal"
  OLD_PREV="$STATE_DIR/old-previous.app"
  BEFORE="$STATE_DIR/state.before"
  LOG="$STATE_DIR/log"
  LOCK="$APPS/.anj-cloud-manager.lock"
}

check_apps_dir() { # $1 = create
  if [ ! -e "$APPS" ] && [ "$1" = create ]; then
    mkdir -p "$APPS" && chmod 755 "$APPS" || refuse "Cannot create $APPS."
  fi
  own_dir "$APPS" || refuse "Need a folder you own (not a symlink): $APPS. Nothing was changed."
  if [ -e "$STATE_DIR" ] || [ -L "$STATE_DIR" ]; then
    private_dir "$STATE_DIR" || refuse "Unexpected ownership or permissions: $STATE_DIR. Nothing was changed."
  fi
}

# ---- the transaction lock ---------------------------------------------------

LOCKED=0
STAGE=
cleanup() {
  [ -n "$STAGE" ] && [ -d "$STAGE" ] && rm -rf -- "$STAGE"
  if [ $LOCKED = 1 ]; then rm -f -- "$LOCK/pid"; rmdir -- "$LOCK" 2>/dev/null; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
take_lock() {
  for attempt in 1 2; do
    if mkdir -- "$LOCK" 2>/dev/null; then
      LOCKED=1
      echo $$ > "$LOCK/pid"
      return 0
    fi
    holder=$(cat "$LOCK/pid" 2>/dev/null)
    if is_uint "$holder" && kill -0 "$holder" 2>/dev/null; then
      busy "Another manager command is running (pid $holder); retry when it ends."
    fi
    # Left by a manager that died: only an exact lock directory is removed.
    [ -d "$LOCK" ] && [ ! -L "$LOCK" ] && rm -f -- "$LOCK/pid" && rmdir -- "$LOCK" 2>/dev/null
  done
  busy "Could not take the manager lock $LOCK; retry."
}

log_event() {
  [ -d "$STATE_DIR" ] || return 0
  printf '%s %s\n' "$(now)" "$*" >> "$LOG"
}

# ---- records ----------------------------------------------------------------

get() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -1; }
# Writes the key=value lines $2 to $1 atomically (no partial record);
# returns 1 on failure. Never fed by a pipe: a pipeline stage is a subshell,
# so its failure would not stop the manager.
write_record() {
  tmp="$1.tmp.$$"
  printf '%s\n' "$2" > "$tmp" && mv -f -- "$tmp" "$1" && return 0
  rm -f -- "$tmp"
  say "Could not write $1."
  return 1
}
installed() { [ -f "$STATE" ] && [ "$(get owner "$STATE")" = "$OWNER" ]; }

# ---- the transaction ---------------------------------------------------------
#
# An install or update is one transaction, journalled before anything moves
# and committed only after its launch check. Places (J = the journal's flags):
#   T  <apps>/AnJ Cloud.app           P  <apps>/AnJ Cloud.previous.app
#   O  <records>/old-previous.app     the previous release, parked (J had_prev)
#   B  <records>/state.before         the records before the transaction
#   N  the verified new bundle, in staging
# Forward: J, B; P->O; T->P (J had_target); N->T; records; launch check;
# commit (remove O, B, J). Undo, from any point (rollback, a refused swap, or
# the next command after a kill): the new T goes, P->T, O->P, B->records.
# Every undo step is decided by where things are, so a repeated or
# interrupted undo ends in the same place: the release that was installed
# before, in T, with its records.
discard() { # moves $1 out of sight (one rename), then deletes it
  [ -e "$1" ] || [ -L "$1" ] || return 0
  d=$(mktemp -d "$STATE_DIR/discard.XXXXXX") || return 1
  mv -- "$1" "$d/x" && rm -rf -- "$d"
}
# Whether P now holds the release moved out of T (not the old previous one).
p_is_moved_target() {
  [ -e "$PREVIOUS" ] || return 1
  [ "$(get had_target "$JOURNAL")" = 1 ] || return 1
  [ "$(get had_prev "$JOURNAL")" = 0 ] || [ -e "$OLD_PREV" ]
}
undo_transaction() {
  # The new release is in T exactly when T exists and either nothing was
  # installed before or the old one now sits in P.
  if [ -e "$TARGET" ] && { [ "$(get had_target "$JOURNAL")" = 0 ] || p_is_moved_target; }; then
    stop_app "$TARGET" 1
    discard "$TARGET" || return 1
  fi
  if [ ! -e "$TARGET" ] && p_is_moved_target; then
    mv -- "$PREVIOUS" "$TARGET" || return 1
  fi
  if [ -e "$OLD_PREV" ] && [ ! -e "$PREVIOUS" ]; then
    mv -- "$OLD_PREV" "$PREVIOUS" || return 1
  fi
  if [ "$(get first "$JOURNAL")" = 1 ]; then
    if [ "$(agent_state)" = exact ]; then
      agent_loaded && [ -z "$(agent_pid)" ] && launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null
      rm -f -- "$AGENT"
    fi
    rm -f -- "$STATE" "$CHOICE" "$BEFORE"
  elif [ -f "$BEFORE" ]; then
    mv -f -- "$BEFORE" "$STATE" || return 1
  fi
  rm -f -- "$JOURNAL"
  if [ ! -f "$STATE" ] && [ ! -e "$TARGET" ]; then
    for d in "$STATE_DIR"/discard.*; do [ -d "$d" ] && rm -rf -- "$d"; done
    rm -f -- "$LOG"
    rmdir -- "$STATE_DIR" 2>/dev/null
  fi
  return 0
}
commit_transaction() {
  rm -f -- "$JOURNAL"
  discard "$OLD_PREV"
  rm -f -- "$BEFORE"
}

# Runs first in every command that changes anything (under the lock).
recover() {
  # Staging left by a killed command (marked when made), and empty ones.
  for st in "$APPS"/.anj-cloud-stage.*; do
    [ -d "$st" ] && [ ! -L "$st" ] || continue
    if [ -f "$st/.anj-cloud-stage" ]; then rm -rf -- "$st"; else rmdir -- "$st" 2>/dev/null; fi
  done
  if [ -f "$JOURNAL" ]; then
    # Only a journal this manager wrote is acted on; anything else could
    # put old records over a newer app.
    for k in first had_target had_prev; do
      case "$(get $k "$JOURNAL")" in 0|1) ;; *)
        refuse "The manager's journal $JOURNAL is unreadable; nothing was changed. Check that $TARGET starts, then delete the journal and retry." ;;
      esac
    done
    # The app's own Start at login toggle runs the embedded copy: undoing
    # from there would quit the app that asked. The next manager run from
    # outside the app finishes it.
    if [ "$EMBEDDED" = 1 ] && { running "$TARGET" || running "$PREVIOUS"; }; then
      busy "An interrupted install or update is pending and AnJ Cloud is running; nothing was changed. Quit AnJ Cloud, then run the manager from Terminal."
    fi
    undo_transaction || refuse "An interrupted install could not be undone; nothing else was changed. Retry."
    say "Undid an interrupted install or update: the release installed before it is back in place."
    log_event "undid an interrupted transaction"
  fi
  # Half-written records of a killed command (the records are intact).
  [ -d "$STATE_DIR" ] && for f in "$STATE_DIR"/*.tmp.*; do [ -f "$f" ] && rm -f -- "$f"; done
  # No transaction: leftovers of one that committed, then a missing app
  # with its previous release still there (the previous one goes back).
  [ -d "$STATE_DIR" ] && for d in "$OLD_PREV" "$STATE_DIR"/discard.*; do
    [ -e "$d" ] && rm -rf -- "$d"
  done
  rm -f -- "$BEFORE"
  if installed && [ ! -e "$TARGET" ] && ours_bundle "$PREVIOUS" && ! running "$PREVIOUS"; then
    mv -- "$PREVIOUS" "$TARGET" || refuse "$TARGET is missing and $PREVIOUS could not be put back; nothing was changed."
    write_record "$STATE" "$(printf 'owner=%s\n' "$OWNER"; sed -n 's/^previous_//p' "$STATE")" ||
      refuse "The previous release is back in place, but its records could not be written; retry."
    say "$TARGET was missing: the previous release was put back."
    log_event "previous release restored to a missing app"
  fi
}

# ---- processes --------------------------------------------------------------

# pids of AnJ Cloud processes whose executable is exactly $1/Contents/MacOS/AnJ Cloud.
app_pids() {
  ps -axo pid=,comm= 2>/dev/null |
    ANJ_EXE="$1/$EXE_REL" awk 'BEGIN { exe = ENVIRON["ANJ_EXE"] }
         { pid = $1; sub(/^ *[0-9]+ +/, ""); if ($0 == exe) print pid }'
}
running() { [ -n "$(app_pids "$1")" ]; }
any_background() { # whether a running instance of $1 was started with --background
  for p in $(app_pids "$1"); do
    case " $(ps -o args= -p "$p" 2>/dev/null) " in *" --background "*) return 0 ;; esac
  done
  return 1
}
# Asks every instance of $1 to quit (SIGTERM is the app's own Quit: sync
# stops first) and waits; $2 = 1 sends SIGKILL to what is left at the end.
stop_app() {
  pids=$(app_pids "$1")
  [ -n "$pids" ] || return 0
  for p in $pids; do kill -TERM "$p" 2>/dev/null; done
  waited=0
  while [ $waited -lt $((QUIT_WAIT * 2)) ]; do
    running "$1" || return 0
    sleep 0.5; waited=$((waited + 1))
  done
  if [ "${2:-0}" = 1 ]; then
    for p in $(app_pids "$1"); do kill -KILL "$p" 2>/dev/null; done
    sleep 1
    running "$1" || return 0
  fi
  return 1
}

# ---- start at login ---------------------------------------------------------

agent_xml() {
  exe=$(printf '%s' "$TARGET/$EXE_REL" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$exe</string>
		<string>--background</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>AssociatedBundleIdentifiers</key>
	<string>$BUNDLE_ID</string>
</dict>
</plist>
EOF
}
# absent, exact (what this install writes), ours (an earlier write of this
# manager, by recorded hash) or foreign (anything else: never changed).
agent_state() {
  if [ ! -e "$AGENT" ] && [ ! -L "$AGENT" ]; then echo absent; return; fi
  if [ -L "$AGENT" ] || [ ! -f "$AGENT" ]; then echo foreign; return; fi
  have=$(sha_of "$AGENT")
  if [ "$have" = "$(agent_xml | shasum -a 256 | awk '{ print $1 }')" ]; then echo exact
  elif [ -n "$have" ] && [ "$have" = "$(get agent_sha256 "$CHOICE")" ]; then echo ours
  else echo foreign; fi
}
agent_loaded() { launchctl print "gui/$UID_/$LABEL" >/dev/null 2>&1; }
# The job's live pid, if launchd started the running app.
agent_pid() { launchctl print "gui/$UID_/$LABEL" 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p' | head -1; }
choice_enabled() { [ "$(get enabled "$CHOICE")" != 0 ]; }  # on by default (#40)
choice_source() { s=$(get source "$CHOICE"); echo "${s:-default}"; }
record_choice() { # enabled source agent_sha256
  write_record "$CHOICE" "$(printf 'owner=%s\nenabled=%s\nsource=%s\nagent_sha256=%s' "$OWNER" "$1" "$2" "$3")"
}
AGENT_PROBLEM=
# Makes the LaunchAgent follow the recorded choice. With "load", an enabled
# agent is loaded (or kicked) when the app is not running, which starts it
# hidden at once, exactly as at login; while it runs the agent waits for the
# next login. A disabled agent is unloaded unless launchd's process is the
# running app (unloading stops that process). Sets AGENT_PROBLEM.
apply_agent() { # $1 = load|noload
  AGENT_PROBLEM=
  st=$(agent_state)
  if [ "$st" = foreign ]; then
    AGENT_PROBLEM="$AGENT exists and was not written by this manager; it was left alone."
    return 0
  fi
  if choice_enabled; then
    mkdir -p "$AGENT_DIR" || { AGENT_PROBLEM="Cannot create $AGENT_DIR."; return 0; }
    if [ "$st" != exact ]; then
      if agent_loaded && [ -z "$(agent_pid)" ]; then launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null; fi
      tmp="$AGENT_DIR/.$LABEL.plist.$$"
      agent_xml > "$tmp" && chmod 644 "$tmp" && plutil -lint "$tmp" >/dev/null 2>&1 && mv -f -- "$tmp" "$AGENT" ||
        { rm -f -- "$tmp"; AGENT_PROBLEM="Could not write $AGENT."; return 0; }
      log_event "autostart agent written"
    fi
    record_choice 1 "$(choice_source)" "$(sha_of "$AGENT")"
    # load: as launchd does at login, which starts the app hidden now.
    if [ "$1" = load ] && ! running "$TARGET"; then
      if agent_loaded; then
        launchctl kickstart "gui/$UID_/$LABEL" >/dev/null 2>&1
      else
        launchctl bootstrap "gui/$UID_" "$AGENT" 2>/dev/null
      fi || AGENT_PROBLEM="Start at login is set, but launchd did not load it now (no GUI session?); it loads at the next login."
    fi
  else
    if [ "$st" != absent ]; then
      rm -f -- "$AGENT"
      log_event "autostart agent removed"
    fi
    # A job of ours that is still loaded goes too, unless launchd's process
    # is the running app (unloading would stop it); it ends at logout.
    if agent_loaded && [ -z "$(agent_pid)" ]; then launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null; fi
    record_choice 0 "$(choice_source)" ""
  fi
}
autostart_json() {
  st=$(agent_state)
  enabled=0
  [ "$st" = exact ] && choice_enabled && enabled=1
  problem=$AGENT_PROBLEM
  [ -z "$problem" ] && [ "$st" = foreign ] && problem="$AGENT exists and was not written by this manager."
  loaded=0; agent_loaded && loaded=1
  # Off with the job still loaded (launchd's process is the running app):
  # the agent file is gone, so the next login does not start it.
  state=on; [ $enabled = 0 ] && state=off
  [ $enabled = 0 ] && [ $loaded = 1 ] && state="off (takes effect at next login)"
  printf '{"enabled": %s, "source": %s, "state": %s, "loaded": %s, "agent": %s, "problem": %s}' \
    "$(json_bool $enabled)" "$(json_str "$(choice_source)")" "$(json_str "$state")" "$(json_bool $loaded)" \
    "$(json_str "$AGENT")" "$(json_opt "$problem")"
}

# ---- launching --------------------------------------------------------------

# Starts the installed app. $1 = background|window. A hidden start goes
# through the LaunchAgent when Start at login is on (exactly the login
# path); a window start, and every start with Start at login off, through
# LaunchServices. Never both: an `open` before the agent's process has
# checked in with LaunchServices starts a second process, and one of the
# two exits 73 on the profile lock (mac-test run 1). After a window start
# the agent loads at the next login.
start_app() {
  if [ "$1" = background ] && choice_enabled && [ "$(agent_state)" = exact ]; then
    if agent_loaded; then
      launchctl kickstart "gui/$UID_/$LABEL" >/dev/null 2>&1 || return 1
    else
      launchctl bootstrap "gui/$UID_" "$AGENT" 2>/dev/null || return 1
    fi
  elif [ "$1" = background ]; then
    open "$TARGET" --args --background 2>/dev/null || return 1
  else
    open "$TARGET" 2>/dev/null || return 1
  fi
}
wait_started() {
  waited=0
  while [ $waited -lt $((LAUNCH_WAIT * 2)) ]; do
    running "$TARGET" && return 0
    sleep 0.5; waited=$((waited + 1))
  done
  return 1
}
# Launch check: started, and still running LAUNCH_STABLE seconds later.
launch_check() {
  start_app "$1" || { say "The app could not be started."; return 1; }
  wait_started || { say "AnJ Cloud did not start within ${LAUNCH_WAIT}s."; return 1; }
  sleep "$LAUNCH_STABLE"
  running "$TARGET" || { say "AnJ Cloud exited within ${LAUNCH_STABLE}s of starting."; return 1; }
}

# ---- bundle checks ----------------------------------------------------------

# Checks the extracted bundle $1; refuses with the reason.
check_bundle() {
  app=$1
  [ -d "$app" ] && [ ! -L "$app" ] || refuse "The archive does not hold a single \"$APP_NAME\"."
  id=$(bundle_id_of "$app")
  [ "$id" = "$BUNDLE_ID" ] || refuse "The archive's bundle id is '${id:-missing}', not $BUNDLE_ID; nothing was installed."
  [ -f "$app/$EXE_REL" ] && [ ! -L "$app/$EXE_REL" ] || refuse "The archive's app has no executable; nothing was installed."
  [ -f "$app/$MANAGER_REL" ] || refuse "The archive's app has no embedded manager (built before M6?); nothing was installed."
  codesign --verify --deep --strict "$app" >/dev/null 2>&1 ||
    refuse "The archive's app fails codesign --verify --deep --strict; nothing was installed."
  info=$(codesign -dvvv "$app" 2>&1)
  printf '%s\n' "$info" | grep -qx "Identifier=$BUNDLE_ID" ||
    refuse "The archive's code signature names another identifier; nothing was installed."
  printf '%s\n' "$info" | grep -q '^CodeDirectory .*flags=0x[0-9a-f]*(.*runtime.*)' ||
    refuse "The archive's app is not a Release build (no hardened runtime); nothing was installed."
  if codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q 'com.apple.security.get-task-allow'; then
    refuse "The archive's app is a Debug or Profile build (get-task-allow); only Release builds are installed."
  fi
}

# Extracts the verified archive into $STAGE/x and sets NEW to the bundle.
extract() {
  mkdir "$STAGE/x" || refuse "Cannot create staging."
  ditto -x -k "$STAGE/archive.zip" "$STAGE/x" 2>/dev/null || refuse "The archive could not be extracted; nothing was installed."
  entries=$(ls -A "$STAGE/x" | grep -v '^__MACOSX$')
  [ "$entries" = "$APP_NAME" ] || refuse "The archive must hold exactly one \"$APP_NAME\"; nothing was installed."
  NEW="$STAGE/x/$APP_NAME"
  # Quarantine: a download marks every file; a launch of a quarantined copy
  # leaves the path launch-disabled (signing spike). The copy is cleared
  # here, before it is ever launched or moved into place.
  xattr -dr com.apple.quarantine "$NEW" 2>/dev/null
  if xattr -r "$NEW" 2>/dev/null | grep -q 'com\.apple\.quarantine'; then
    refuse "Quarantine could not be removed from the archive's app; nothing was installed."
  fi
  check_bundle "$NEW"
}

# ---- install and update -----------------------------------------------------

cmd_install() { # mode zip sha apps restart launch
  mode=$1 zip=$2 want=$3 restart=$5 launch=$6
  set_layout "$4"
  case "$want" in *[!0-9a-fA-F]*|'') refuse "--sha256 must be 64 hexadecimal characters." ;; esac
  [ ${#want} = 64 ] || refuse "--sha256 must be 64 hexadecimal characters."
  want=$(printf '%s' "$want" | tr 'A-F' 'a-f')
  no_controls "$zip"
  [ -f "$zip" ] || refuse "No archive at $zip."
  size=$(wc -c < "$zip" | tr -d ' ')
  [ "$size" -le $MAX_BYTES ] 2>/dev/null || refuse "The archive is larger than 2 GiB."
  check_apps_dir create
  take_lock
  recover
  if installed; then
    [ -e "$TARGET" ] || [ -e "$PREVIOUS" ] ||
      refuse "The manager's records exist but $TARGET is missing and no previous release is kept; run uninstall, then install."
    [ -e "$TARGET" ] || refuse "$TARGET is missing; $PREVIOUS is kept and was not changed. Retry once it is no longer running."
  else
    [ "$mode" = update ] && refuse "AnJ Cloud is not installed by this manager in $APPS; use install."
    if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
      refuse "$TARGET exists and was not installed by this manager. Move it to the Trash (do not open it) and retry, or pass another --apps-dir."
    fi
  fi
  if [ -e "$PREVIOUS" ] && ! ours_bundle "$PREVIOUS"; then
    refuse "$PREVIOUS is not an AnJ Cloud bundle; it was left alone and nothing was changed."
  fi
  running "$PREVIOUS" && busy "$BUSY"
  was_running=0
  if running "$TARGET"; then
    [ "$mode" = update ] && [ "$restart" = 1 ] || busy "$BUSY"
    was_running=1
  fi

  # Stage and verify while the installed app keeps running.
  STAGE=$(mktemp -d "$APPS/.anj-cloud-stage.XXXXXX") || refuse "Cannot create staging in $APPS."
  : > "$STAGE/.anj-cloud-stage"   # a later command removes it if this one dies
  cat -- "$zip" > "$STAGE/archive.zip" || refuse "Cannot read $zip."
  have=$(sha_of "$STAGE/archive.zip")
  [ "$have" = "$want" ] || refuse "SHA-256 mismatch (archive $have); nothing was installed."
  extract
  version=$(plist_value CFBundleShortVersionString "$NEW/Contents/Info.plist")
  build=$(plist_value CFBundleVersion "$NEW/Contents/Info.plist")
  cdhash=$(cdhash_of "$NEW")

  first=1; installed && first=0
  background=0
  if [ $was_running = 1 ]; then
    any_background "$TARGET" && background=1
    say "Quitting the running AnJ Cloud..."
    stop_app "$TARGET" 0 || busy "AnJ Cloud was asked to quit but is still running after ${QUIT_WAIT}s; nothing was installed. Retry once it has quit."
  elif [ $first = 0 ] && [ "${window:-0}" != 1 ]; then
    background=1  # always on (#40): an update starts it hidden
  fi

  # Started meanwhile (staging takes a while): never swap a running bundle.
  [ $was_running = 0 ] && running "$TARGET" && busy "$BUSY"

  # The transaction (see "the transaction" above): journal first.
  [ -d "$STATE_DIR" ] || { mkdir -m 700 "$STATE_DIR" || refuse "Cannot create $STATE_DIR."; }
  moved=0; [ -e "$TARGET" ] && moved=1
  had_prev=0; [ -e "$PREVIOUS" ] && had_prev=1
  old_state=
  if [ -f "$STATE" ]; then
    old_state=$(cat "$STATE")
    cp -- "$STATE" "$BEFORE" || refuse "Cannot write $BEFORE; nothing was changed."
  fi
  write_record "$JOURNAL" "$(printf 'first=%s\nhad_target=%s\nhad_prev=%s\nmode=%s\nversion=%s\ncdhash=%s\nstarted=%s' \
    "$first" "$moved" "$had_prev" "$mode" "$version" "$cdhash" "$(now)")" ||
    { rm -f -- "$BEFORE"; refuse "Cannot write $JOURNAL; nothing was changed."; }
  if [ $had_prev = 1 ]; then
    mv -- "$PREVIOUS" "$OLD_PREV" || abort_swap "Cannot move $PREVIOUS aside"
  fi
  if [ $moved = 1 ]; then
    mv -- "$TARGET" "$PREVIOUS" || abort_swap "Cannot move the installed app aside"
  fi
  [ ! -e "$TARGET" ] && mv -- "$NEW" "$TARGET" || abort_swap "Cannot move the new app into place"
  records=$(printf 'owner=%s\nversion=%s\nbuild=%s\narchive_sha256=%s\ncdhash=%s\ninstalled_at=%s' \
    "$OWNER" "$version" "$build" "$want" "$cdhash" "$(now)")
  if [ $moved = 1 ]; then
    records=$(printf '%s\n' "$records"; printf '%s\n' "$old_state" |
      sed -n -E 's/^(version|build|archive_sha256|cdhash|installed_at)=/previous_\1=/p')
  fi
  write_record "$STATE" "$records" || abort_swap "Cannot write the records"
  log_event "$mode version=$version build=$build archive_sha256=$want cdhash=$cdhash"

  # Start at login follows the choice (on by default, #40); the agent loads
  # with the launch below, or at the next login.
  [ -f "$CHOICE" ] || record_choice 1 default ""
  apply_agent noload

  result=installed; [ "$mode" = update ] && result=updated
  checked=0
  if [ "$launch" = 1 ]; then
    how=window; [ $background = 1 ] && how=background
    launch_outcome
    if launch_check "$how"; then
      checked=1
    else
      rollback "$first" "$was_running" "$background"
    fi
  fi
  commit_transaction
  printf '{"result": %s, "app": %s, "version": %s, "build": %s, "archive_sha256": %s, "cdhash": %s, "previous_kept": %s, "launch_checked": %s, "autostart": %s, "profile_kept": %s}\n' \
    "$(json_str "$result")" "$(json_str "$TARGET")" "$(json_str "$version")" "$(json_str "$build")" \
    "$(json_str "$want")" "$(json_str "$cdhash")" "$(json_bool $moved)" "$(json_bool $checked)" \
    "$(autostart_json)" "$(json_str "$PROFILE")"
}

# apply-update's outcome, written just before the new release starts (it
# reads result.json as it starts): only for the update child of
# apply-update, which overwrites it if the launch check fails. Best effort;
# apply-update writes it itself when the marker is missing.
launch_outcome() {
  [ "${ANJ_MANAGER_APPLY_COPY:-}" != "" ] && [ -n "${ANJ_MANAGER_LAUNCH_RESULT:-}" ] &&
    [ -n "${ANJ_MANAGER_LAUNCH_OUTCOME:-}" ] && [ -n "${ANJ_MANAGER_LAUNCH_MARK:-}" ] || return 0
  in_updates "$ANJ_MANAGER_LAUNCH_RESULT" || return 0
  tmp="${ANJ_MANAGER_LAUNCH_RESULT%/*}/.result.$$"
  printf '%s\n' "$ANJ_MANAGER_LAUNCH_OUTCOME" > "$tmp" && mv -f -- "$tmp" "$ANJ_MANAGER_LAUNCH_RESULT" &&
    : > "$ANJ_MANAGER_LAUNCH_MARK" || rm -f -- "$tmp"
}

# A swap step failed before the new release was in place: the old
# previous slot goes back, a quit app is started again, and the command
# refuses (the installed release is unchanged).
abort_swap() {
  undo_transaction || refuse "$1, and undoing it failed; the next manager command finishes the undo."
  if [ "${was_running:-0}" = 1 ] && [ -e "$TARGET" ]; then
    how=window; [ "$background" = 1 ] && how=background
    launch_check "$how" >/dev/null 2>&1
  fi
  refuse "$1; the installed release was kept."
}

# The new release did not stay running: put the previous one back (a
# first install is removed), restore the records, and start the restored
# release again if it was running before. Exits 2.
rollback() { # first was_running background
  say "Rolling back."
  log_event "launch failed: rolling back"
  undo_transaction || { say "Undoing the update failed; the next manager command finishes it."; exit 2; }
  if [ "$1" = 1 ]; then
    printf '{"result": "rolled_back", "app": null, "restored": null}\n'
    say "AnJ Cloud did not stay running; the installation was removed. Nothing else changed."
    exit 2
  fi
  restored=$(get version "$STATE")
  log_event "update rolled back to version=$restored: launch failed"
  apply_agent noload
  relaunched=0
  if [ "$2" = 1 ]; then
    how=window; [ "$3" = 1 ] && how=background
    launch_check "$how" && relaunched=1
  fi
  printf '{"result": "rolled_back", "app": %s, "restored": %s, "relaunched": %s}\n' \
    "$(json_str "$TARGET")" "$(json_str "$restored")" "$(json_bool $relaunched)"
  say "The new release did not stay running; the previous release ($restored) was restored."
  exit 2
}

# ---- autostart, status, uninstall ------------------------------------------

cmd_autostart() { # action apps
  set_layout "$2"
  check_apps_dir nocreate
  if [ "$1" = status ]; then
    installed || refuse "AnJ Cloud is not installed by this manager in $APPS."
    autostart_json; echo
    return
  fi
  take_lock
  recover
  installed || refuse "AnJ Cloud is not installed by this manager in $APPS."
  case "$1" in on|enable) e=1 ;; *) e=0 ;; esac
  record_choice $e user "$(get agent_sha256 "$CHOICE")"
  log_event "autostart enabled=$e (user)"
  apply_agent load
  autostart_json; echo
}

cmd_status() {
  set_layout "$1"
  if ! installed; then
    printf '{"installed": false, "apps_dir": %s}\n' "$(json_str "$APPS")"
    return
  fi
  prev=null
  if [ -n "$(get previous_version "$STATE")" ] && [ -d "$PREVIOUS" ]; then
    prev=$(printf '{"app": %s, "version": %s, "build": %s, "archive_sha256": %s, "cdhash": %s}' \
      "$(json_str "$PREVIOUS")" "$(json_str "$(get previous_version "$STATE")")" \
      "$(json_str "$(get previous_build "$STATE")")" "$(json_str "$(get previous_archive_sha256 "$STATE")")" \
      "$(json_str "$(get previous_cdhash "$STATE")")")
  fi
  r=0; running "$TARGET" && r=1
  printf '{"installed": true, "apps_dir": %s, "app": %s, "version": %s, "build": %s, "archive_sha256": %s, "cdhash": %s, "installed_at": %s, "previous": %s, "running": %s, "autostart": %s, "profile": %s, "rollback": "automatic when an updated release does not stay running; the previous release is kept"}\n' \
    "$(json_str "$APPS")" "$(json_str "$TARGET")" "$(json_str "$(get version "$STATE")")" \
    "$(json_str "$(get build "$STATE")")" "$(json_str "$(get archive_sha256 "$STATE")")" \
    "$(json_str "$(get cdhash "$STATE")")" "$(json_str "$(get installed_at "$STATE")")" "$prev" \
    "$(json_bool $r)" "$(autostart_json)" "$(json_str "$PROFILE")"
}

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# The default profile's id from its manifest (base macOS sqlite3); empty
# when there is no profile. Only an id the app could have made is used.
profile_id() {
  [ -f "$PROFILE/manifest.sqlite" ] || return 0
  id=$(sqlite3 -readonly "$PROFILE/manifest.sqlite" "SELECT value FROM settings WHERE key='profileId'" 2>/dev/null | head -1)
  case "$id" in ''|*[!A-Za-z0-9-]*) return 0 ;; esac
  printf '%s' "$id"
}
# The invitation first, the device key last (delta review L5): if the
# keychain refuses part-way, the device key is the item most likely kept.
key_accounts() { printf 'anj-cloud:%s:invitation anj-cloud:%s:device-key' "$1" "$1"; }

cmd_uninstall() { # $1 apps dir, $2 = 1 to remove the profile and its keychain items too
  set_layout "$1"
  check_apps_dir nocreate
  take_lock
  recover
  if running "$TARGET" || running "$PREVIOUS"; then
    busy "AnJ Cloud is running. Quit it from its menu-bar item and retry; nothing was removed."
  fi
  if [ ! -e "$TARGET" ] && [ -e "$PREVIOUS" ]; then
    refuse "$TARGET is missing and $PREVIOUS is the only copy left; it was not removed. Move it to $TARGET to keep it, or delete it yourself."
  fi
  removed= kept=
  add() { if [ -z "$2" ]; then printf '%s' "$(json_str "$1")"; else printf '%s, %s' "$2" "$(json_str "$1")"; fi; }
  prof_id=$(profile_id)
  if [ "$2" = 1 ] && [ -e "$PROFILE" ]; then
    # The profile goes only with its keychain items, and before anything
    # else changes: a refusal (the login keychain is locked outside the GUI
    # session) leaves everything as it was.
    [ -d "$PROFILE" ] && [ ! -L "$PROFILE" ] && own_dir "$PROFILE" ||
      refuse "$PROFILE is not a profile folder of this user; nothing was removed."
    if [ -n "$prof_id" ]; then
      for acct in $(key_accounts "$prof_id"); do
        security delete-generic-password -s "$BUNDLE_ID" -a "$acct" >/dev/null 2>&1
        rc=$?
        case $rc in
          0) removed=$(add "login keychain item $acct" "$removed") ;;
          44) ;; # errSecItemNotFound: nothing to remove
          *)
            gone=$(printf '%s' "$removed" | sed 's/"login keychain item //g; s/"//g')
            refuse "The login keychain refused to delete $acct ($rc); run this from the logged-in desktop session (it may ask for your password). The app and the profile were not removed.${gone:+ Already removed: $gone.}" ;;
        esac
      done
    fi
  fi
  st=$(agent_state)
  case "$st" in
    exact|ours)
      agent_loaded && launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null
      rm -f -- "$AGENT" && removed=$(add "$AGENT" "$removed") ;;
    foreign) kept=$(add "$AGENT (not written by this manager)" "$kept") ;;
  esac
  for b in "$TARGET" "$PREVIOUS"; do
    [ -e "$b" ] || [ -L "$b" ] || continue
    if installed && ours_bundle "$b"; then
      [ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$b" >/dev/null 2>&1
      rm -rf -- "$b" && removed=$(add "$b" "$removed")
    else
      kept=$(add "$b (not installed by this manager)" "$kept")
    fi
  done
  if [ -d "$STATE_DIR" ]; then
    rm -rf -- "$STATE_DIR" && removed=$(add "$STATE_DIR" "$removed")
  fi
  if [ "$2" = 1 ]; then
    if [ -e "$PROFILE" ]; then
      rm -rf -- "$PROFILE" && removed=$(add "$PROFILE" "$removed")
    fi
    printf '{"result": "uninstalled", "removed": [%s], "kept": [%s], "profile_kept": null, "keychain_kept": [], "root_kept": %s}\n' \
      "$removed" "$kept" "$(json_str "the synced folder and its files (never removed)")"
    return 0
  fi
  accounts=
  [ -n "$prof_id" ] && for acct in $(key_accounts "$prof_id"); do accounts=$(add "$acct" "$accounts"); done
  [ -e "$PROFILE" ] &&
    say "Kept the profile and its login keychain items. To remove them too, run this command again with --remove-profile from the logged-in desktop session."
  printf '{"result": "uninstalled", "removed": [%s], "kept": [%s], "profile_kept": %s, "keychain_kept": [%s], "keychain_service": %s, "remove_with": %s}\n' \
    "$removed" "$kept" "$(json_str "$PROFILE")" "$accounts" "$(json_str "$BUNDLE_ID")" \
    "$(json_str "anj-cloud-macos-install.sh uninstall --remove-profile")"
}


# ---- apply-update (spec #40 R2) -------------------------------------------

UPDATES="$PROFILE/updates"
# The JSON value of "$1" in the one-line JSON object $2 (strings unquoted).
json_get() { printf '%s\n' "$2" | sed -n "s/.*\"$1\": *\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" | head -1; }
in_updates() { # a regular file directly in the private updates folder
  case "$1" in /*) ;; *) return 1 ;; esac
  [ "$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" = "$(cd "$UPDATES" 2>/dev/null && pwd -P)" ] || return 1
  [ ! -L "$1" ]
}
APPLY_LOCK= APPLY_DIR= APPLY_SELF= DEL_ZIP= DEL_MANIFEST=
apply_cleanup() {
  for f in "$APPLY_SELF" "$DEL_ZIP" "$DEL_MANIFEST"; do [ -n "$f" ] && [ -f "$f" ] && [ ! -L "$f" ] && rm -f -- "$f"; done
  [ -n "$APPLY_DIR" ] && [ -d "$APPLY_DIR" ] && rm -rf -- "$APPLY_DIR"
  if [ -n "$APPLY_LOCK" ]; then rm -f -- "$APPLY_LOCK/pid"; rmdir -- "$APPLY_LOCK" 2>/dev/null; fi
  cleanup
}
write_result() { # json; atomically, in the updates folder only
  [ -n "$result_file" ] || return 0
  tmp="$UPDATES/.result.$$"
  printf '%s\n' "$1" > "$tmp" && mv -f -- "$tmp" "$result_file" || { rm -f -- "$tmp"; say "Could not write $result_file."; }
}
wait_quit() { # app pid or empty; true once the app has exited
  waited=0
  while [ $waited -lt $((APPLY_WAIT * 4)) ]; do
    gone=1
    if [ -n "$1" ] && kill -0 "$1" 2>/dev/null; then gone=0; fi
    running "$TARGET" && gone=0
    [ $gone = 1 ] && return 0
    sleep 0.25; waited=$((waited + 1))
  done
  return 1
}
relaunch_window() { [ -e "$TARGET" ] && launch_check window >/dev/null 2>&1; }
# Verifies the private copy $APPLY_DIR/update.zip against $manifest with the
# installed release's own verifier; prints its JSON; refuses with the reason.
verify_download() {
  [ -f "$TARGET/$EXE_REL" ] || refuse "AnJ Cloud is not installed in $APPS."
  codesign --verify --strict "$TARGET" >/dev/null 2>&1 ||
    refuse "The installed AnJ Cloud fails codesign --verify; it cannot vouch for an update."
  [ -f "$TARGET/$RECEIPT_REL" ] ||
    refuse "This release has no release receipt and cannot update itself; install updates with this script's update command."
  out=$("$TARGET/$EXE_REL" --verify-update "$APPLY_DIR/update.zip" --manifest "$APPLY_DIR/manifest.json" 2>/dev/null)
  rc=$?
  ok=$(json_get ok "$out")
  if [ $rc != 0 ] || [ "$ok" != true ]; then
    why=$(json_get message "$out")
    refuse "${why:-The installed AnJ Cloud could not verify the update.}"
  fi
  code=$(json_get version_code "$out")
  # The archive's own receipt names the same version and platform.
  unzip -p "$APPLY_DIR/update.zip" "$APP_NAME/$RECEIPT_REL" > "$APPLY_DIR/receipt.json" 2>/dev/null ||
    refuse "The update has no release receipt."
  [ "$(plist_value version_code "$APPLY_DIR/receipt.json")" = "$code" ] &&
    [ "$(plist_value target "$APPLY_DIR/receipt.json")" = "$RELEASE_TARGET" ] ||
    refuse "The update's receipt does not match its signed version."
  printf '%s\n' "$out"
}

cmd_apply_update() { # zip manifest result app_pid check
  zip=$1 manifest=$2 result_file=$3 app_pid=$4 check=$5
  set_layout "$apps"
  no_controls "$zip"; no_controls "$manifest"; [ -n "$result_file" ] && no_controls "$result_file"
  if [ -n "$app_pid" ]; then is_uint "$app_pid" || usage; fi
  # The bundle (and this script inside it) is replaced below: run from a
  # private copy, with the folder named explicitly.
  if [ "${ANJ_MANAGER_APPLY_COPY:-}" != "$$" ] && [ "$check" = 0 ]; then
    check_apps_dir nocreate
    copy=$(mktemp "$STATE_DIR/apply-manager.XXXXXX") && cat -- "$0" > "$copy" ||
      refuse "Cannot copy the manager for the update."
    export ANJ_MANAGER_APPLY_COPY=$$ ANJ_MANAGER_APPLY_SELF=$copy
    set -- apply-update "$zip" --manifest "$manifest" --apps-dir "$APPS"
    [ -n "$result_file" ] && set -- "$@" --result "$result_file"
    [ -n "$app_pid" ] && set -- "$@" --app-pid "$app_pid"
    exec /bin/sh "$copy" "$@"
  fi
  APPLY_SELF=${ANJ_MANAGER_APPLY_SELF:-}
  trap apply_cleanup EXIT
  check_apps_dir nocreate
  installed || refuse "AnJ Cloud is not installed by this manager in $APPS."
  private_dir "$UPDATES" || refuse "Update files must be in the profile's private updates folder ($UPDATES)."
  for f in "$zip" "$manifest" ${result_file:+"$result_file"}; do
    in_updates "$f" || refuse "Update files must be in the profile's private updates folder ($UPDATES)."
  done
  if [ "$check" = 0 ]; then
    APPLY_LOCK="$APPS/.anj-cloud-apply.lock"
    if ! mkdir -- "$APPLY_LOCK" 2>/dev/null; then
      holder=$(cat "$APPLY_LOCK/pid" 2>/dev/null)
      if is_uint "$holder" && kill -0 "$holder" 2>/dev/null; then
        APPLY_LOCK=
        printf '{"ok": false, "concurrent": true, "message": "Another update is already being applied."}\n'
        exit 0
      fi
      rm -f -- "$APPLY_LOCK/pid"; rmdir -- "$APPLY_LOCK" 2>/dev/null; mkdir -- "$APPLY_LOCK" 2>/dev/null ||
        { APPLY_LOCK=; busy "Could not take the update lock."; }
    fi
    echo $$ > "$APPLY_LOCK/pid"
    # Installed or refused, the download is deleted (spec #37 rule 4).
    DEL_ZIP=$zip DEL_MANIFEST=$manifest
  fi
  [ -f "$zip" ] && [ -f "$manifest" ] || refuse "The update files are missing."
  APPLY_DIR=$(mktemp -d "$STATE_DIR/apply.XXXXXX") || refuse "Cannot create private staging."
  size=$(wc -c < "$zip" | tr -d ' ')
  [ "$size" -le $MAX_BYTES ] 2>/dev/null || refuse "The update is larger than 2 GiB."
  cat -- "$zip" > "$APPLY_DIR/update.zip" && cat -- "$manifest" > "$APPLY_DIR/manifest.json" ||
    refuse "Cannot read the update files."

  if [ "$check" = 1 ]; then
    out=$(verify_download) || exit 1
    printf '{"ok": true, "check": true, "version": %s, "version_code": %s}\n' \
      "$(json_str "$(json_get version "$out")")" "$(json_get version_code "$out")"
    exit 0
  fi

  # The app has handed over and is quitting. Every outcome from here is
  # written for it, and it is started again.
  out=$( (verify_download) 2> "$APPLY_DIR/verify.err")
  if [ $? != 0 ]; then
    why=$(sed 's/^anj-cloud: //' "$APPLY_DIR/verify.err" | tail -1)
    log_event "apply-update refused: $why"
    write_result "{\"ok\": false, \"message\": $(json_str "$why")}"
    wait_quit "$app_pid" && relaunch_window
    printf '{"ok": false, "message": %s}\n' "$(json_str "$why")"
    exit 1
  fi
  version=$(json_get version "$out"); code=$(json_get version_code "$out"); want=$(json_get sha256 "$out")
  if ! wait_quit "$app_pid"; then
    why="AnJ Cloud did not quit in time; the update was not installed."
    write_result "{\"ok\": false, \"message\": $(json_str "$why")}"
    printf '{"ok": false, "message": %s}\n' "$(json_str "$why")"
    exit 1
  fi
  log_event "apply-update version_code=$code sha256=$want"
  # The new release reads result.json as it starts, so the update writes
  # the outcome just before launching it (launch_outcome); a failed launch
  # check is answered below, before the restored release starts.
  ok_json="{\"ok\": true, \"version\": $(json_str "$version"), \"version_code\": $code}"
  ANJ_MANAGER_LAUNCH_RESULT=$result_file ANJ_MANAGER_LAUNCH_OUTCOME=$ok_json ANJ_MANAGER_LAUNCH_MARK=$APPLY_DIR/outcome-written \
    /bin/sh "${ANJ_MANAGER_APPLY_SELF:-$0}" update "$APPLY_DIR/update.zip" --sha256 "$want" --apps-dir "$APPS" --window \
    > "$APPLY_DIR/update.json" 2> "$APPLY_DIR/update.err"
  rc=$?
  case $rc in
    0) [ -f "$APPLY_DIR/outcome-written" ] || write_result "$ok_json"
       printf '{"ok": true, "version": %s, "version_code": %s}\n' "$(json_str "$version")" "$code" ;;
    2) why="The new release did not start; the previous release was restored."
       write_result "{\"ok\": false, \"message\": $(json_str "$why")}"
       relaunch_window
       printf '{"ok": false, "rolled_back": true, "message": %s}\n' "$(json_str "$why")" ;;
    *) why=$(sed 's/^anj-cloud: //' "$APPLY_DIR/update.err" | tail -1)
       why=${why:-The update could not be installed ($rc).}
       write_result "{\"ok\": false, \"message\": $(json_str "$why")}"
       relaunch_window
       printf '{"ok": false, "message": %s}\n' "$(json_str "$why")" ;;
  esac
  log_event "apply-update rc=$rc"
  [ $rc = 0 ]
}

# ---- arguments --------------------------------------------------------------

cmd=${1:-}
[ $# -gt 0 ] && shift
zip= sha= apps= restart=0 launch=1 action= remove_profile=0 window=0
manifest= result_file= app_pid= check=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sha256) [ $# -ge 2 ] || usage; sha=$2; shift 2 ;;
    --apps-dir) [ $# -ge 2 ] || usage; apps=$2; shift 2 ;;
    --restart) restart=1; shift ;;
    --no-launch) launch=0; shift ;;
    --remove-profile) remove_profile=1; shift ;;
    --window) window=1; shift ;;
    --manifest) [ $# -ge 2 ] || usage; manifest=$2; shift 2 ;;
    --result) [ $# -ge 2 ] || usage; result_file=$2; shift 2 ;;
    --app-pid) [ $# -ge 2 ] || usage; app_pid=$2; shift 2 ;;
    --check) check=1; shift ;;
    --*) say "unknown option $1"; usage ;;
    *)
      case "$cmd" in
        install|update|apply-update) [ -z "$zip" ] || usage; zip=$1 ;;
        autostart) [ -z "$action" ] || usage; action=$1 ;;
        *) usage ;;
      esac
      shift ;;
  esac
done
[ "$remove_profile" = 0 ] || [ "$cmd" = uninstall ] || usage
[ "$window" = 0 ] || [ "$cmd" = update ] || usage
[ -z "$manifest$result_file$app_pid" ] && [ "$check" = 0 ] || [ "$cmd" = apply-update ] || usage
case "$cmd" in
  install|update)
    [ -n "$zip" ] && [ -n "$sha" ] || usage
    [ "$restart" = 0 ] || [ "$cmd" = update ] || usage
    cmd_install "$cmd" "$zip" "$sha" "$apps" "$restart" "$launch" ;;
  autostart)
    case "$action" in on|off|enable|disable|status) ;; *) usage ;; esac
    [ -z "$sha" ] && [ "$restart" = 0 ] && [ "$launch" = 1 ] || usage
    cmd_autostart "$action" "$apps" ;;
  status) [ -z "$sha" ] || usage; cmd_status "$apps" ;;
  uninstall) [ -z "$sha" ] || usage; cmd_uninstall "$apps" "$remove_profile" ;;
  apply-update)
    [ -n "$zip" ] && [ -n "$manifest" ] && [ -z "$sha" ] && [ "$restart" = 0 ] && [ "$launch" = 1 ] || usage
    [ "$check" = 0 ] || [ -z "$result_file" ] || usage
    cmd_apply_update "$zip" "$manifest" "$result_file" "$app_pid" "$check" ;;
  *) usage ;;
esac
