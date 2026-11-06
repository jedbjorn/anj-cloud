#!/bin/zsh
# Release build, archive and receipt (spec #31 M6). Runs ON mac-test from the
# client directory tool/macos/mac_test.sh sent (its .anj-source names the
# commit). No signing identity: the build is ad-hoc signed (decision #117 (3),
# #124); only Release builds are handed out (ARCHITECTURE.md, macOS).
#
#   package_release.sh <out dir> [--skip-build] [--version-code <n> --version <v>]
#
# With --version-code and --version (spec #40 R2; tool/macos/release_macos.sh
# computes them on the VM host as package_linux.py does: `git rev-list --count` and
# the commit's UTC date), the build is an in-app-updatable release: its
# CFBundleVersion is the version code, and Contents/Resources/
# bundle-receipt.json {platform, target, version, version_code,
# source_head} is stamped into the bundle and the bundle signed again
# (ad-hoc, hardened runtime, Release entitlements), so the manager's
# apply-update and deploy/release.py can read it. Such a release must come
# from a clean source (no uncommitted files).
#
# 1. flutter build macos --release (timed: build-seconds in the receipt)
# 2. tool/macos/verify_bundle.sh release (seal, entitlements, embedded
#    manager byte-identical to tool/macos/anj-cloud-macos-install.sh)
# 3. ditto -c -k --keepParent "AnJ Cloud.app" <name>.zip, with
#    <name> = anj-cloud-macos-arm64-<version>+<build>-<commit12>
# 4. <name>.zip.sha256 (shasum format) and <name>.receipt.json: version,
#    build, source commit, Flutter/Dart/Xcode/macOS versions, cdhash,
#    archive SHA-256 and size, the embedded manager's SHA-256, and the
#    in-app release fields (spec #40 R2, "release"; null without
#    --version-code).
# The receipt's SHA-256 is what the operator passes to
#   anj-cloud-macos-install.sh install|update <zip> --sha256 <hex>
# Exit 0 only when every step passes.
set -u
cd "${0:A:h}/../.."
out=${1:?usage: package_release.sh <out dir> [--skip-build] [--version-code <n> --version <v>]}
shift
skip=0 version_code= release_version=
while (( $# )); do
  case $1 in
    --skip-build) skip=1; shift ;;
    --version-code) version_code=${2:?}; shift 2 ;;
    --version) release_version=${2:?}; shift 2 ;;
    *) echo "usage: package_release.sh <out dir> [--skip-build] [--version-code <n> --version <v>]" >&2; exit 64 ;;
  esac
done
if [[ -n $version_code$release_version ]]; then
  [[ $version_code == <1-2100000000> && $release_version =~ '^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$' ]] ||
    { echo "FAIL  --version-code and --version must both be given and valid"; exit 64; }
fi
mkdir -p "$out"; out=${out:A}
export FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
app="build/macos/Build/Products/Release/AnJ Cloud.app"
q() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

seconds=null
if (( ! skip )); then
  flutter --suppress-analytics pub get > "$out/pub-get.log" 2>&1 || { echo "FAIL  flutter pub get"; tail -20 "$out/pub-get.log"; exit 1; }
  start=$SECONDS
  number=(); [[ -n $version_code ]] && number=(--build-number "$version_code")
  # anj-defines.env (the deployment profile's origin) is sent by mac_test.sh when the profile is real.
  defines=(); [[ -f anj-defines.env ]] && defines=(--dart-define-from-file=anj-defines.env)
  if ! flutter --suppress-analytics build macos --release $number $defines > "$out/build-release.log" 2>&1; then
    echo "FAIL  flutter build macos --release after $((SECONDS - start)) s"; tail -30 "$out/build-release.log"; exit 1
  fi
  seconds=$((SECONDS - start))
  echo "pass  flutter build macos --release in ${seconds} s"
fi
source_line=$(head -1 .anj-source 2>/dev/null || echo unknown)
commit=$(printf '%s' "$source_line" | sed -n 's/^commit \([0-9a-f]\{40\}\),.*/\1/p')
dirty=$(printf '%s' "$source_line" | sed -n 's/^commit [0-9a-f]*, \([0-9]*\) uncommitted.*/\1/p')
[[ -n $commit ]] || { echo "FAIL  no source commit (send with tool/macos/mac_test.sh)"; exit 1; }
if [[ -n $version_code ]]; then
  [[ $dirty == 0 ]] || { echo "FAIL  an in-app-updatable release needs a clean source ($dirty uncommitted files)"; exit 1; }
  printf '{"platform": "macOS arm64", "target": "macos-arm64", "version": "%s", "version_code": %s, "source_head": "%s"}\n' \
    "$release_version" "$version_code" "$commit" > "$app/Contents/Resources/bundle-receipt.json"
  if ! codesign --force --sign - --options runtime --entitlements macos/Runner/Release.entitlements "$app" \
      > "$out/resign.log" 2>&1; then
    echo "FAIL  signing the bundle again after stamping its receipt"; tail -5 "$out/resign.log"; exit 1
  fi
  echo "pass  receipt stamped: version $release_version, version_code $version_code"
fi
if ! sh tool/macos/verify_bundle.sh "$app" release > "$out/bundle-release.log" 2>&1; then
  echo "FAIL  bundle checks (release)"; grep FAIL "$out/bundle-release.log"; exit 1
fi
echo "pass  bundle checks (release)"

plist="$app/Contents/Info.plist"
version=$(plutil -extract CFBundleShortVersionString raw -o - "$plist")
build=$(plutil -extract CFBundleVersion raw -o - "$plist")
cdhash=$(codesign -dvvv "$app" 2>&1 | sed -n 's/^CDHash=//p')
name="anj-cloud-macos-arm64-$version+$build-${commit[1,12]}"
zip="$out/$name.zip"
rm -f "$zip"
(cd "${app:h}" && ditto -c -k --keepParent "AnJ Cloud.app" "$zip") || { echo "FAIL  ditto"; exit 1; }
sha=$(shasum -a 256 "$zip" | awk '{ print $1 }')
size=$(wc -c < "$zip" | tr -d ' ')
(cd "$out" && shasum -a 256 "$name.zip" > "$name.zip.sha256")
manager_sha=$(shasum -a 256 "$app/Contents/Resources/anj-cloud-macos-install.sh" | awk '{ print $1 }')
flutter --version --machine > "$out/flutter-version.json" 2>/dev/null
fv=$(plutil -extract frameworkVersion raw -o - "$out/flutter-version.json" 2>/dev/null)
dv=$(plutil -extract dartSdkVersion raw -o - "$out/flutter-version.json" 2>/dev/null)
xv=$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
cat > "$out/$name.receipt.json" <<EOF
{
  "schema": "anj-cloud-macos-release-receipt-v2",
  "target": "macos-arm64",
  "bundle_id": "cloud.anj.anj-cloud",
  "version": $(q "$version"),
  "build": $(q "$build"),
  "archive": $(q "$name.zip"),
  "archive_sha256": $(q "$sha"),
  "archive_size": $size,
  "source_commit": $(q "$commit"),
  "source_uncommitted_files": ${dirty:-null},
  "signature": "adhoc",
  "cdhash": $(q "$cdhash"),
  "manager_sha256": $(q "$manager_sha"),
  "flutter": $(q "$fv"),
  "dart": $(q "$dv"),
  "xcode": $(q "$xv"),
  "macos": $(q "$(sw_vers -productVersion) ($(sw_vers -buildVersion))"),
  "build_seconds": $seconds,
  "built_at": $(q "$(date -u +%Y-%m-%dT%H:%M:%SZ)"),
  "release": $([[ -n $version_code ]] && printf '{"version": %s, "version_code": %s, "publish": "python3 deploy/release.py publish --target macos-arm64 --artifact %s"}' "$(q "$release_version")" "$version_code" "$name.zip" || printf null)
}
EOF
plutil -lint "$out/$name.receipt.json" >/dev/null 2>&1 || /usr/bin/python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$out/$name.receipt.json" ||
  { echo "FAIL  receipt is not valid JSON"; exit 1; }
echo "pass  archive $name.zip ($size bytes) sha256 $sha cdhash $cdhash"
echo "$zip"
