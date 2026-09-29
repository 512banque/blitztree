#!/bin/zsh
# Offline agent setup checks. The harness uses disposable executable scripts;
# it never starts a real agent, opens a browser, reads credentials or installs anything.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d /tmp/blitztree-agent-setup.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
FLAGS=(-parse-as-library -swift-version 6 -default-isolation MainActor -target arm64-apple-macos14.0)
cargo build --locked --release --lib
SOURCES=(app/*.swift)
SOURCES=(${SOURCES:#app/Main.swift})
swiftc "${SOURCES[@]}" tests/AgentSetupChecks.swift "${FLAGS[@]}" \
    -import-objc-header app/bz.h -L target/release -lblitztree \
    -framework AppKit -framework SwiftUI -o "$TMP/agent-setup"
"$TMP/agent-setup"
