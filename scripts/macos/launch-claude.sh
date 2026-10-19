#!/bin/bash
set -euo pipefail

# Each app carries its profile identity, so renaming it is harmless.
CONTENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="$(/usr/libexec/PlistBuddy -c 'Print :ClaudeProfile' "$CONTENTS_DIR/Info.plist")"

if [[ -d /Applications/Claude.app ]]; then
  CLAUDE_APP=/Applications/Claude.app
elif [[ -d "$HOME/Applications/Claude.app" ]]; then
  CLAUDE_APP="$HOME/Applications/Claude.app"
else
  /usr/bin/osascript -e 'display alert "Claude not found" message "Install Claude Desktop in Applications, then open this launcher again." as critical'
  exit 1
fi

ARGS=(-n -a "$CLAUDE_APP")
case "$PROFILE" in
  default) ;;
  *)
    # Profile names are also validated by the builder; never interpret them as paths.
    [[ "$PROFILE" =~ ^[a-z0-9][a-z0-9-]*$ && ${#PROFILE} -le 64 ]] || {
      echo "Invalid profile: $PROFILE" >&2; exit 1;
    }
    PROFILE_DIR="$HOME/.claude-instances/$PROFILE"
    ARGS+=(--args "--user-data-dir=$PROFILE_DIR")
    ;;
esac

# Validate the exact command without launching Claude or creating profile data.
if [[ "${1:-}" == --dry-run ]]; then
  printf '%q ' /usr/bin/open "${ARGS[@]}"
  printf '\n'
  exit 0
fi

if [[ "$PROFILE" != default ]]; then
  umask 077
  mkdir -p "$PROFILE_DIR"
fi
exec /usr/bin/open "${ARGS[@]}"
