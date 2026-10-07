#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cleanup() {
  rm -rf "$ROOT/.build"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$ROOT/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
/usr/bin/swift "$ROOT/scripts/generate-launchers.swift" "$@"
