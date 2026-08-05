# Security policy

## Supported versions

Security fixes are applied to the latest release and the `main` branch.

## Reporting a vulnerability

Please use [GitHub private vulnerability reporting](https://github.com/emaitchess/searoom/security/advisories/new).
Do not open a public issue for a vulnerability that could expose users before a
fix is available.

Searoom does not use a network connection, privileged helper, kernel extension,
or background daemon. Its optional hardware collectors open read-only IOKit
services and return unavailable when access is denied.

The configurable global shortcut uses the system hot-key API rather than an
event tap, so Searoom does not request Accessibility or Input Monitoring
permission. Preferences remain in `UserDefaults`; bounded trend samples remain
in the user's Application Support directory and can be cleared from Settings.
