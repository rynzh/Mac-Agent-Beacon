# Security policy

Please do not publish vulnerabilities that could expose local agent data, bypass macOS permissions, or unexpectedly alter keyboard input.

Until a dedicated private reporting address is set up, open a minimal GitHub issue without secrets or reproduction data that contains private prompts. Maintainers can arrange a private follow-up channel.

## Safety model

- The LED helper writes an HID LED output element only.
- It checks that logical Caps Lock did not change during a write and stops if it did.
- Input Monitoring permission is granted by macOS, not by this project.
- The optional mapping installer makes recoverable backups and refuses unexpected existing mappings.

These protections do not replace independent review before using the optional remapping installer.
