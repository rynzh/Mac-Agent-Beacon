# Changelog

All notable changes to this project are documented here.

## Unreleased

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
