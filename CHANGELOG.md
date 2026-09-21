# Changelog

All notable changes to this project are documented here.
This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-09-19

First public release.

### Added
- Menu bar gauge showing session and weekly plan usage, with a popover breakdown.
- Local token accounting from Claude Code transcripts: today's totals, a seven-day
  column chart, and a per-model split.
- Welcome window on first run that explains every permission before requesting it,
  with specific recovery steps for each way the Keychain read can fail.
- Paste-a-token fallback for Macs where the Keychain read isn't available, stored in the
  app's own Keychain item via the Security framework. Discarded if Claude rejects it,
  kept if the check fails for an unrelated reason, and removable with Forget token.
- `--show-welcome` reopens the first-run window without hunting for the ? button.
- Universal binary (Apple silicon and Intel), hardened runtime, Developer ID signed
  when a certificate is available and ad-hoc signed otherwise.
- `Scripts/make-icon.swift`: the app icon, rendered from source.
- `Scripts/release.sh`: build, sign, notarize, staple and verify a distributable DMG.
  No notarized release is published yet; install by building from source.

[1.0.0]: https://github.com/chrisrmullinsdesign/usage
