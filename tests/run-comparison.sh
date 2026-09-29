#!/bin/zsh
# Offline integration checks. Only disposable fixture folders are scanned.
set -euo pipefail
cd "$(dirname "$0")/.."
COMPARISON_TEST_TMP=$(mktemp -d /tmp/blitztree-comparison-checks.XXXXXX)
trap 'rm -rf "$COMPARISON_TEST_TMP"' EXIT
cargo build --locked --release --lib
SOURCES=(app/*.swift)
SOURCES=(${SOURCES:#app/Main.swift})
swiftc "${SOURCES[@]}" tests/ComparisonChecks.swift \
    -parse-as-library -swift-version 6 -default-isolation MainActor \
    -target arm64-apple-macos14.0 -import-objc-header app/bz.h \
    -L target/release -lblitztree -framework AppKit -framework SwiftUI \
    -o "$COMPARISON_TEST_TMP/comparison"
"$COMPARISON_TEST_TMP/comparison" "$@"
