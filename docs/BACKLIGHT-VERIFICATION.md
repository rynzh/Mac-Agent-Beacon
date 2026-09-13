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

Verified on macOS 27.0 (26A428), MacBookPro18,3, with the built-in Apple keyboard.
Karabiner remained running for other devices; its ownership of the built-in
keyboard had already been released with the user's two mappings retained through
native macOS mapping. This PR does not configure or alter those mappings.

- The actual brightness readback followed both on/off phases.
- Twenty stable samples of the installed controller's Caps Lock phase and
  CoreBrightness readback matched. Both outputs were real, not simulated.
- The user visually confirmed synchronized whole-keyboard/Caps Lock blinking
  during a ten-second test and normal backlight restoration afterward.
- Completion: 46 stable hardware samples matched both lights. Observed phase
  intervals were 0.94–1.10 seconds; after six seconds the controller expired to
  idle, turned the LED off, and restored the backlight sensor/dimming settings.
- EOF, SIGTERM and the two-second watchdog each restored the original brightness,
  automatic brightness flag and idle-dimming flag in a fixed-brightness check.
- With automatic brightness initially enabled, the flag was restored. macOS can
  immediately recalculate brightness from ambient light, so an exact persistent
  brightness match is only asserted with automatic brightness initially disabled.

No reboot, power-loss, force-killed helper, Intel hardware, or external keyboard
test is claimed. SIGKILL and power loss cannot run restoration code. CoreBrightness
is a private interface and still needs testing on additional macOS versions.

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
