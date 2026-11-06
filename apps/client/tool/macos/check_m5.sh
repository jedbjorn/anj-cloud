#!/bin/zsh
# macOS UI conventions and Admin of spec #31 M5 (acceptance row 16). Runs ON
# mac-test from the client directory tool/macos/mac_test.sh sent over,
# without sudo; deploy/macos_admin_fixture.py starts it with --config.
#
#   tool/macos/check_m5.sh --out <dir> [--config <file>] [--timeout <s>]
#
# Runs integration_test/macos_ui_test.dart in the real app from a gui/<uid>
# job (tool/macos/gui_run.sh: the console session's window server and
# pasteboard): the macOS conventions, then, with --config, the Admin flow
# against the review stack through the reverse forward. While the home
# screen shows, the whole screen is captured (title bar, traffic lights,
# menu bar). TMPDIR is a real path inside the task directory (/tmp is a
# symlink on macOS). Stale results never count: <out> and the job's log
# are removed first, and the last line is this run's
#   M5 GUI RESULT <status>
# Exit status: the gui job's (124 on timeout).
set -u
cd "${0:A:h}/../.."
out=
config=
limit=1500
while (( $# )); do
  case $1 in
    --out) out=$2; shift 2 ;;
    --config) config=$2; shift 2 ;;
    --timeout) limit=$2; shift 2 ;;
    *) echo "usage: check_m5.sh --out <dir> [--config <file>] [--timeout <s>]" >&2; exit 64 ;;
  esac
done
[[ -n $out ]] || { echo "check_m5.sh: --out is required" >&2; exit 64; }
export FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
run=build/m5
rm -rf -- "$out" "$run/gui" "$run/gui.label"
mkdir -p "$out" "$run/tmp" "$run/gui"
out=${out:A}
tmp=${run:A}/tmp
defines=(--dart-define=ANJ_M5_OUT=$out)
[[ -n $config ]] && defines+=(--dart-define=ANJ_M5_CONFIG=${config:A})
print -r -- "info  source: $(head -1 .anj-source 2>/dev/null || echo unknown)"
print -r -- "info  macOS $(sw_vers -productVersion), $(uname -m)"

# The job's label is local.anj-test.gui.<gui_run pid>: recorded so the
# driver can boot out exactly this run's job.
tool/macos/gui_run.sh "$run/gui" "$limit" /usr/bin/env TMPDIR="$tmp" \
  flutter --suppress-analytics test integration_test/macos_ui_test.dart -d macos \
  --reporter expanded $defines &
job=$!
print -r -- "local.anj-test.gui.$job" > "$run/gui.label"
shot=0
while kill -0 $job 2>/dev/null; do
  if (( ! shot )) && grep -q '"home shown"' "$out/ui-progress.json" 2>/dev/null; then
    # Evidence only: a failed capture never fails the run.
    if screencapture -x "$out/desktop-home.png" 2>/dev/null && [[ -s $out/desktop-home.png ]]; then
      print -r -- "info  desktop screenshot $out/desktop-home.png"
    else
      print -r -- "warn  desktop screenshot failed"
    fi
    shot=1
  fi
  sleep 1
done
wait $job
rc=$?
rm -f -- "$run/gui.label"
print -r -- "M5 GUI RESULT $rc"
exit $rc
