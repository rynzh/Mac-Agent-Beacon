# Agent Beacon

Use the Caps Lock LED on an Apple built-in keyboard as a quiet status light for coding agents.

Agent Beacon is a macOS-only, local-first prototype. It writes the physical Caps Lock LED without sending keystrokes, changing logical Caps Lock state, or storing prompts and agent responses.

## Status light

| Agent state | LED |
| --- | --- |
| Working or retrying | Solid on |
| Waiting for approval, usage limit reached, or terminal task failure | Fast blink (0.2 seconds on, 0.2 seconds off) |
| Completed or idle | Off |

When more than one agent is active, attention takes precedence over working. A task that is actively retrying remains solid; the light only blinks after a terminal failure is recorded.

## What it supports

- Apple Internal Keyboard / Trackpad Caps Lock LED only.
- Codex lifecycle hooks and read-only observation of local Codex task status, including `usageLimitExceeded` when the local status database provides it.
- Claude Code lifecycle hooks and notification events.
- A generic CLI event interface for other local agents.
- Optional persistent remapping for the built-in keyboard only: Caps Lock → left Command, right Command → left Control, right Option → F19.

The built-in-keyboard remapping is optional. It exists because Karabiner can exclusively own the device, preventing direct LED access. External keyboards are not changed.

## Requirements

- macOS with an Apple Internal Keyboard / Trackpad
- Xcode Command Line Tools (`clang`)
- Ruby 2.6+
- Input Monitoring permission for the installed `beacon-led` helper

## Quick start

### One command install

From a cloned checkout:

```sh
./install.sh
```

It copies the runtime to `~/Library/Application Support/AgentBeacon/app/`, builds it, runs its tests, and installs Codex hooks. Add `--with-claude` to install Claude Code hooks too. It never enables keyboard remapping unless you explicitly pass `--install-mapping`.

After publishing the repository, users can install without cloning first:

```sh
curl -fsSL https://raw.githubusercontent.com/rynzh/Mac-Agent-Beacon/main/install.sh | bash -s -- --repo https://github.com/rynzh/Mac-Agent-Beacon.git
```

The installer stops for the two required user-controlled approvals: Input Monitoring and Codex `/hooks` trust.

### Manual install

Clone the repository, then build and test:

```sh
make
make test
ruby bin/agent-beacon.rb doctor
```

`doctor` only discovers the LED interface. It does not prove that the LED is writable.

Stop any existing controller before running the physical check:

```sh
ruby bin/agent-beacon.rb stop
ruby bin/agent-beacon.rb demo
```

The demo blinks the LED for about four seconds, then restores the physical LED to the current logical Caps Lock state. Confirm the result visually before continuing.

### Grant Input Monitoring

Open **System Settings → Privacy & Security → Input Monitoring** and allow the exact `build/beacon-led` executable that will run. If macOS asks you to restart the parent application, save work and restart it.

Agent Beacon does not fall back to simulated Caps Lock presses when access is denied.

## Connect agents

Install hooks from the repository directory:

```sh
ruby bin/agent-beacon.rb install-hooks codex
ruby bin/agent-beacon.rb install-hooks claude
```

This makes timestamped backups and only adds Agent Beacon's own handlers. Codex requires you to review and trust newly installed hooks through `/hooks`; do not bypass that review.

For another local agent, emit lifecycle events directly:

```sh
ruby bin/agent-beacon.rb event my-agent session-1 working
ruby bin/agent-beacon.rb event my-agent session-1 attention
ruby bin/agent-beacon.rb event my-agent session-1 done
ruby bin/agent-beacon.rb event my-agent session-1 idle
```

Use a stable session ID. An optional turn ID prevents an older completion signal from overwriting a newer turn.

## Optional persistent keyboard mapping

Only use this after the LED demo succeeds and you want Caps Lock to act as Command while retaining LED control:

```sh
ruby bin/persistence.rb install
```

This changes the selected Karabiner profile so it ignores the built-in keyboard, writes three built-in-keyboard HID mappings, and installs two per-user LaunchAgents. It refuses to overwrite an unexpected non-empty system mapping or an existing Karabiner device override.

To undo those changes:

```sh
ruby bin/persistence.rb uninstall
ruby bin/agent-beacon.rb uninstall-hooks codex
ruby bin/agent-beacon.rb uninstall-hooks claude
```

Read [docs/SAFETY.md](docs/SAFETY.md) before using this option.

## Operations

```sh
ruby bin/agent-beacon.rb status
ruby bin/agent-beacon.rb clear
ruby bin/agent-beacon.rb stop
```

Runtime files are stored under `~/Library/Application Support/AgentBeacon/`. They contain state, locks and logs; they do not contain prompts, responses or tool arguments.

`status` reports whether the controller is running. `output.simulated: true` means a test-only controller was used and is not proof that hardware control worked.

## Privacy and compatibility

The Codex observer queries only local task IDs, timestamps, status and error classification from `thread_turns`. It does not query message content. This is an internal local storage format rather than a supported public API, so it may need updating after Codex changes its database schema.

This project has been exercised on one macOS installation only. Sleep/wake behavior, different Apple keyboard generations, and all Karabiner configurations need independent verification.

## Development

```sh
make test
AGENT_BEACON_SIMULATE=1 ruby bin/agent-beacon.rb event test session-1 working
```

The simulation environment variable prevents HID access and is suitable only for controller tests.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please include macOS version, keyboard model, and whether Karabiner was enabled in hardware reports; never attach private agent transcripts.

## License

Agent Beacon is licensed under the [MIT License](LICENSE). The LED helper adapts CapsPulse code; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
