# Safety and rollback

## Before installing persistent mapping

1. Run the LED demo and visually confirm it works.
2. Confirm Caps Lock is intended to become left Command.
3. Back up any custom Karabiner configuration.
4. Keep an external keyboard available while testing.

The installer only targets the Apple built-in keyboard. It refuses to continue when the selected Karabiner profile already has device-specific settings or when the system has an unfamiliar non-empty mapping.

## Roll back

Run:

```sh
ruby bin/persistence.rb uninstall
```

This removes Agent Beacon's LaunchAgents, clears its known HID mapping, and restores the saved Karabiner configuration when the target profile remains unchanged. It deliberately leaves agent hooks installed; remove them separately with `uninstall-hooks` commands from the README.

If the installer reports that the profile changed, stop and restore manually from the runtime backup rather than forcing another mapping change.
