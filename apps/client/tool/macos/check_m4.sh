#!/bin/zsh
# M4 checks of spec #31 on mac-test: the Cloud release guard (acceptance row
# 7, decision #126), Finish editing over the Darwin guard, the shared
# exclusions, and the editor round trip (row 14). Runs ON mac-test from the
# client directory tool/macos/mac_test.sh sent over, without sudo; driven by
# tool/macos/m4_window.sh on the VM host.
#
#   tool/macos/check_m4.sh [--evidence <dir>] [--skip-ssh-keychain]
#
# 1. a fresh Darwin test dylib (build_native.sh)
# 2. the shared release suites over it: release_guard_qualification (held
#    descriptor, mapping, child-held descriptor, write between hash and
#    unlink, opens inside the window, clean release), eviction,
#    staging_release, edit_completion (Finish editing), sync_exclusions and
#    the round-trip harness with its atomic-save editor; plus
#    test_macos/root_filesystem_macos_test.dart
# 3. Automation consent for TextEdit and Preview, read without prompting
#    (automation_consent.swift), from SSH and from a gui/<uid> job; the
#    targets are launched hidden first and quit again if this script
#    started them. Accessibility is never requested
# 4. the editor round trip with TextEdit (txt, rtf) and Preview's save
#    path for the pdf (save only: annotating in Preview is the operator's, at M7
#    on the MacBook), through the route that has consent; without consent
#    it is recorded as "pending: no Automation consent" and the step does
#    not fail (row 14 then needs the operator)
# 5. M3's SSH keychain rerun (PR #72 e0cd7578; --skip-ssh-keychain skips
#    it): integration_test/macos_adapters_test.dart straight from SSH, with
#    an item another program created: a missing item reads as missing, a
#    write is refused (SecretStoreUnavailable), the foreign item reads as
#    unavailable and stays unchanged
# Exit 0 only when every step that ran passes. Evidence goes to <dir>
# (default build/macos-m4).
set -u
cd "${0:A:h}/../.."
evidence=build/macos-m4
ssh_keychain=1
while (( $# )); do
  case $1 in
    --evidence) evidence=$2; shift 2 ;;
    --skip-ssh-keychain) ssh_keychain=0; shift ;;
    *) echo "usage: check_m4.sh [--evidence <dir>] [--skip-ssh-keychain]" >&2; exit 64 ;;
  esac
done
mkdir -p "$evidence"; evidence=${evidence:A}
# macOS /tmp and $TMPDIR (/var/folders) sit under symlinks; the root open
# refuses a symlink anywhere in the path (ELOOP), so use a real directory.
export TMPDIR=$PWD/build/tmp
mkdir -p "$TMPDIR"; TMPDIR=${TMPDIR:A}
export FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
flutter_bin=$(whence -p flutter) || { echo "FAIL  flutter not on PATH"; exit 1; }
export FLUTTER_SDK=${flutter_bin:A:h:h}
failed=0
step() { # name, log, command...
  local name=$1 log=$2; shift 2
  local start=$SECONDS
  print -r -- "== $name"
  if "$@" > "$evidence/$log" 2>&1; then print -r -- "pass  $name ($(( SECONDS - start )) s)"
  else print -r -- "FAIL  $name (see $log)"; tail -25 "$evidence/$log"; failed=1; fi
}
print -r -- "info  source: $(head -1 .anj-source 2>/dev/null || echo unknown)"
{ sw_vers; flutter --version; } > "$evidence/toolchain.txt" 2>&1

step "flutter pub get" pub-get.log flutter --suppress-analytics pub get
lib=$PWD/.dart_tool/libanj_rootfs.dylib
step "build test dylib" native.log tool/macos/build_native.sh --out "$lib"
export ANJ_MACOS_ROOTFS_LIBRARY=$lib ANJ_ROOTFS_LIBRARY=$lib
step "release guard, Finish editing and exclusions over the Darwin guard" release-suites.log \
  flutter --suppress-analytics test --reporter expanded --concurrency=1 \
    test/release_guard_qualification_test.dart test/eviction_test.dart \
    test/staging_release_test.dart test/edit_completion_test.dart \
    test/sync_exclusions_test.dart test/editor_roundtrip_fixture_test.dart \
    test_macos/root_filesystem_macos_test.dart
grep -E '^[0-9:]+ \+[0-9]+.*(All tests passed|Some tests failed)' "$evidence/release-suites.log" | tail -1

# --- Consent, without prompting ---------------------------------------------
apps=(TextEdit Preview)
ids=(com.apple.TextEdit com.apple.Preview)
started=()
probe=$evidence/consent; mkdir -p "$probe"
print -r -- 'A scratch note for the consent probe.' > "$probe/probe.txt"
# A tolerated minimal PDF (Preview repairs the cross-reference table).
printf '%s\n' '%PDF-1.4' '1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj' \
  '2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj' \
  '3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >> endobj' \
  'trailer << /Root 1 0 R >>' '%%EOF' > "$probe/probe.pdf"
for i in 1 2; do
  if ! pgrep -xq -- "${apps[$i]}"; then
    started+=("${apps[$i]}")
    case $i in
      1) open -g -j -a TextEdit "$probe/probe.txt" ;;
      2) open -g -j -a Preview "$probe/probe.pdf" ;;
    esac
  fi
done
for _ in {1..40}; do
  pgrep -xq TextEdit && pgrep -xq Preview && break
  sleep 0.25
done
quit_started() {
  local app
  for app in $started; do pkill -x -- "$app" 2>/dev/null; done
  started=()
}
trap quit_started EXIT
consent_ssh=$(swift tool/macos/automation_consent.swift $ids 2>"$probe/ssh.err")
consent_gui=$(tool/macos/gui_run.sh "$probe/gui" 120 swift tool/macos/automation_consent.swift $ids 2>"$probe/gui.err" | tail -1)
print -r -- "$consent_ssh" > "$probe/consent-ssh.json"
print -r -- "$consent_gui" > "$probe/consent-gui.json"
# The user TCC database, read-only (needs Full Disk Access; may be refused).
sqlite3 -readonly "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service, client, client_type, indirect_object_identifier, auth_value from access where service = 'kTCCServiceAppleEvents'" \
  > "$probe/tcc-user.txt" 2>&1 || true
print -r -- "info  consent from SSH: ${consent_ssh:-unreadable}"
print -r -- "info  consent from gui/<uid>: ${consent_gui:-unreadable}"
granted() { [[ $1 == *"\"$2\":\"granted\""* ]]; }
route=
for candidate in ssh gui; do
  [[ $candidate == ssh ]] && c=$consent_ssh || c=$consent_gui
  if granted "$c" com.apple.TextEdit; then route=$candidate; consent=$c; break; fi
done
pdf=skip
# Preview's save path only; annotation is the operator's at M7 (planner, M4).
if [[ -n $route ]] && granted "$consent" com.apple.Preview; then pdf=preview-save; fi
quit_started

# --- Editor round trip (row 14) ----------------------------------------------
if [[ -z $route ]]; then
  print -r -- "pending  editor round trip: no Automation consent for TextEdit on either route (row 14 needs the operator)"
  print -r -- "pending: no Automation consent" > "$evidence/editor-roundtrip.txt"
else
  print -r -- "info  editor round trip through the $route route, pdf: $pdf"
  for app in TextEdit Preview; do pgrep -xq -- "$app" || started+=("$app"); done
  rt=(/usr/bin/env "TMPDIR=$TMPDIR" "ANJ_ROOTFS_LIBRARY=$lib" "FLUTTER_SDK=$FLUTTER_SDK"
    dart run tool/editor_roundtrip_fixture.dart "$TMPDIR/editor-rt" "$evidence/editor-roundtrip.json"
    --editor textedit --pdf $pdf --consent "$probe/consent-$route.json")
  if [[ $route == ssh ]]; then
    step "editor round trip: TextEdit txt/rtf, Preview $pdf (SSH)" editor-roundtrip.log $rt
  else
    step "editor round trip: TextEdit txt/rtf, Preview $pdf (gui/<uid>)" editor-roundtrip.log \
      tool/macos/gui_run.sh "$evidence/editor-gui" 420 $rt
  fi
  grep -E '^(pass|FAIL)  ' "$evidence/editor-roundtrip.log"
  quit_started
fi

# --- M3: the SSH keychain rerun (PR #72 e0cd7578) ----------------------------
if (( ssh_keychain )); then
  run=$(date +%s)
  foreign="anj-test-m3-m4run-$run"
  if tool/macos/keychain_items.sh add "$foreign" "unchanged-$run" > "$evidence/keychain-add.log" 2>&1; then
    step "M3 keychain from SSH: missing reads missing, a write is refused, a foreign item is unavailable" \
      keychain-ssh.log \
      flutter --suppress-analytics test integration_test/macos_adapters_test.dart -d macos \
        --reporter expanded --dart-define=ANJ_M3_SESSION=ssh --dart-define=ANJ_M3_FOREIGN=$foreign
    value=$(tool/macos/keychain_items.sh value "$foreign" 2>/dev/null)
    if [[ $value == "unchanged-$run" ]]; then
      print -r -- "pass  the foreign item is unchanged"
    else
      print -r -- "FAIL  the foreign item is unchanged"; failed=1
    fi
  else
    print -r -- "FAIL  foreign keychain item (see keychain-add.log)"; failed=1
  fi
  tool/macos/keychain_items.sh clean anj-test-m3-m4run > "$evidence/keychain-clean.log" 2>&1 ||
    { print -r -- "FAIL  keychain cleanup (see keychain-clean.log)"; failed=1; }
fi

rm -rf -- "$TMPDIR/editor-rt"
if (( failed )); then echo "check_m4: FAILED"; else echo "check_m4: all steps passed"; fi
exit $failed
