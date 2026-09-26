<img src="assets/icon.png" width="128" alt="BlitzTree icon">

# BlitzTree

WizTree for macOS. A native disk treemap that scans a whole Mac (3.6M files) in about 14 seconds.

> i got mad there was nothing as fast and as nice as wiztree for my macbook so i made this pretty quickly in like 1 hour with only claude fable 5. its pretty good

![BlitzTree scanning /Applications](assets/screenshot.png)

## Download

**[⬇ BlitzTree.dmg](https://github.com/ahmedkhaleel2004/blitztree/releases/latest/download/BlitzTree.dmg)**: open it and drag BlitzTree into Applications. Apple Silicon, macOS 14 Sonoma or later (Liquid Glass on macOS 26+).

On first launch:

1. The app is not notarized, so macOS blocks it. Go to System Settings → Privacy & Security, scroll down, and click **Open Anyway**.
2. Grant Full Disk Access when the app asks, then click **Relaunch**.

## What you get

- Cushion-shaded treemap in the WinDirStat/WizTree style, colored by file type, with a title strip on each folder
- Finder-style outline list beside it, synced with the map
- Live progress while it scans, and an optional block for free space
- Double-click to zoom in; breadcrumbs to zoom out; right-click to reveal in Finder, copy the path, or move to Trash (with a confirmation)
- No network access and no telemetry

## Speed

| Home folder, 3.1M entries (M4) | time |
|---|---|
| **BlitzTree** | **10.2 s** |
| parallel `readdir` + `lstat` (what most scanners do) | 14.4 s |
| `du -skx` | 65.3 s |

Full numbers and method are in [BENCHMARKS.md](BENCHMARKS.md).

Why it is fast:

- `getattrlistbulk(2)` returns the metadata for a whole directory in one syscall, so there is no `stat` per file.
- A rayon pool keeps many directories in flight at once, which is where APFS scales.
- Scan threads run at user-interactive QoS. At a GUI app's default QoS they land on efficiency cores and the scan takes twice as long.
- `searchfs(2)` looks like the macOS answer to reading NTFS's MFT, but it was 5× slower: it is one sequential walk of the catalog and cannot be parallelized.

## Accuracy

- Sizes are what the disk actually allocates (the same number as `du`), not apparent length.
- A hard-linked file is counted once.
- Only one volume is measured: disk images, Recovery and other volumes mounted inside it are skipped.
- Folders that are only in iCloud (evicted to the cloud) are not opened, so a scan never starts a download.
- Root-only system areas such as the Spotlight index and unified logs cannot be read without elevation. The status bar shows the size of that gap instead of hiding it.

## Architecture

```mermaid
flowchart LR
    subgraph rust [Rust engine]
        W["getattrlistbulk workers"] --> T["arena tree,\nbottom-up sizes"]
        T --> F["flat arrays\n(CSR children, name blob)"]
    end
    F -- "C FFI, zero-copy" --> S["Swift Tree"]
    S --> L["squarified layout"] --> C["per-pixel cushion shader"] --> V["NSView bitmap\n+ title strips"]
    S --> O["NSOutlineView list"]
```

During a scan the UI reads atomic counters 30 times a second. When the scan ends, the tree crosses the FFI once as flat arrays, and Swift reads them in place with no serialization and no copies.

## Build

Needs Xcode 26 or later (for the Icon Composer icon and Liquid Glass APIs) and Rust.

```sh
./build.sh                  # → build/BlitzTree.app
./deploy.sh                 # build and install to /Applications
cargo test --release        # engine tests
```

`BlitzTree /some/path` scans that folder instead of the whole disk.

MIT
