#!/usr/bin/env bash
# A publishable macOS release (spec #40 R2), driven from the VM host: the commit is
# checked out alone, its version code and version computed as
# tool/package_linux.py does (`git rev-list --count`, the commit's UTC date),
# the source sent to mac-test, built and stamped there by
# tool/macos/package_release.sh --version-code --version, and the archive
# and receipts fetched back. Publish the archive with
#   python3 deploy/release.py publish --target macos-arm64 --artifact <zip>
#
#   release_macos.sh <commit> <out dir> [--source-ref <ref>] [--task <shell>/<task>]
#
# The commit must be in origin/main (fetched first); --source-ref names
# another ref for disposable review-stack proofs only (deploy/release.py
# then needs --local-project and the same --source-ref). <out dir> must not
# exist. Owner TAG for the mac-test lifecycle: the task's prefix (default
# LANE1/macrel-1, owner macrel); the guest task directory is removed after.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
commit=${1:?usage: release_macos.sh <commit> <out dir> [--source-ref <ref>] [--task <shell>/<task>]}
out=${2:?usage}; shift 2
ref=origin/main task=LANE1/macrel-1
while (( $# )); do
  case $1 in
    --source-ref) ref=${2:?}; shift 2 ;;
    --task) task=${2:?}; shift 2 ;;
    *) echo "release_macos.sh: unknown option $1" >&2; exit 64 ;;
  esac
done
[[ $out == /* && ! -e $out ]] || { echo "release_macos.sh: <out dir> must be an absolute path that does not exist" >&2; exit 64; }
owner=${task#*/}; owner=${owner%%-*}
git -C "$repo" fetch --quiet origin main
commit=$(git -C "$repo" rev-parse --verify "$commit^{commit}")
[[ $(git -C "$repo" rev-parse --is-shallow-repository) == false ]] || { echo "release_macos.sh: use a full clone" >&2; exit 1; }
git -C "$repo" merge-base --is-ancestor "$commit" "$ref" || { echo "release_macos.sh: ${commit:0:12} is not in $ref" >&2; exit 1; }
code=$(git -C "$repo" rev-list --count "$commit")
date=$(TZ=UTC git -C "$repo" show -s --format=%cd --date=format-local:%Y.%m.%d "$commit")
version="$date.$code"
mkdir -p "$out"
tree=$(mktemp -d "${TMPDIR:-/tmp}/anj-macrel.XXXXXX")
cleanup() {
  "$tree/src/apps/client/tool/macos/mac_test.sh" clean "$owner" > "$out/guest-clean.txt" 2>&1 || true
  git -C "$repo" worktree remove --force "$tree/src" >/dev/null 2>&1 || true
  rm -rf -- "$tree"
}
trap cleanup EXIT
git -C "$repo" worktree add --quiet --detach "$tree/src" "$commit"
client="$tree/src/apps/client"
mt="$client/tool/macos/mac_test.sh"
echo "release $version (version_code $code) from ${commit:0:12}"
"$mt" send "$task" | tee "$out/send.txt"
"$mt" run "$task" "perl -e 'alarm 1200; exec @ARGV' zsh tool/macos/package_release.sh build/release --version-code $code --version $version" \
  | tee "$out/package.log"
"$mt" fetch "$task" build/release "$out"
zip=$(ls "$out"/build/release/anj-cloud-macos-arm64-*.zip)
mv "$out"/build/release/* "$out"/ && rm -rf "$out/build"
zip="$out/$(basename "$zip")"
(cd "$out" && shasum -a 256 -c "$(basename "$zip").sha256")
echo "$zip"
