#!/usr/bin/env bash
# Build the public source tree: the tracked files of this checkout minus everything that is private
# or specific to one household, copied into a new directory and then checked by the gate.
#
#   tool/export_public.sh <out-dir>
#
# <out-dir> must not exist. The script only copies and scans: it never pushes, never creates a
# repository and never talks to GitHub. Exit 0 means the export passed the gate; any other exit
# means do not publish the directory. Writes <out-dir>/EXPORT-MANIFEST.txt.
#
# The gate (tool/export_gate.py) needs gitleaks on PATH (or GITLEAKS=/path/to/gitleaks) and reads the
# household identifiers to refuse from your deployment profile ([export] in profile.toml), so the
# public tree itself never contains them.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
out=${1:?usage: tool/export_public.sh <out-dir>}
[[ $out == /* ]] || out=$PWD/$out
[[ ! -e $out && ! -L $out ]] || { echo "export_public: $out already exists; give a new directory" >&2; exit 64; }
cd "$repo"
if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
  echo "export_public: tracked files have uncommitted changes; commit them so the manifest names the exact source" >&2
  exit 64
fi
commit=$(git rev-parse HEAD)

# Paths that never leave the private repository: the Subfloor engine and agent files, the private
# plan, and the Android probe spike with its run results. A path ending in / is a directory prefix.
exclude=(
  sc CLAUDE.md AGENTS.md opencode.json
  .sc-state/ .subfloor/ .super-coder/ .claude/ .agents/ .opencode/ shared/ specs_sc/ docs_sc/
  docs/implementation-plan.md
  apps/android-probe/
)
excluded=()
count=0
mkdir -p "$out"
while IFS= read -r -d '' file; do
  skip=0
  for rule in "${exclude[@]}"; do
    if [[ $rule == */ ]]; then [[ $file == "$rule"* ]] && skip=1; else [[ $file == "$rule" ]] && skip=1; fi
  done
  if (( skip )); then excluded+=("$file"); continue; fi
  mkdir -p "$out/$(dirname "$file")"
  cp -P -- "$file" "$out/$file"
  count=$((count + 1))
done < <(git ls-files -z)

# The Subfloor block of .gitignore is private too.
if [[ -f $out/.gitignore ]]; then
  sed -i '/^# >>> subfloor managed ignores >>>$/,/^# <<< subfloor managed ignores <<<$/d' "$out/.gitignore"
fi

{
  echo "source commit: $commit"
  echo "files exported: $count"
  echo "tracked paths excluded: ${#excluded[@]}"
  echo "exclusion rules:"
  printf '  %s\n' "${exclude[@]}"
  echo "excluded tracked paths (first 200):"
  printf '  %s\n' "${excluded[@]:0:200}"
} > "$out/EXPORT-MANIFEST.txt"

python3 "$here/export_gate.py" "$out"
