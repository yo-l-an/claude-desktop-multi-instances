#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PROFILE_DELETE_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/claude-delete-profile.XXXXXX")"
trap 'rm -rf "$PROFILE_DELETE_CACHE"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export CLANG_MODULE_CACHE_PATH="$PROFILE_DELETE_CACHE"
/usr/bin/swift "$ROOT/scripts/delete-profile.swift" "$@"
