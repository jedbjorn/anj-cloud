#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .dart_tool
clang++ -std=c++17 -Wall -Wextra -Werror -O2 -fPIC -shared native/posix/rootfs.cc -o .dart_tool/libanj_rootfs.so
