# Security

Claude Usage reads a Claude Code OAuth token and sends it to Anthropic. That makes its
security posture worth stating plainly, and worth checking yourself — the whole app is
about 1,300 lines of Swift in `Sources/`.

## What it touches

| | |
|---|---|
| **Reads** | The Keychain item `Claude Code-credentials`; its own Keychain item `ClaudeUsage manual token`; `~/.claude/projects/**/*.jsonl` |
| **Writes** | `~/Library/Logs/ClaudeUsage.log` (owner-only); its own `UserDefaults`; its own Keychain item, and only when you paste a token in |
| **Network** | `GET https://api.anthropic.com/api/oauth/usage`, once per refresh |
| **Never** | Refreshes, rotates or writes the token. Uploads transcripts. Opens a port. |

## How the token is handled

- Read through `/usr/bin/security`, in memory only, and never written to disk.
  The Keychain item also holds Claude Code's MCP OAuth secrets; `security` can't return a
  single field, so the app parses the whole item and keeps only `claudeAiOauth.accessToken`.
- Never logged. `Sources/Usage.swift` logs percentages and HTTP status codes, nothing else.
  A pasted token is logged only by *length*, to tell a truncated paste from a rejected one.
  Read `~/Library/Logs/ClaudeUsage.log` yourself to confirm.
- The app never *refreshes* the token. Rotating it would sign Claude Code out, so an expired
  token is reported to you rather than renewed.
- **Redirects are refused** (`RefuseRedirects` in `Sources/Usage.swift`). Without this, a
  redirect would carry the `Authorization` header to whatever host it named.
- The URL session is ephemeral: no disk cache, no cookies, TLS 1.2 minimum.
- A token is checked before it goes anywhere near a request header: printable ASCII, no
  whitespace, at most 4 KB. A malformed paste or a tampered Keychain item is refused, not sent.
- `~/Library/Logs/ClaudeUsage.log` is created owner-only (`0600`), and an older world-readable
  log is tightened at launch.

## Pasted tokens

If the Keychain route doesn't work on your Mac, the welcome window lets you paste an OAuth
access token instead. That token:

- Goes into **this app's own** Keychain item (`ClaudeUsage manual token`), created and owned
  by this app. Claude Code's item is never written to, by this or any other code path.
- Is stored through the Security framework, not the `security` CLI. Shelling out would mean
  `security add-generic-password -w <token>`, putting the token in the process arguments
  where any other process could read it out of `ps`.
- Is marked `kSecAttrAccessibleWhenUnlocked` and non-synchronizable, so it stays on this Mac
  and is unreadable while the Mac is locked.
- Is discarded if Claude rejects it (401/403). It is *kept* if the check fails for an
  unrelated reason — no network, or a rate limit — because throwing away a token over a
  transient error loses something that was probably fine. The window says which happened.
- Can be removed at any time with **Forget token** in the welcome window, which deletes the
  item and falls back to the Claude Code login.

These tokens are short-lived (roughly an hour), so this is an escape hatch, not a way to run
the app without Claude Code.

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
