# Homebrew distribution

The Tap is [rynzh/homebrew-tap](https://github.com/rynzh/homebrew-tap).
It installs the controller and C helper in Homebrew's `libexec` directory, with
an `agent-beacon` launcher under Homebrew's `bin`. Hook commands use the stable
`opt/agent-beacon/bin/agent-beacon` path. Logs and state remain under
`~/Library/Application Support/AgentBeacon`, outside the versioned Cellar.

## Installation

```sh
brew install rynzh/tap/agent-beacon && agent-beacon setup
```

Setup merges hooks with backups and starts a Homebrew-managed user service.
Repeated setup replaces only matching Beacon hooks, preserving other handlers.
It never grants permissions or modifies keyboard mappings. If service startup
fails, the hooks remain installed and setup can be retried.

Input Monitoring and Codex hook trust are manual. The helper path is printed by
setup. The service retries after startup failure. To retry immediately after
authorization, run `brew services restart agent-beacon`.

Ruby is a Homebrew dependency. The observer uses macOS's `/usr/bin/sqlite3`.
The service and hooks do not depend on an interactive shell's PATH.

## Previous installations

Do not run two installations against the same LED. Setup detects the legacy
`local.agent-beacon.controller` LaunchAgent and refuses to overwrite it.
For the source installer, remove its Codex hooks and managed service with its
original `beacon` command before running Homebrew setup. Retain backups.
For early installations that also managed keyboard mappings, follow
[the migration notes](SAFETY.md); do not remove their service blindly.

## Upgrade and removal

Run `brew upgrade agent-beacon`, followed by `agent-beacon setup` to restart the
controller. Stable hook paths survive version changes. This does not guarantee
that macOS retains LED permission: the helper is not Developer ID signed yet.
Reauthorize the helper if necessary.

Run `agent-beacon uninstall` before `brew uninstall agent-beacon`. This stops the
Homebrew service and removes matching hooks; logs and backups remain.

## Release process

1. Commit and test the intended source revision.
2. Push a semantic version tag, such as `v0.2.0`.
3. The source release workflow tests and publishes a tarball, checksums and a
   generated Formula as a GitHub prerelease.
4. Copy the released Formula to the Tap, review it, and commit it.
5. Dispatch the Tap's `bottles` workflow. It builds on Apple Silicon and Intel
   macOS 15, tests the command, creates bottles, reinstalls them and tests again.
6. Successful builds publish bottle assets and commit their checksums into the
   Formula. Promote the source prerelease only after reviewing the results.

The workflow template is `packaging/bottles.yml`; the active copy lives in the
Tap. Updating the main repository template does not update the Tap automatically.

Hosted runners cannot verify a real keyboard LED or macOS Input Monitoring UI.
Physical-device approval, upgrade and sleep/wake tests remain separate checks.
On systems without a compatible bottle, Homebrew can fall back to source builds;
do not advertise those platforms as requiring no compiler.
