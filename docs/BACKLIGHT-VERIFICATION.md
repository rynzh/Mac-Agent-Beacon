# Backlight verification

The optional output shares the controller's attention and completion phases.
It never infers requests from conversation text or changes approval behavior.

## Automated checks

`make test` builds both production helpers, runs the native backlight session
tests with a fake brightness client, and runs the Ruby suite. The native tests do
not load CoreBrightness or change hardware. The Ruby simulation mode also never
starts the real backlight helper.

Coverage includes:

- Disabled by default; working/idle states do not acquire backlight control.
- Identical on/off phase values; duplicate phases do not produce extra writes.
- Slow completion cadence, expiry to idle, and attention/working/completion priority.
- Attention-to-completion transitions preserve the original brightness snapshot.
- Disabling during an alert, resolution, and controller shutdown close the helper.
- A new alert snapshots the current settings again.
- Unavailable or hanging helpers fail independently, with bounded cleanup and
  no repeated launch attempts on every blink phase.
- Restoration of brightness and all combinations of automatic brightness/idle
  dimming, including partial takeover failures and invalid brightness readings.

## Hardware check

Before a release, repeat this checklist on a supported MacBook:

- Record brightness, automatic-brightness and idle-dimming state with
  `agent-beacon backlight inspect`.
- Confirm an attention event blinks the Caps Lock LED and keyboard backlight in
  phase, then restores normal illumination when the event resolves.
- Confirm a completion event keeps the Caps Lock LED off while the optional
  keyboard backlight slow-blinks for six seconds.
- Confirm EOF, SIGTERM and the two-second watchdog restore the recorded settings.
- Re-run the check with automatic brightness both enabled and disabled. macOS may
  recalculate brightness immediately when automatic brightness is restored.

Record the macOS version and Mac model with release evidence. CoreBrightness is a
private interface and needs testing across macOS releases. Power loss, SIGKILL,
Intel hardware and external keyboards remain unsupported validation scenarios.

To reproduce a short visual check after enabling backlight alerts, inject an
explicit test event and always remove that same test session afterward:

```sh
agent-beacon event backlight-test visual-check attention
sleep 5
agent-beacon event backlight-test visual-check idle
```

Keep a second terminal available for the final command. Confirm that both lights
blink together and normal keyboard illumination returns when the test ends.
Other real tasks may still keep the Caps Lock LED lit or blinking.
