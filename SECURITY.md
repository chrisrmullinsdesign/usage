# Security

Claude Usage reads a Claude Code OAuth token and sends it to Anthropic. That makes its
security posture worth stating plainly, and worth checking yourself — the whole app is
about 1,300 lines of Swift in `Sources/`.

## What it touches

| | |
|---|---|
| **Reads** | The Keychain item `Claude Code-credentials`; `~/.claude/projects/**/*.jsonl` |
| **Writes** | `~/Library/Logs/ClaudeUsage.log`; its own `UserDefaults` |
| **Network** | `GET https://api.anthropic.com/api/oauth/usage`, once per refresh |
| **Never** | Refreshes, rotates or writes the token. Uploads transcripts. Opens a port. |

## How the token is handled

- Read through `/usr/bin/security`, in memory only, and never written to disk.
  The Keychain item also holds Claude Code's MCP OAuth secrets; `security` can't return a
  single field, so the app parses the whole item and keeps only `claudeAiOauth.accessToken`.
- Never logged. `Sources/Usage.swift` logs percentages and HTTP status codes, nothing else.
  Read `~/Library/Logs/ClaudeUsage.log` yourself to confirm.
- The app never *refreshes* the token. Rotating it would sign Claude Code out, so an expired
  token is reported to you rather than renewed.
- **Redirects are refused** (`RefuseRedirects` in `Sources/Usage.swift`). Without this, a
  redirect would carry the `Authorization` header to whatever host it named.
- The URL session is ephemeral: no disk cache, no cookies, TLS 1.2 minimum.

## Hardening

- **Hardened runtime**, no entitlements. Release builds are Developer ID signed; a
  notarized DMG is not published yet, so today the app is built from source.
- Not sandboxed: the App Sandbox would block reading `~/.claude` and running the Keychain
  tool. This is a deliberate trade-off, and the reason the source is short and readable.
- Transcript lines over 32 MB (pasted images, file dumps) are skipped rather than buffered.
- The Keychain read is given 15 seconds during background polls, so a locked Keychain can't
  stall the app. Only the welcome window's explicit **Connect** waits on a permission dialog.

## Verifying what you built

```sh
codesign --verify --deep --strict --verbose=2 build/ClaudeUsage.app
codesign -dvv build/ClaudeUsage.app 2>&1 | grep -E 'TeamIdentifier|flags'
```

Expect `flags=0x10000(runtime)`. A build made on a machine with the project's Developer ID
certificate reports `TeamIdentifier=S52LNBX9HH`; your own build will be ad-hoc signed, with no
team identifier, which is expected and fine.

If a signed DMG is published later, verify it before opening:

```sh
spctl -a -vvv -t install ~/Downloads/ClaudeUsage-<version>.dmg   # accepted, Notarized Developer ID
```

## Reporting a vulnerability

Please **don't** open a public issue. Use GitHub's
[private vulnerability reporting](https://github.com/chrisrmullinsdesign/usage/security/advisories/new)
and allow a few days for a first response.

## Scope note

This app calls an undocumented Anthropic endpoint with Claude Code's own token. It is
unofficial and not affiliated with or endorsed by Anthropic. The endpoint can change or
disappear without notice; the app is written to fail visibly rather than silently when it does.
