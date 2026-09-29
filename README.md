<img src="assets/icon.png" width="128" alt="BlitzTree icon">

# BlitzTree

A fast, native disk-space treemap for macOS, in the spirit of WizTree. It scans a whole Mac (3.6M files) in about 14 seconds.

This is [Kevin Richard's fork](https://github.com/512banque/blitztree) of
[Ahmed Khaleel's BlitzTree](https://github.com/ahmedkhaleel2004/blitztree).
It includes upstream v0.5.6 and these contributions:

- [#3: cleanup validation](https://github.com/ahmedkhaleel2004/blitztree/pull/3) — shared path guards, exact command arguments, and validated Trash receipts.
- [#4: path comparison performance](https://github.com/ahmedkhaleel2004/blitztree/pull/4) — fewer temporary allocations in ranking and hard-link accounting.
- [#5: earlier scan results](https://github.com/ahmedkhaleel2004/blitztree/pull/5) — show the completed tree before volume capacity arrives, then refresh the maps.

The read-only JSON CLI from [#2](https://github.com/ahmedkhaleel2004/blitztree/pull/2)
is already part of upstream and is included here too. The original attribution
and MIT license are retained.

<p>
  <img src="assets/screenshot.png" width="49%" alt="BlitzTree treemap view of /Applications">
  <img src="assets/screenshot-rings.png" width="49%" alt="BlitzTree rings view of /Applications">
</p>

## Install

Build this fork using the [source instructions below](#build-from-source).
Requires Apple Silicon and macOS 14 or later. Local builds use an ad-hoc
signature and are not notarized; grant Full Disk Access when prompted, then relaunch.

Automatic updates are disabled so an upstream binary cannot replace this fork's
changes. This fork does not publish binary releases. For the maintainer's signed
and notarized version, see [upstream releases](https://github.com/ahmedkhaleel2004/blitztree/releases).

## Features

- Cushion-shaded treemap colored by file type, with a synced Finder-style outline list
- Prefer DaisyDisk? Switch to rings in the toolbar: click a folder to zoom in, the middle to go back
- Zoom into folders, reveal in Finder, or move to Trash (with confirmation)
- Clean Up panel: finds folders that are safe to delete (caches, `node_modules`, Rust `target`, Xcode DerivedData and more) so you can trash them in one go
- AI cleanup: click "Clean up with Claude Code" (or Codex) and your own agent plans what can go, live in the panel, while the treemap lights up those folders. BlitzTree does the cleanup itself, in two steps you approve: move to Trash, then delete for good. No agent installed? One click sets up Codex (free with a ChatGPT account) or Claude Code
- Live progress while scanning, and an optional free-space block
- Native AppKit/SwiftUI, with the Liquid Glass design on macOS 26 and later
- No telemetry or automatic update checks in this fork. The AI cleanup only runs when you click it, using your own agent, which sends folder paths and sizes from the scan (never file contents) to Anthropic or OpenAI

## Performance

| Home folder, 3.1M entries (M4) | Time |
|---|---|
| **BlitzTree** | **10.2 s** |
| Parallel `readdir` + `lstat` | 14.4 s |
| `du -skx` | 65.3 s |

- `getattrlistbulk(2)` reads a whole directory's metadata in one syscall instead of one `stat` per file.
- A Rust worker pool keeps many directories in flight, and scan threads run at user-initiated QoS: they stay on performance cores without starving the UI.
- The treemap is laid out once and painted on every core in parallel, so zooming redraws in a couple of frames.

Method, full results and a comparison with other tools: [BENCHMARKS.md](BENCHMARKS.md).

## Accuracy

Sizes are allocated bytes, matching `du`. Hard-linked files count once, the scan stays on one volume, and cloud-only iCloud folders are never downloaded. Root-only system data that no app can read is reported in the status bar instead of hidden.

## AI cleanup

The agent runs headless and read-only: it only writes a plan from the scan BlitzTree already has. BlitzTree then acts on it behind its own checks, whatever the plan says:

- Agent Trash actions require scanned paths inside your home folder. Photos, iCloud Drive, Mail, keychains and `~/.ssh` remain protected. Documents and Desktop allow rebuildable project folders, plus dated Codex chat folders under `~/Documents/Codex`. Git metadata and whole shared folders such as `~/Library/Caches` remain protected.
- Only each tool's own cache cleanup commands (`uv cache clean`, `brew cleanup`, `npm cache clean` and similar, plus `xcrun simctl` for Xcode simulator runtimes and device data), with no shell syntax
- Codex chats and projects you used in the last 2 days are left alone
- Caches of apps that are open are skipped until you quit them
- "Delete for good" removes only what this cleanup moved to the Trash

## Build from source

Requires Xcode 26 or later and Rust.

```sh
./build.sh              # build/BlitzTree.app
./deploy.sh             # build and install to /Applications
cargo test --release    # engine tests
```

The Rust engine hands the finished tree to the Swift UI as flat arrays over a C interface, with no copying. `BlitzTree <path>` scans a specific folder.

Source builds do not use Apple Developer credentials. `release.sh` is disabled
until a release process for this fork is configured.

## Track upstream

For a fresh clone, keep this fork as `origin` and the original project as `upstream`:

```sh
git clone https://github.com/512banque/blitztree.git
cd blitztree
git remote add upstream https://github.com/ahmedkhaleel2004/blitztree.git
git fetch upstream
```

Future upstream changes can be merged into this fork while retaining the patches.

## JSON CLI for agents and scripts

An optional, read-only CLI uses the same scan engine without opening the GUI
or launching an AI agent:

```sh
cargo build --locked --release --features cli --bin blitztree
./target/release/blitztree scan --root "$HOME/Downloads"
./target/release/blitztree quick-wins --root "$HOME" --limit 20
```

`scan` lists the largest directories and files as JSON. `quick-wins` includes
that inventory plus the Clean Up panel's existing candidates and labels. The
panel and CLI share one Rust implementation of the rules, with no new heuristics.
Both report incomplete scans; allocated bytes are not
a promise of reclaimable space. Neither command modifies the scanned files.

The CLI is built from source separately from the app. Its JSON dependency is
only compiled with the `cli` feature. See [the CLI contract and tests](docs/AGENT_API.md).

## License

MIT
