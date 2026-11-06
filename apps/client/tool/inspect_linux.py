#!/usr/bin/env python3
"""Inspect every ELF in a runtime bundle; ISA notes are necessary, not CPU proof."""
import json
from pathlib import Path
import re
import subprocess
import sys

LIMITS = {"GLIBC": (2, 36), "GLIBCXX": (3, 4, 30), "CXXABI": (1, 3, 13)}


def inspect_elf(path):
    result = subprocess.run(["readelf", "-W", "-h", "-n", "-V", "-d", str(path)],
                            check=True, text=True, capture_output=True).stdout
    if not re.search(r"Class:\s+ELF64", result) or not re.search(r"Machine:\s+Advanced Micro Devices X86-64", result):
        raise ValueError(f"{path.name}: require an x86_64 ELF64 binary")
    search_paths = re.findall(r"\((?:RPATH|RUNPATH)\).*?\[(.*?)\]", result)
    if any(entry not in ("$ORIGIN", "$ORIGIN/lib") for paths in search_paths for entry in paths.split(":")):
        raise ValueError(f"{path.name}: unexpected runtime library search path: {search_paths}")
    needed = [line.split(", x86 ", 1)[0] for line in re.findall(r"x86 ISA needed: (.+)", result)]
    if any(token.strip() != "x86-64-baseline" for line in needed for token in line.split(",")):
        raise ValueError(f"{path.name}: nonbaseline CPU ISA requirement: {needed}")
    # Only version requirements, not definitions of symbols exported by a library.
    version_needs = result.split("Version needs section", 1)[-1] if "Version needs section" in result else ""
    versions = {}
    for namespace, limit in LIMITS.items():
        found = {tuple(map(int, value.split("."))) for value in re.findall(rf"Name: {namespace}_([0-9.]+)", version_needs)}
        if found:
            highest = max(found)
            if highest > limit:
                raise ValueError(f"{path.name}: {namespace}_{'.'.join(map(str, highest))} exceeds Debian 12 ABI ceiling")
            versions[namespace] = ".".join(map(str, highest))
    if "GLIBC_PRIVATE" in version_needs:
        raise ValueError(f"{path.name}: depends on private glibc ABI")
    return {"isa_needed": needed, "runtime_search_paths": search_paths, "max_required_symbol_versions": versions,
            "needed_libraries": re.findall(r"\(NEEDED\).*?\[(.*?)\]", result)}


def inspect_bundle(root):
    results = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Unexpected bundle symlink: {path}")
        if path.is_file():
            with path.open("rb") as stream:
                is_elf = stream.read(4) == b"\x7fELF"
            if is_elf:
                results[str(path.relative_to(root))] = inspect_elf(path)
    required = {"anj_cloud", "lib/libflutter_linux_gtk.so", "lib/libapp.so", "lib/libanj_rootfs.so"}
    if not required <= results.keys():
        raise ValueError(f"Missing expected runtime ELFs: {sorted(required - results.keys())}")
    return results


if __name__ == "__main__":
    try:
        print(json.dumps(inspect_bundle(Path(sys.argv[1])), indent=2))
    except (ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
