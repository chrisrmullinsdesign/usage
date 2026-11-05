#!/bin/zsh
# Runs the unit tests: compiles every source except App.swift (it holds @main) together with
# Tests/main.swift, then runs the result. No Xcode project or package manager needed.
set -euo pipefail
cd "${0:A:h}/.."

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

sources=(${(f)"$(ls Sources/*.swift | grep -v '/App.swift$')"})
swiftc -swift-version 5 ${=SWIFTC_EXTRA_FLAGS:-} "${sources[@]}" Tests/main.swift -o "$OUT/tests"
"$OUT/tests"
