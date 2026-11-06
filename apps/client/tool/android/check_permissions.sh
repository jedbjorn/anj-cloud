#!/usr/bin/env bash
# The APK's permission set is exactly the allowlist (spec #28 A3: the camera plugin adds
# CAMERA and nothing else; PR #63 review F6). Run on every APK build_apk.sh makes.
#   tool/android/check_permissions.sh <apk>
set -euo pipefail
APK="${1:?usage: $0 <apk>}"
. $HOME/.local/share/anj-cloud/toolchains/android/env.sh
AAPT2="$(ls -d "$ANDROID_HOME"/build-tools/*/ | sort -V | tail -1)aapt2"
dump="$("$AAPT2" dump permissions "$APK")"
pkg="$(sed -n "s/^package: //p" <<<"$dump")"
actual="$(sed -n "s/^uses-permission: name='\([^']*\)'.*/\1/p" <<<"$dump" | sort)"
# INTERNET: the gateway. CAMERA: the invitation scan. Background sync (A4): the network
# setting, WorkManager after reboot, the dataSync service and its notifications; WAKE_LOCK
# comes with WorkManager. The in-app updater (A7) installs through PackageInstaller. The receiver permission is androidx.core's own signature
# permission for unexported dynamic receivers.
expected="$(printf '%s\n' android.permission.INTERNET android.permission.CAMERA \
  android.permission.ACCESS_NETWORK_STATE android.permission.RECEIVE_BOOT_COMPLETED \
  android.permission.FOREGROUND_SERVICE android.permission.FOREGROUND_SERVICE_DATA_SYNC \
  android.permission.POST_NOTIFICATIONS android.permission.WAKE_LOCK \
  android.permission.REQUEST_INSTALL_PACKAGES \
  "$pkg.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION" | sort)"
if [ "$actual" != "$expected" ]; then
  echo "FAIL $APK permissions differ from the allowlist" >&2
  diff <(echo "$expected") <(echo "$actual") >&2 || true
  exit 1
fi
"$AAPT2" dump xmltree "$APK" --file AndroidManifest.xml \
  | grep -A2 'uses-feature' | grep -A1 'android.hardware.camera.any' | grep -q 'required.*=false' \
  || { echo "FAIL android.hardware.camera.any must be optional" >&2; exit 1; }
echo "PASS $pkg permissions: $(tr '\n' ' ' <<<"$actual")"
