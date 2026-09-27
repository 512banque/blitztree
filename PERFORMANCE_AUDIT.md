# Performance audit — 2026-09-27

Baseline: `74b8fe4f097a819ece484a73e08f5368e64c3001` (v0.5.0 source).
Machine: Apple M4, 10 CPU cores, 16 GB RAM, macOS 27.0, Swift 6.4,
Rust 1.98. Release builds, warm filesystem caches, normal desktop activity.
Team benchmarks ran sequentially; background system activity was not stopped.
These are local measurements, not a claim about every disk or Mac.

Raw measurements are checked in under
[`benchmarks/results/2026-09-27`](benchmarks/results/2026-09-27).

## Changes

### Scanner and C handoff

- Reuse one 256 KiB directory-read buffer per worker. Previously every directory,
  including empty ones, allocated and released its own buffer.
- Move parsed filenames into tree nodes instead of cloning each name under the
  global arena mutex. Prepare descent paths before taking that mutex.
- Reserve each incoming arena batch once and avoid the mutex for empty directories.
- Build and sort child lists in their final flat buffer, comparing the compact
  allocation column. Preallocate name storage and release source names while
  converting the tree.
- Batch progress updates in the count-only diagnostic walker.

Isolated flattening of 262,401 synthetic nodes improved from **6.789 ms to
5.930 ms median** over ten alternating reference/current pairs. Source-tree
destruction is included; fixture construction is excluded. Scan peak memory
must be assessed separately from this CPU microbenchmark.

Final end-to-end FFI comparison, nine alternating pairs after warming both builds:

| Real scan | Before median (range) | After median (range) | Peak footprint, before → after |
|---|---:|---:|---:|
| `/Applications`, 332,018 entries | 0.620 s (0.611–0.718) | 0.597 s (0.587–0.739) | 61.60 → 58.98 MB |
| Repositories, 264,259 entries | 0.485 s (0.456–1.160) | 0.480 s (0.442–1.031) | 48.55 → 45.66 MB |

Counts, allocated bytes, and errors match in every measured run. The applications
median improved 3.7%; the repository wall-time difference is within substantial
background-load variation, so this is not evidence of a meaningful repository
scan speedup. Peak footprints are the median per-process peaks in decimal MB,
about 4–6% lower in these runs. Entry counts exclude the root.

The benchmark's optional thread argument previously configured Rayon's global
pool, while the real scanner built a separate pool and ignored that setting.
It now sets `RAYON_NUM_THREADS` before creating either pool. A new `ffi` mode
measures scanning, flattening, polling/handoff, and releasing the result.
`BZ_JSON=1` emits exact counts, allocated bytes, errors, and elapsed seconds.

A 4/6/8/10/12/16/32-worker sweep (three shuffled rounds per target) did not
establish a consistent better default across applications and repositories.
Ten workers led the applications median, but four were nearly tied; repository
samples varied heavily with background load. The core-count default is unchanged.

### Treemap and rings

The treemap skips a parent cushion only when its children demonstrably cover
every rounded pixel. Flat surfaces compute their shaded color once and fill
rows instead of evaluating the lighting formula per pixel. Layout geometry,
frame darkening, subpixel fallback, and color formulas stay identical.

Treemap pointer lookup uses a grid of leaf rectangles, retaining the original
last-matching-leaf rule at boundaries. Rings lookup uses angular binary search
within the pointer's ring. Rings also reuse arc paths and highlighted indices.
Invalid layouts clear geometry and invalidate the cached layout dimensions.

Review uncovered a fractional-edge coverage case and a stale ring-index crash
in intermediate versions of these optimizations. Both have dedicated regression
checks in the final rendering harness.

| Offscreen operation, 2,880 × 1,800 pixels | Before median | After median |
|---|---:|---:|
| Treemap redraw, balanced 13,280-node tree | 30.343 ms | 7.080 ms |
| Treemap redraw, 100,000 files | 46.264 ms | 34.727 ms |
| Treemap redraw, 120-level directory chain | 26.666 ms | 5.053 ms |
| Rings redraw, balanced tree | 57.495 ms | 57.325 ms |
| Rings hit testing, 50,000 queries | 584.782 ms | 14.390 ms |
| Treemap hit testing, 1,000 queries, 100,000 files | 2,769.655 ms | 0.307 ms |

These are nine alternating pairs. Treemap redraw includes building its hover
index, so the flatter workload trades some of the paint savings for much cheaper
pointer movement: about **2.77 ms → 0.00031 ms per query** in that fixture.
The index stores leaf references by 32-point cell and uses additional memory;
this audit does not claim a reduction in total app memory.

### Cleanup and outline

Cleanup discovery stops below the 50 MB threshold: a smaller subtree cannot
contain a qualifying folder, and siblings are already sorted by size. It also
avoids decoding parent names for unrelated directory names. Outline child-count
queries read the flat child offsets without creating wrapper objects; selecting
a collapsed folder leaves its descendants unmaterialized. A tree identity check
prevents an older cleanup task from publishing results after a rescan.

| Operation | Before median | After median |
|---|---:|---:|
| Cleanup, real `/Applications`, 332,019 nodes | 10.579 ms | 0.060 ms |
| Cleanup, real repositories, 264,259 nodes | 1.677 ms | 0.096 ms |
| Cleanup, synthetic 515,001-node tree | 58.401 ms | 1.086 ms |
| Cleanup, 100,003 sorted siblings | 2.382 ms | 0.004 ms |
| Outline child-count callback, 100,000 children | 5.146 ms | <0.001 ms |

Both cleanup implementations inspect the same immutable tree in each real
comparison, and their complete ordered outputs match. Timings use nine pairs.
The outline callback creates **100,000 → 0** child wrappers. This does not measure
the total cost of expanding or reloading 100,000 visible rows. Submillisecond
ratios are less useful than the absolute time saved.

## Verification and reproduction

```sh
cargo test --release
cargo test --release --lib flatten_benchmark -- --ignored --nocapture
benchmarks/run-ui.sh
benchmarks/run-ui.sh --scan-path /Applications /path/to/projects
uv run python benchmarks/rendering.py --baseline 74b8fe4
./build.sh
```

`benchmarks/run-ui.sh --check-only` and the rendering runner's `--check-only`
option omit timing loops. Swift harnesses use production `-O`, Swift 6, default
main-actor isolation, and the macOS 14 deployment target, without whole-module
optimization. The rendering harness compiles the actual old/new renderer files
with a deterministic synthetic tree adapter; it measures redraw operations,
not total app launch or scan time. The UI harness uses the production `Tree`
and either an in-memory C fixture adapter or the actual Rust scanner.

To compare scanner versions, put the baseline source in an ignored directory,
copy the current `src/bin/bench.rs` into it so both libraries use the same
harness, and build both with `cargo build --release`. Then run:

```sh
uv run benchmarks/scan.py \
  --baseline build/perf-baseline-source/target/release/bench \
  --candidate target/release/bench --path /Applications \
  --output build/perf-results/apps-ffi.json
```

The scanner runner warms both builds, alternates AB/BA order, records every
sample and executable SHA256, and fails if file/directory/byte/error totals
differ. `/usr/bin/time -l` records process peak memory. Do not compare timing
ratios across a changing input tree without investigating the mismatch.

Engine checks cover hardlinks, directory symlinks, parent ordering, empty
directories, cloud/mount metadata, and exact equality of every flat ABI column
against the original conversion. Cleanup checks cover all matching rules,
threshold boundaries, nesting, Trash, Unicode, randomized and wide trees, and
real NSOutlineView count/selection behavior. Benchmarking performs no cleanup
and launches no coding agent.

Rendering verification passed 28 paired bitmap/geometry cases, 126
scale/root/paint-band cases, 2,000 independent rounded-pixel coverage cases,
260,708 ring hit comparisons, and 11,344 treemap hit comparisons. It includes
fractional sizes, zero-byte and empty trees, free space, very uneven weights,
deep chains, and invalidation followed by returning to the original size.

The complete app built successfully and passed `codesign --verify --deep
--strict`. Native UI smoke testing covered a real `/Applications` scan, folder
zoom, switching treemap/rings, free-space toggling, and rescan. Both scans
displayed 278,661 files and 32.53 GB; `du -skx /Applications` independently agreed
at exactly **32,533,331,968 allocated bytes**. The tested app needed no new Full
Disk Access grant for that path, and its AI startup was disabled for QA.
The build retains the same three Swift concurrency warnings seen in the baseline
(one scoped render buffer capture and two agent-locator captures).

## Remaining opportunities

1. **Filesystem traversal remains the scan limit.** A baseline Instruments
   sample attributed 53.8% of running CPU samples to `getattrlistbulk` and 37.4%
   to `open`. An `openat`-based experiment could reduce repeated path resolution,
   but needs bounded descriptor ownership, deep-tree tests, and measurements
   before replacing the current walker. This is a hypothesis, not a measured win.
2. **Rings painting remains relatively expensive.** Reusing paths avoids
   repeated construction but did not materially improve the initial raster
   timings. The big demonstrated rings benefit is pointer lookup. Further work
   should profile clipping, gradients, and antialiasing rather than assume more
   caching will help.
   The native smoke log also showed 159–218 ms from tree completion until the
   main queue became free, despite about 28 ms of treemap layout/paint. That is
   a useful next profiling target in the full UI handoff; this audit does not
   claim that all main-thread stalls are eliminated.
3. **Agent preparation has bounded opportunities.** Prompt generation walks
   the tree and sorts candidate lists before taking 250 folders/80 files.
   Streaming JSON parsing rereads its accumulated buffer per chunk. These run
   once per plan or on small plans; no measured benefit justified changing the
   agent integration in this audit.
4. **FDA caching was not justified by the measured denied-probe path**
   (about 0.07 ms). The successful Full Disk Access path was not benchmarked.

Unchanged engine limitations found during review: invalid UTF-8 entry names and
per-entry metadata errors are skipped; freeing a scan handle does not cancel
its worker scan. These are separate correctness/lifecycle work, not performance
improvements claimed by this change.
