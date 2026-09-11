#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --repo URL            Clone this public repository before installation.
  --with-claude         Install Claude Code hooks as well as Codex hooks.
  --install-mapping     Opt in to the built-in Caps Lock remapping installer.
  --no-hooks            Build and install files without modifying agent config.
  --help                Show this help.

For a published repository:
  curl -fsSL https://raw.githubusercontent.com/rynzh/Mac-Agent-Beacon/main/install.sh | bash -s -- --repo https://github.com/rynzh/Mac-Agent-Beacon.git
EOF
}

REPO_URL=''
WITH_CLAUDE=0
INSTALL_MAPPING=0
INSTALL_HOOKS=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO_URL=${2:?missing repository URL}; shift 2 ;;
    --with-claude) WITH_CLAUDE=1; shift ;;
    --install-mapping) INSTALL_MAPPING=1; shift ;;
    --no-hooks) INSTALL_HOOKS=0; shift ;;
    --help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 64 ;;
  esac
done

SOURCE_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
TEMP_SOURCE=''
cleanup() {
  [ -z "$TEMP_SOURCE" ] || rm -rf "$TEMP_SOURCE"
}
trap cleanup EXIT INT TERM

if [ -n "$REPO_URL" ]; then
  command -v git >/dev/null 2>&1 || { printf 'git is required to clone the repository.\n' >&2; exit 1; }
  TEMP_SOURCE=$(mktemp -d "${TMPDIR:-/tmp}/agent-beacon.XXXXXX")
  git clone --depth=1 "$REPO_URL" "$TEMP_SOURCE/source"
  SOURCE_DIR="$TEMP_SOURCE/source"
fi

for required in Makefile bin/agent-beacon.rb bin/codex-status.rb bin/codex-live.rb bin/persistence.rb native/led.c; do
  [ -e "$SOURCE_DIR/$required" ] || { printf 'Not an Agent Beacon source directory: %s\n' "$SOURCE_DIR" >&2; exit 1; }
done

INSTALL_ROOT="${AGENT_BEACON_HOME:-$HOME/Library/Application Support/AgentBeacon}"
APPLICATION="$INSTALL_ROOT/app"
[ ! -e "$APPLICATION" ] || {
  printf 'Agent Beacon is already installed at: %s\n' "$APPLICATION" >&2
  printf 'Use the existing installation or uninstall it before reinstalling.\n' >&2
  exit 1
}

STAGING="$INSTALL_ROOT/.app-install-$$"
rm -rf "$STAGING"
mkdir -p "$STAGING"
for item in Makefile THIRD_PARTY_NOTICES.md LICENSE bin native test; do
  cp -R "$SOURCE_DIR/$item" "$STAGING/"
done

(
  cd "$STAGING"
  make test
)
mv "$STAGING" "$APPLICATION"

if [ "$INSTALL_HOOKS" -eq 1 ]; then
  /usr/bin/ruby "$APPLICATION/bin/agent-beacon.rb" install-hooks codex
  if [ "$WITH_CLAUDE" -eq 1 ]; then
    /usr/bin/ruby "$APPLICATION/bin/agent-beacon.rb" install-hooks claude
  fi
fi

if [ "$INSTALL_MAPPING" -eq 1 ]; then
  /usr/bin/ruby "$APPLICATION/bin/persistence.rb" install
fi

cat <<EOF

Agent Beacon installed at:
  $APPLICATION

Next required steps:
  1. System Settings → Privacy & Security → Input Monitoring:
     allow $APPLICATION/build/beacon-led
  2. In Codex CLI, run /hooks and review/trust Agent Beacon handlers.
  3. Run this physical check after permission is granted:
     /usr/bin/ruby "$APPLICATION/bin/agent-beacon.rb" demo
EOF
