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
