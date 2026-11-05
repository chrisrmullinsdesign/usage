# Contributing

Bug reports and small, focused pull requests are welcome.

## Building

```sh
git clone https://github.com/chrisrmullinsdesign/usage.git
cd usage
./build.sh --install
```

No Xcode project and no package manager: `build.sh` calls `swiftc` twice (arm64 and x86_64),
`lipo`s the slices together and assembles the bundle. You need the Xcode command line tools
(`xcode-select --install`) and macOS 14 or later.

Without a Developer ID certificate the build signs ad-hoc, which is fine for local use.

## House style

- Comments explain *why*, not *what*. If a line needs a comment to say what it does, rewrite the line.
- No new dependencies. The app is AppKit, SwiftUI and Foundation, and should stay that way.
- Keep the security properties in `SECURITY.md` true. Anything touching the token, the network
  session or the Keychain read needs a matching update there, in the same PR.

## Before opening a PR

```sh
./Scripts/test.sh   # unit tests for the pure logic; add a case when you change it
./build.sh          # must build clean for both architectures
codesign --verify --strict --deep build/ClaudeUsage.app
```

Then run it and open the popover — there are no automated UI tests, so say in the PR what
you exercised by hand.

CI also builds with `-warnings-as-errors`, so a warning fails the PR. Run
`SWIFTC_EXTRA_FLAGS=-warnings-as-errors ./build.sh` to see what CI will see.

## Changing the icon

`Scripts/make-icon.sh` re-renders `Resources/AppIcon.png` and `.icns` from
`Scripts/make-icon.swift`. Commit both outputs so building the app never needs the script.
