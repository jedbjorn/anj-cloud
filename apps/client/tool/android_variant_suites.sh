#!/usr/bin/env bash
# The shared engine suites whose storage behaviour depends on how installs are
# made, run against the host build of the Android boundary
# (-DANJ_ANDROID_BOUNDARY: no openat2, installs cannot link) with the engine
# told so (ANJ_ROOTFS_HARDLINKS=0). PR #60 review F1/F3: staging must hold no
# copy beyond the root, and recovery-copy rules must agree with Linux. Main's
# top-folder restore (spec #34 P7) and share placement (P6) install through
# the same paths, so their suites run here too, as do the phone folders (spec
# #52), whose installs cross into a second staging folder.
# Run by tool/check.sh after the Linux suite.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${FLUTTER_SDK:=$HOME/.local/share/anj-cloud/toolchains/flutter-3.47.9}"
mkdir -p .dart_tool
clang++ -std=c++17 -Wall -Wextra -Werror -O2 -fPIC -shared -DANJ_ANDROID_BOUNDARY \
  native/posix/rootfs.cc -o .dart_tool/libanj_rootfs_android.so
suites=(test/android_storage_test.dart test/staging_release_test.dart
  test/recover_dismiss_test.dart test/eviction_test.dart
  test/edit_completion_test.dart test/root_retention_test.dart test/sync_test.dart
  test/top_folders_test.dart test/sharing_engine_test.dart test/add_files_test.dart
  test/phone_folders_test.dart)
if [ -n "${ANJ_TEST_EXCLUDE:-}" ]; then   # CI: the same seat-dependent files tool/check.sh skips
  mapfile -t suites < <(printf '%s\n' "${suites[@]}" | grep -Ev "$ANJ_TEST_EXCLUDE")
fi
ANJ_ROOTFS_LIBRARY="$PWD/.dart_tool/libanj_rootfs_android.so" ANJ_ROOTFS_HARDLINKS=0 \
  "$FLUTTER_SDK/bin/flutter" --suppress-analytics test --concurrency=1 "${suites[@]}"
