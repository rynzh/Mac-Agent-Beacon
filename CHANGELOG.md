# Changelog

All notable changes to this project are documented here.

## Unreleased

- Decouple the built-in Caps Lock LED from logical Caps Lock on macOS 26 and
  later with the HID service override. Agent Beacon owns only the light and
  restores normal system-managed behavior when it exits.
- Remove the legacy device-grab and keyboard-remapping utilities from the
  distributed project.
- Reconcile persisted Codex working sessions with the latest turn status when
  the controller starts, preventing completed tasks from leaving the LED on.
- Add opt-in whole-keyboard backlight alerts, synchronized with the Caps Lock
  attention and completion phases, with brightness/auto-dimming restoration and optional-output
  failure isolation. Enable with `agent-beacon backlight on`.
- Indicate recent completion with an opt-in keyboard-backlight slow blink for 6
  seconds while keeping the Caps Lock LED off. Attention and ongoing work take priority.

## 0.1.0

- One-command local and published-repository installer.
- Native Apple built-in keyboard Caps Lock LED helper.
- Local controller with working, attention and idle light states.
- Codex and Claude Code hook installers plus generic CLI events.
- Optional built-in keyboard remapping with reversible persistence.
- Read-only Codex status observation for terminal failure and usage-limit states.
