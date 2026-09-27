# UI and cleanup benchmark

Run `benchmarks/run-ui.sh` for correctness checks and timings, or pass
`--check-only` for the checks. Use
`benchmarks/run-ui.sh --scan-path /Applications /path/to/projects` to time cleanup
against real scan snapshots after `cargo build --release`. No agent starts and
no cleanup is performed in either mode. It compiles the current production Swift files
with the same `-O`, Swift 6, main actor isolation, and macOS 14 target as
`build.sh`. Synthetic mode uses a C adapter to provide read-only trees through the real
`Tree`/C bridge; real mode links the Rust library and scans each path once,
then both algorithms inspect that same snapshot. Scan time is excluded from
cleanup timings. The permission probe only checks the existing FDA-protected
directories.

`UIReferenceCleanup.swift` preserves the original traversal for differential
comparison. Checks cover exact and below-threshold sizes, marker-dependent
matches, nested caches, Trash, Unicode names, and a deterministic 25,001-node
random tree. A wide sorted-sibling case puts 100,000 small entries before
qualifying entries during fixture construction and checks that the sorted
threshold break still returns every qualifying match. Explicit expected matches are checked independently of the
reference. Actual `NSOutlineView` callbacks and selection verify that counting
or selecting a collapsed folder leaves its child wrappers unmaterialized.

The timed cleanup fixture contains 1,000 projects, each with a 64 MB
`node_modules` and a small source subtree of 512 long-named folders. It has
515,001 nodes and 1,000 identical cleanup matches before and after. Timings
alternate the old and new traversal for nine pairs and report the median.
This shape exercises subtree pruning; it is a synthetic case, not a claim
that all real scans get the same speedup.

The outline timing compares the old materialized-array child count with the
current production callback for a folder with 100,000 children. It reports the
callback's time and verified wrapper allocation count, not the total cost of
expanding or reloading a directory list. AppKit can still request wrappers when
it expands rows.

Measured on 2026-09-27, Swift 6.4, arm64, with no other team benchmarks running:

| Operation | Before median | After median |
|---|---:|---:|
| Cleanup discovery, 515,001 synthetic nodes | 58.401 ms | 1.086 ms |
| Cleanup discovery, 100,003 sorted siblings | 2.382 ms | 0.004 ms |
| Cleanup discovery, /Applications (332,019 nodes; 2 matches) | 10.579 ms | 0.060 ms |
| Cleanup discovery, user repos (264,259 nodes; 20 matches) | 1.677 ms | 0.096 ms |
| Child-count callback, 100,000 children | 5.146 ms | <0.001 ms |
| Wrappers allocated by child-count callback | 100,000 | 0 |

The FDA probe was denied in the benchmark executable: median 0.070 ms,
maximum 0.125 ms over 31 warm calls. No permission-cache change was made;
this does not measure the successful FDA-probe path. Raw samples are saved in
`build/perf-results/ui.txt` and `build/perf-results/ui-real.txt` by the audit run.
Real-tree runs had no unreadable directories; exact ordered cleanup item
signatures matched in every iteration. Real-tree cleanup times are small and
vary with scheduling/cache state, so the absolute milliseconds are more useful
than the very large ratios. The source SHA256s are recorded with the logs.

## Full-window handoff and observation

The second pass profiles and runs the actual SwiftUI/AppKit window. Build two
read-only harnesses, then alternate their processes:

```sh
uv run python benchmarks/ui-handoff.py --ref 178d256 --output build/ui-before
uv run python benchmarks/ui-handoff.py --ref 178d256 --ui-current --output build/ui-after
uv run python benchmarks/compare-ui.py --baseline build/ui-before \
  --candidate build/ui-after --path /Applications --output build/ui-comparison.json
```

`--ui-current` freezes the current Model, ContentView, Cleanup and Agent sources
with the reference renderers, isolating the UI changes. Both link the same Rust
library. Omit `--ref` to exercise all current sources. Agent discovery and
automatic scanning are removed only from temporary ContentView copies; the
harness starts each scan explicitly and never launches an agent or performs
cleanup. The installed app and its preferences are untouched.

The window has a 1,240 × 900-point content area. After scan completion, the
harness forces pending layout/display and records the time since the first
completed-engine poll. This is CPU-side window readiness, not GPU presentation
latency. It checks every available cell's tree identity, name, and size. Three
alternating process pairs, each containing four scans, gave:

| Operation | First pass (`178d256`) | Second pass UI |
|---|---:|---:|
| First result, median of three processes | 166.149 ms | 96.848 ms |
| Rescan, median of nine samples | 127.887 ms | 37.044 ms |
| Rescan range | 98.068–146.779 ms | 34.702–48.050 ms |
| Root body evaluations for 120 hover updates | 120 | 0 |

The scan targets contained 332,019 nodes throughout. The changes isolate
progress/status observation, read volume capacity concurrently with scanning,
construct empty canvases during the initial scan, and reuse unchanged collapsed
outline rows and cells. Reuse is bounded to 4,096 roots and rejected after child
materialization or changes to order, name, type, or child count. The synthetic
UI tests verify fresh node IDs, changed children, subsequent expansion, rename
and shape invalidation, and selection clearing. The canvas explicitly observes
selection so picks from the outline still redraw it after observation isolation.

Optional integration checks:

```sh
BZ_TIMING=1 BZ_UI_EXERCISE=1 build/ui-after /Applications 3
BZ_TIMING=1 BZ_VOLUME_DELAY=1.5 build/ui-after /path/to/empty-fixture 1
```

The first exercises zoom, selection, renderer switching, free-space toggles,
root navigation, and recycled cells. The second injects latency only into the
temporary metadata reader: the empty-tree scan remained responsive for 140
main-actor ticks during a 1.5-second wait, and progress kept updating. Earlier
`BZ hand-off` queue logs are diagnostic scheduling latency; they must not be
interpreted as uninterrupted main-thread blocking or complete frame timings.

A whole-module Swift optimization build did not demonstrate a useful layout
gain, so the production build flags remain unchanged.

The shared Clean Up implementation selects candidates in Rust before tree hand-off.
Synthetic fixtures seed the Swift adapter with the existing reference output;
use `run-ui.sh --scan-path PATH` to compare actual Rust selection with that
reference. Cleanup presentation timings exclude Rust selection and must not
be read as end-to-end selection speedups. Size ties are compared independently
of order in the real-scan parity check.
