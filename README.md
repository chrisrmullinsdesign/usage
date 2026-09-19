<div align="center">

<img src="docs/icon.png" width="128" alt="">

# Claude Usage

**Your Claude plan limits, live in the macOS menu bar.**

The same numbers as Claude Code's `/usage`, plus the tokens Claude Code has recorded on this Mac.

[![Build](https://github.com/chrisrmullinsdesign/usage/actions/workflows/build.yml/badge.svg)](https://github.com/chrisrmullinsdesign/usage/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Universal](https://img.shields.io/badge/Universal-Apple%20silicon%20%2B%20Intel-black)

<img src="docs/menubar.png" width="150" alt="Menu bar showing a gauge icon, 4% · 27%">

</div>

---

## Install

1. Download **ClaudeUsage-1.0.0.dmg** from the [latest release](https://github.com/chrisrmullinsdesign/usage/releases/latest).
2. Drag **Claude Usage** to Applications.
3. Open it. A window explains what it reads before it reads anything — click **Connect to Claude Code**.

The app is signed with a Developer ID and notarized by Apple, so it opens on a double-click:
no right-click-Open, no trip to System Settings. Verify that yourself if you like:

```sh
spctl -a -vvv -t install ~/Downloads/ClaudeUsage-1.0.0.dmg   # accepted · Notarized Developer ID
```

You need [Claude Code](https://claude.com/claude-code) installed and signed in — that's where the
usage data comes from.

<div align="center"><img src="docs/welcome.png" width="420" alt="First-run window listing what the app reads and why"></div>

## What it shows

<img src="docs/popover.png" width="330" align="right" alt="The popover: plan meters, token tiles, and a seven-day column chart">

**Plan limits** — from `GET https://api.anthropic.com/api/oauth/usage`

- Current session (5-hour window), weekly all-models, and weekly per-model
- Reset countdowns, and this week's usage split by surface
- Meters turn amber and red, with an icon and a label, as the API reports higher severity —
  status never rides on colour alone

**Claude Code on this Mac** — from `~/.claude/projects/**/*.jsonl`

- Today's output, input, cache-write and cache-read tokens, and message count
- Output tokens per day for the last seven days; hover a column for that day's detail
- Today's usage by model

The menu bar shows `session % · weekly %` by default; the button in the popover footer switches
it to session-only or icon-only.

It refreshes every 15 minutes, when you open the popover and the figures are over five minutes
old, or when you click ↻.

<br clear="right">

## How it works

The interesting part of this project is what it *doesn't* do.

**It never touches your token beyond reading it.** Claude Code stores its OAuth login in the
Keychain. This app reads that item through `/usr/bin/security`, keeps only
`claudeAiOauth.accessToken` in memory, and discards the rest — the same item also holds Claude
Code's MCP secrets. It never refreshes or rewrites the token, because rotating it would sign
Claude Code out. If the token expires, the popover keeps the last figures and tells you to open
Claude Code, which renews it.

**One host, no redirects.** One HTTPS request per refresh, to `api.anthropic.com`. The URL
session is ephemeral — no disk cache, no cookies, TLS 1.2 minimum — and redirects are *refused*,
so the bearer token can't be forwarded somewhere else by a 302. Transcript data never leaves the Mac.

**Permission is asked for, not sprung.** Nothing reads the Keychain until you click Connect in
the first-run window. Each way that read can fail — no Claude Code login, a denied dialog, a
locked Keychain, a malformed item — gets its own message and its own next step, rather than one
generic error.

**It stays out of the way.** Transcripts are read incrementally: the first scan covers seven days
in about three seconds, and later scans only parse the bytes appended since the last one,
de-duplicated by API message id. Lines over 32 MB (pasted images, file dumps) are skipped instead
of buffered. The 15-minute timer carries 60 seconds of tolerance so macOS can coalesce the wake-up,
and HTTP 429 backs off for 30 minutes. Idle cost is about 60 MB of memory and no CPU to speak of.

**Hardened runtime, no entitlements, no dependencies.** AppKit, SwiftUI and Foundation only.
It isn't sandboxed — the App Sandbox would block reading `~/.claude` — which is exactly why the
source is kept short enough to read in a sitting. See [SECURITY.md](SECURITY.md).

## Build from source

Needs the Xcode command line tools (`xcode-select --install`) and macOS 14+.

```sh
./build.sh            # build/ClaudeUsage.app, universal, ad-hoc signed
./build.sh --install  # also copy to ~/Applications and launch
```

There's no Xcode project and no package manager: `build.sh` runs `swiftc` once per architecture
and `lipo`s the result. With a Developer ID certificate installed it signs with that instead;
`Scripts/release.sh` takes it the rest of the way to a notarized, stapled DMG.

`Scripts/make-icon.sh` re-renders the app icon from `Scripts/make-icon.swift` — the icon is
drawn in CoreGraphics, not pasted in from a design tool.

## Uninstall

Untick **Open at login**, click **Quit**, then:

```sh
rm -rf /Applications/ClaudeUsage.app ~/Library/Logs/ClaudeUsage.log
defaults delete com.chrismullins.ClaudeUsage
```

## Source map

| File | |
|---|---|
| `Sources/App.swift` | The `MenuBarExtra` scene and app delegate |
| `Sources/Usage.swift` | Keychain read, usage API model, polling store, log |
| `Sources/Transcripts.swift` | Incremental transcript scanner |
| `Sources/Views.swift` | Menu bar label, popover, meters, seven-day columns |
| `Sources/Welcome.swift` | First-run window and permission recovery |

About 1,300 lines of Swift.

## Notes

This is an unofficial personal project. It is not affiliated with, endorsed by, or supported by
Anthropic, and it calls an endpoint that Anthropic doesn't document — that endpoint can change
or disappear without notice. The app is written to fail visibly when it does.

MIT licensed. © 2026 Chris Mullins.
