# BlitzTree — WizTree-class disk treemap for macOS

## Goal
Ultra-fast, fully native macOS disk analyzer. Single main view: a WizTree-style
squarified cushion treemap. Ultra-minimal Apple-like UI. Table hidden by default.
Live scan progress. Speed is the headline feature.

## Measured on this machine (M4, 10 cores, macOS 26.6.2, APFS, warm cache)

Scan target: home dir = 1.06M files / 107k dirs / 220 GB; Data volume = 1.94M entries / 280 GB.

| strategy                            | home (~1.17M entries) | Data volume (~1.94M) |
|-------------------------------------|-----------------------|----------------------|
| parallel getattrlistbulk (ours)     | **5.0 s**             | **7.1 s**            |
| ...count-only (no tree) = floor     | 4.0 s                 | —                    |
| parallel readdir+lstat (naive-par)  | 7.5 s                 | —                    |
| searchfs(2) whole-catalog dump      | —                     | 38 s (!)             |
| du -sk                              | 22.6 s                | —                    |
| Disk Inventory X (reference class)  | minutes               | minutes              |

Key findings:
- searchfs(2) — the theoretical "MFT read" analog — is ~8x SLOWER than parallel
  getattrlistbulk on APFS: it is one sequential kernel catalog iteration and
  cannot be parallelized. (It does bypass dir permissions and saw 2.02M entries
  with 0 errors, and it works per-volume only. Not our engine; keep FFI for
  possible future use.)
- Thread sweet spot ≈ 10–16 (num cores). 32+ threads regresses ~40%.
- Tree building costs ~1 s over the syscall floor (mutex arena + allocs) —
  optimization headroom exists (thread-local read buffers, sharded arena,
  name interning) but 5 s is already ~50x Disk Inventory X.
- searchfs needed no permissions, but getattrlistbulk needs Full Disk Access
  to see everything (433 unreadable dirs without it).

## Architecture

- **Engine: Rust** (`blitztree` crate, this repo) — parallel getattrlistbulk
  walker, arena tree, bottom-up aggregation. Exposed as C staticlib (`bz_*`).
  - Live progress: atomic counters polled from UI at 30 Hz.
  - Post-scan: flat arrays (parent, sizes, flags, CSR children, name blob)
    handed to Swift zero-copy.
- **UI: Swift + SwiftUI/AppKit** (fully native, macOS 26 target)
  - Treemap = custom NSView. Layout: squarified treemap (Bruls et al.),
    computed in Swift over the flat arrays. Render: WizTree/WinDirStat-style
    cushion shading drawn into a bitmap on layout change only (not per frame);
    hover/selection as light overlay → instant-feel, no Metal complexity v1.
  - Color by file-type category, WizTree-like.
  - Interactions: hover tooltip (path, size, %), click select, double-click
    zoom into dir, breadcrumb back, right-click → Reveal in Finder / Move to
    Trash. Table view exists but hidden by default (toggle).
  - Live progress: counters + indeterminate sweep while scanning, treemap
    appears the instant the scan lands.
- **Packaging**: SwiftPM executable + script to assemble .app bundle,
  ad-hoc codesigned. User grants Full Disk Access once.

## Milestones
1. ✅ Rust engine benchmarked (5 s / 1.2M entries warm)
2. Rust C FFI (bz_scan, bz_progress, flat tree export)
3. Swift app skeleton: window, scan kickoff, live counters
4. Squarified layout + cushion treemap render
5. Interactions (hover/zoom/breadcrumb/trash) + type colors
6. Polish: FDA onboarding, app icon, optional table panel

## Open items / later
- Scanner micro-opts toward the 4 s floor (thread-local bufs, sharded arena)
- Hardlink / APFS clone accounting (WizTree ignores this too by default)
- Volume picker + free-space block in treemap
- Cold-cache benchmark (needs sudo purge)
