#!/bin/zsh
# Runs one command inside the console user's GUI session (spec #31 M3).
# Runs ON mac-test, without sudo. An SSH session cannot reach the login
# keychain or LaunchServices' per-session state; a one-shot launchd job
# bootstrapped into gui/<uid> can (proven 2026-11-04, spec #31).
#
#   gui_run.sh <out dir> <timeout seconds> <command...>
#
# The command runs under `zsh -l` (Homebrew and Flutter on PATH) in the
# current directory. Its stdout and stderr go to <out dir>/gui.log, which
# this script prints when it ends. Exit status: the command's, 124 on
# timeout (the job is booted out), 69 when there is no GUI session.
# The job label is local.anj-test.gui.<pid>; it is always booted out.
set -u
out=${1:?usage: gui_run.sh <out dir> <timeout> <command...>}
limit=${2:?usage}
shift 2
(( $# )) || { echo "gui_run.sh: no command" >&2; exit 64; }
mkdir -p "$out"; out=${out:A}
uid=$(id -u)
label="local.anj-test.gui.$$"
job=$(mktemp -d "${TMPDIR:-/tmp}/anj-gui.XXXXXX") || exit 70
trap 'launchctl bootout "gui/$uid/$label" 2>/dev/null; rm -rf -- "$job"' EXIT
rm -f "$out/gui.log" "$out/gui.rc"
{
  print -r -- '#!/bin/zsh -l'
  print -r -- "cd ${(q)PWD} || exit 66"
  # launchd gives the job its own TMPDIR; the caller's wins (check_m3.sh
  # sets one with no symlink in its path).
  [[ -n ${TMPDIR:-} ]] && print -r -- "export TMPDIR=${(q)TMPDIR}"
  print -r -- "${(j: :)${(q)@}} > ${(q)out}/gui.log 2>&1"
  print -r -- "print -r -- \$? > ${(q)out}/gui.rc"
} > "$job/run.zsh"
chmod 700 "$job/run.zsh"
cat > "$job/job.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>/bin/zsh</string><string>-l</string><string>$job/run.zsh</string></array>
<key>RunAtLoad</key><true/>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
if ! launchctl bootstrap "gui/$uid" "$job/job.plist" 2>"$job/bootstrap.err"; then
  echo "gui_run.sh: no GUI session for gui/$uid: $(cat "$job/bootstrap.err")" >&2
  exit 69
fi
waited=0
while [[ ! -s $out/gui.rc ]] && (( waited < limit * 2 )); do
  sleep 0.5; (( waited++ ))
done
[[ -f $out/gui.log ]] && cat "$out/gui.log"
if [[ ! -s $out/gui.rc ]]; then
  echo "gui_run.sh: timed out after ${limit}s" >&2
  exit 124
fi
exit "$(cat "$out/gui.rc")"
