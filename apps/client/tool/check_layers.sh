#!/usr/bin/env bash
# Layer rule (decision #74, ARCHITECTURE.md): shared code (lib/core, lib/ui,
# lib/design, lib/main.dart) never imports, exports or includes a part from
# lib/platform/<os>/. It reaches a platform only through
# lib/platform/adapters.dart.
set -euo pipefail
cd "$(dirname "$0")/.."
pattern="^[[:space:]]*(import|export|part)[[:space:]]+['\"][^'\"]*platform/[^/'\"]+/"
if matches=$(grep -rnE --include='*.dart' "$pattern" lib/core lib/ui lib/design lib/main.dart); then
  echo "Shared code imports platform-specific code:" >&2
  echo "$matches" >&2
  exit 1
fi
echo "Layer check: shared code does not import lib/platform/<os>/."
