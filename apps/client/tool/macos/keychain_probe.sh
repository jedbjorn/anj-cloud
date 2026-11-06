#!/bin/zsh
# Runs keychain_probe.swift from this SSH session and from the GUI session
# against one existing test item, then removes the item (spec #31 M3).
# Runs ON mac-test without sudo; reads no secret.
#
#   tool/macos/keychain_probe.sh <out dir>
set -u
out=${1:?usage: keychain_probe.sh <out dir>}
mkdir -p "$out"; out=${out:A}
here=${0:A:h}
run=$(date +%s)
existing="anj-test-m3-probe-$run"
missing="anj-test-m3-absent-$run"
"$here/keychain_items.sh" add "$existing" "probe-$run" > /dev/null || { echo "keychain_probe.sh: could not add the probe item" >&2; exit 1; }
echo "== from SSH"
swift "$here/keychain_probe.swift" cloud.anj.anj-cloud "$existing" "$missing" | tee "$out/probe-ssh.json"
echo "== from the GUI session"
"$here/gui_run.sh" "$out/gui" 120 swift "$here/keychain_probe.swift" cloud.anj.anj-cloud "$existing" "$missing" | tee "$out/probe-gui.json"
"$here/keychain_items.sh" clean "$existing"
