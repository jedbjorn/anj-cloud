#!/usr/bin/env bash
# The Linux libanj_rootfs.so exports exactly the shared C ABI in
# native/posix/exports.txt (spec #31 S2). Run by tool/check.sh after
# tool/build_rootfs.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
# Every defined dynamic symbol named anj_* (functions, data, weak), so an
# extra exported variable or weak function fails too; blank lines ignored.
want=$(grep -v -e '^#' -e '^[[:space:]]*$' native/posix/exports.txt | sort)
got=$(nm -D --defined-only .dart_tool/libanj_rootfs.so | awk '$3 ~ /^anj_/ { print $3 }' | sort)
if [ "$got" != "$want" ]; then
  echo "libanj_rootfs.so exports differ from native/posix/exports.txt:" >&2
  diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") >&2 || true
  exit 1
fi
echo "Export check: libanj_rootfs.so exports exactly native/posix/exports.txt ($(printf '%s\n' "$want" | wc -l) symbols)."
