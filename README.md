# Mac Agent Beacon

Use the Caps Lock LED on a MacBook as a status light for background Codex tasks.

**Solid = working · Fast blinking = needs attention · Off = finished**

Mac Agent Beacon runs locally and does not require an API key, cloud service,
or Node.js. Homebrew is recommended; a source installer is also available.
It controls status lights only: it does not press keys, remap
Caps Lock, or change your agent's approval policy.

<p align="center">
  <img
    src="assets/agent-beacon-hero.png"
    alt="Mac Agent Beacon status light"
    width="380"
  />
</p>


## Features

| Agent state | Caps Lock LED |
| --- | --- |
| Working, automatically approved, or retrying | Solid |
| Waiting for user approval or structured input | Fast blinking |
| Quota exhausted, terminal network/permission error, or observer disconnected during active work | Fast blinking |
| Finished or idle | Off |

- Attention takes priority when several tasks are active.
- The LED returns to solid as soon as an approval is resolved.
- Ordinary text such as “reply approve and I will continue” is not inferred.
- Temporary network retries remain solid; only a terminal interruption alerts.
- Built for Codex Desktop, with lifecycle hooks shared with Codex CLI.

### Optional whole-keyboard backlight alerts

The built-in keyboard backlight can blink in the same phase as the Caps Lock LED
when a task needs attention. It is off by default. To enable it:

```sh
agent-beacon backlight inspect
agent-beacon backlight on
```

For a source installation, replace `agent-beacon` with
`"$HOME/Library/Application Support/AgentBeacon/app/bin/beacon"`.
Use `backlight off` to disable it; a running controller applies the change without
a restart. `backlight status` shows the saved preference, and `status` includes
the active backlight output and any helper error.

Only the existing attention state flashes the backlight: pending approval/input,
terminal failures, or observer disconnection during active work. Working and idle
states leave normal keyboard illumination alone. Both lights use the controller's
same 0.4-second cycle. Alert brightness is the current brightness or 35%, whichever
is higher; the dark phase is zero. The display brightness is never changed.

The helper snapshots brightness, automatic brightness and idle dimming before
each alert. It temporarily pauses automatic brightness and idle dimming, then
restores all three settings when the alert ends, the feature is disabled, stdin
closes, or it receives SIGINT/SIGTERM/SIGHUP. A two-second input watchdog restores
the settings if the controller stalls. Changes made manually during an alert are
replaced by the saved settings when the alert ends. A force-killed helper or power
loss cannot perform cleanup; use the macOS keyboard brightness controls if needed.
If automatic brightness was enabled, macOS can adjust the restored brightness
again immediately according to the ambient light.

This optional helper uses Apple's private CoreBrightness API, which can change
between macOS releases. An unavailable or failing backlight helper is reported
without stopping the Caps Lock output. It supports a built-in backlit keyboard,
not external RGB keyboards, and is never started in simulation mode.

## Quick start: Homebrew (recommended)

Install [Homebrew](https://brew.sh/) and open Codex at least once first. Then run
this single command in Terminal as your normal user, without `sudo`:

```sh
brew install --force-bottle rynzh/tap/agent-beacon && agent-beacon setup
```

Requires Homebrew and macOS 15 or later. Apple Silicon and Intel bottles are
available; Homebrew manages Ruby automatically. The command requires a compatible
bottle and will not silently fall back to compiling Agent Beacon from source.

`agent-beacon setup` merges the Codex hooks with backups and starts the background
service. It does not change keyboard mappings or grant permissions for you.

Complete these two manual steps:

1. In **System Settings → Privacy & Security → Input Monitoring**, add and enable
   the LED helper at the exact path printed by setup. Press `Command-Shift-G` in
   the file picker to enter that path. Follow any restart instruction from macOS,
   then run `brew services restart agent-beacon`.
2. In Codex CLI, open `/hooks`, review the new Agent Beacon entries, and trust
   only commands pointing to your Homebrew `agent-beacon` launcher and ending in
   `hook codex`. Start a new Codex Desktop task afterward.

The install command cannot bypass either approval. If you installed the package
without setup, run `agent-beacon setup` separately.

### Verify the service and light

```sh
brew services list
agent-beacon status
```

Expect `agent-beacon` to be `started`, `controller_running` to be `true`, and
`output.simulated` to be `false`. With an active Codex Desktop task, the live
observer should also report connected.

For three physical light-on/light-off cycles, pause the service, run the demo,
then restart the service even if the demo reports an error:

```sh
brew services stop agent-beacon && agent-beacon demo
brew services start agent-beacon
```

Confirm the light visually. The demo does not press keys or change mappings.
After the service restarts, the light resumes the current task state; an active
task should be solid, not necessarily off.

If Homebrew reports `error 1`, inspect the service log:

```sh
tail -n 40 "$(brew --prefix)/var/log/agent-beacon.log"
```

An HID-access error means the helper could not access the LED; check Input
Monitoring and possible keyboard-tool conflicts, then restart the service.
Do not disable macOS security or remove keyboard mappings to make it start.

### Upgrade or uninstall

```sh
brew upgrade agent-beacon
agent-beacon setup
```

Run setup again after upgrading to restart the service. An updated helper may
require renewed Input Monitoring authorization. To uninstall:

```sh
agent-beacon uninstall
brew uninstall agent-beacon
```

### Migrate an existing source installation

Do not run two controllers against the same LED. Setup deliberately stops if it
finds the old `local.agent-beacon.controller` service, even if it is not running.
Back up the existing installation and hook configuration first.

For the standard source installer **with a `service-receipt.json` file**, remove
its integration using its original launcher, then configure Homebrew:

```sh
BEACON_DIR="$HOME/Library/Application Support/AgentBeacon/app"
"$BEACON_DIR/bin/beacon" uninstall-hooks codex
"$BEACON_DIR/bin/beacon" service remove
agent-beacon setup
```

These commands retain app files, logs and backups. Recheck Input Monitoring:
the Homebrew helper is a different executable from the source-installed helper.

If you used an early `persistence.rb` installation or depend on its Caps Lock /
Command / Option mappings, **do not run its uninstaller blindly**: it can restore
the old mappings. There is no automated mapping-preserving migration command.
Keep the mapping service and configuration intact and review
[the migration notes](docs/SAFETY.md) before switching controllers.
See [Homebrew details](docs/HOMEBREW.md) for package and release information.

## Source installation requirements

- macOS with a supported built-in Apple keyboard and Caps Lock LED
- Xcode Command Line Tools or Xcode
- System Ruby 2.6 or newer, SQLite, Git, and Make
- Codex installed and signed in

External and Magic Keyboards are not currently supported. Karabiner-Elements may
block LED access if it exclusively grabs the built-in keyboard. If Caps Lock still
controls capitalization or input sources, macOS may also update the same LED.

## Install from source (alternative)

### 1. Install Apple's command-line tools

Skip this step if they are already installed.

```sh
xcode-select --install
```

Complete the macOS installer before continuing.

### 2. Install Mac Agent Beacon

Run this command in Terminal. Do not use `sudo`.

```sh
curl -fsSL https://raw.githubusercontent.com/rynzh/Mac-Agent-Beacon/main/install.sh | /bin/bash -s -- --repo https://github.com/rynzh/Mac-Agent-Beacon.git
```

Prefer to inspect the source first?

```sh
git clone https://github.com/rynzh/Mac-Agent-Beacon.git
cd Mac-Agent-Beacon
bash install.sh
```

The installer checks dependencies, builds and tests the LED helper, installs the
app under `~/Library/Application Support/AgentBeacon/`, merges the Codex hooks
without removing existing ones, and starts a per-user background service.

### 3. Allow LED access

Open **System Settings → Privacy & Security → Input Monitoring**.

Add and enable:

```text
~/Library/Application Support/AgentBeacon/app/build/beacon-led
```

In the file picker, press `Command-Shift-G`, paste the path, and select the file.
If macOS asks you to restart an app, save your work and restart it.

### 4. Trust the Codex hooks

Open Codex CLI, run `/hooks`, and review the new Agent Beacon hooks. Trust entries
whose command ends with:

```text
AgentBeacon/app/bin/agent-beacon.rb hook codex
```

These manual approvals are intentionally not bypassed by the installer.

### 5. Start a new task

Open Codex Desktop and start a task. The LED should stay solid while Codex works,
blink when Codex is genuinely waiting for your action, and turn off when the task
finishes.

## Check a source installation

```sh
"$HOME/Library/Application Support/AgentBeacon/app/bin/beacon" status
```

A healthy active session normally reports a running controller, real rather than
simulated output, and a connected live observer.

To test the physical LED directly:

```sh
BEACON_DIR="$HOME/Library/Application Support/AgentBeacon/app"
"$BEACON_DIR/bin/beacon" stop
"$BEACON_DIR/bin/beacon" demo
"$BEACON_DIR/bin/beacon" service restart
```

Stop the controller before the demo so two processes do not compete for the LED.

## Uninstall a source installation

```sh
BEACON_DIR="$HOME/Library/Application Support/AgentBeacon/app"
"$BEACON_DIR/bin/beacon" uninstall-hooks codex
"$BEACON_DIR/bin/beacon" service remove
```

The commands remove the integrations and service but keep logs and backups. The
remaining `~/Library/Application Support/AgentBeacon/` folder can be moved to
Trash manually.

## How it works

- A Ruby controller combines task state from Codex hooks.
- Codex Desktop approval waits are detected through a read-only local IPC observer.
- Terminal failures are classified from Codex's local SQLite state.
- A small C helper uses macOS IOKit/IOHID to write the built-in Caps Lock LED.
- A LaunchAgent keeps the controller running after login.

The helper targets the LED output directly and does not inject a Caps Lock
keypress. On graceful exit, it restores the physical light to the current logical
Caps Lock state.

Codex Desktop IPC and database formats are internal interfaces and may change
after a Codex update. Runtime data stays on the Mac. Conversation snapshots may be
parsed in memory for state detection, but prompts, responses, and tool arguments
are not stored or uploaded by Mac Agent Beacon.

## Development

```sh
make test
```

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and the
[approval verification notes](docs/APPROVAL-VERIFICATION.md).

## License

[MIT](LICENSE). The LED helper includes adapted CapsPulse code; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
