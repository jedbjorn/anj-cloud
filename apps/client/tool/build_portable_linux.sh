#!/usr/bin/env bash
# Executed only inside the isolated packaging container. No host build paths.
set -euo pipefail
mkdir /work
cd /work
tar -xf /input/source.tar
cp -a /sdk-source /opt/flutter
# The read-only SDK source is copied before Flutter changes its internal cache.
git config --global --add safe.directory /opt/flutter
python3 apps/client/tool/deps.py
cd apps/client
# anj-defines.env (the deployment profile's origin) is added to the source archive by package_linux.py.
defines=()
[ -f anj-defines.env ] && defines=(--dart-define-from-file=anj-defines.env)
"$FLUTTER_SDK/bin/flutter" --suppress-analytics build linux --release "${defines[@]}"
python3 tool/inspect_linux.py build/linux/x64/release/bundle > /output/elf-audit.json
# Resolve all direct and transitive ELF dependencies against the baseline distro.
# ldd is used only on binaries just built from this committed source and SDK.
python3 - <<'PY'
import json
from pathlib import Path
import subprocess
bundle = Path('build/linux/x64/release/bundle')
audit = json.loads(Path('/output/elf-audit.json').read_text())
resolution = {}
for name in audit:
    output = subprocess.run(['ldd', str(bundle / name)], text=True, capture_output=True)
    # Some Dart AOT data ELFs deliberately have no dynamic section.
    if output.returncode and 'statically linked' not in output.stdout + output.stderr and 'not a dynamic executable' not in output.stdout + output.stderr:
        raise SystemExit(output.stdout + output.stderr)
    if 'not found' in output.stdout:
        raise SystemExit(output.stdout)
    resolution[name] = output.stdout.strip()
Path('/output/dependency-resolution.json').write_text(json.dumps(resolution, indent=2) + '\n')
PY
cp -a build/linux/x64/release/bundle /output/bundle
{ cat /etc/os-release; clang++ --version; readelf -n /usr/lib/x86_64-linux-gnu/Scrt1.o; dpkg-query -W; } > /output/build-toolchain.txt
