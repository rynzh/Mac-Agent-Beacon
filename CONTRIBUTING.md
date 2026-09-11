# Contributing

## Development setup

Run `make test` on macOS. The test suite builds the native HID helper and runs controller tests with Ruby's standard library.

Use `AGENT_BEACON_SIMULATE=1` for controller-only work. Do not treat simulated output as hardware verification.

## Pull requests

- Keep keyboard behavior unchanged unless the change is explicitly about the opt-in mapping installer.
- Never add synthetic Caps Lock key events or modifier-state writes as an LED fallback.
- Add a focused test for state transitions and run `make test`.
- Describe the manual hardware check, macOS version, keyboard model and Karabiner state.

## Reporting bugs

Do not include agent transcripts, prompts, API keys, access tokens, or full local logs. Use the security process for vulnerabilities.
