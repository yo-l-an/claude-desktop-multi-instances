#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

usage() {
  printf '%s\n' 'Usage: "./Claude Profiles - macOS.command" [ACTION [ARGUMENTS...]]' \
    'Without ACTION, choose from a menu.' \
    '  create [--validate] [--config FILE] [--output DIR] [--install-dir DIR]' \
    '  delete [PROFILE] [--dry-run]'
}

delete_profile() {
  PROFILE_DELETE_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/claude-delete-profile.XXXXXX")"
  trap 'rm -rf "$PROFILE_DELETE_CACHE"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  CLANG_MODULE_CACHE_PATH="$PROFILE_DELETE_CACHE" /usr/bin/swift "$ROOT/scripts/macos/delete-profile.swift" "$@"
}

ACTION="${1:-}"
if [[ -z "$ACTION" ]]; then
  printf '%s\n' 'Claude Profiles' '' '1. Create launchers' '2. Delete a profile' ''
  read -r -p 'Number (Enter to cancel): ' CHOICE || CHOICE=''
  case "$CHOICE" in
    1) ACTION=create ;;
    2) ACTION=delete ;;
    '') echo 'Cancelled.'; exit 0 ;;
    *) echo 'Invalid selection.' >&2; exit 1 ;;
  esac
  echo
else
  shift
fi

case "$ACTION" in
  create) exec "$ROOT/scripts/macos/generate-launchers.sh" --install "$@" ;;
  delete) delete_profile "$@" ;;
  -h|--help) usage ;;
  *) echo "Unknown action: $ACTION. Use --help for usage." >&2; exit 1 ;;
esac
