#!/bin/bash
set -euo pipefail

REPO_URL=https://github.com/rynzh/Mac-Agent-Beacon.git
REPO_REF=main
FORCE_DOWNLOAD=0
SETUP_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO_URL=${2:?missing repository URL}; FORCE_DOWNLOAD=1; shift 2 ;;
    --ref) REPO_REF=${2:?missing branch or tag}; FORCE_DOWNLOAD=1; shift 2 ;;
    --help)
      printf '%s\n' 'Agent Beacon: installs app, Codex hooks and login service; does not grant permissions or remap keys.'
      printf '%s\n' 'Options: --with-claude --prefix PATH --no-hooks --no-service --repo URL --ref BRANCH_OR_TAG'
      exit 0 ;;
    --prefix) SETUP_ARGS+=("$1" "${2:?missing installation path}"); shift 2 ;;
    --with-claude|--no-hooks|--no-service) SETUP_ARGS+=("$1"); shift ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 64 ;;
  esac
done

[ "$(uname -s)" = Darwin ] || { printf 'macOS is required.\n' >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { printf 'Run without sudo, as your normal user.\n' >&2; exit 1; }
[ -x /usr/bin/ruby ] || { printf 'System Ruby 2.6+ is required.\n' >&2; exit 1; }
/usr/bin/ruby -e 'abort "Ruby 2.6+ required" if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("2.6")'
if ! /usr/bin/xcode-select -p >/dev/null 2>&1 || ! /usr/bin/xcrun --find clang >/dev/null 2>&1; then
  printf 'Install Apple Command Line Tools first: xcode-select --install\nThen rerun this installer.\n' >&2
  exit 1
fi
for dependency in make git sqlite3; do
  command -v "$dependency" >/dev/null || { printf 'Missing dependency: %s\n' "$dependency" >&2; exit 1; }
done

SOURCE_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ "$FORCE_DOWNLOAD" -eq 0 ] && [ -f "$SOURCE_DIR/bin/setup.rb" ]; then
  exec /usr/bin/ruby "$SOURCE_DIR/bin/setup.rb" "${SETUP_ARGS[@]}"
fi

# Ruby owns and cleans its unique temporary directory even if clone/build fails.
exec /usr/bin/ruby -rtmpdir -e '
  repo, ref, *options = ARGV
  Dir.mktmpdir("agent-beacon-download-") do |directory|
    source = File.join(directory, "source")
    abort "Download failed; nothing installed" unless system("git", "clone", "--depth=1", "--branch", ref, "--", repo, source)
    abort "Downloaded source lacks setup.rb; publish the new installer first" unless File.file?(File.join(source, "bin/setup.rb"))
    abort "Installation failed" unless system(RbConfig.ruby, File.join(source, "bin/setup.rb"), *options)
  end
' "$REPO_URL" "$REPO_REF" "${SETUP_ARGS[@]}"
