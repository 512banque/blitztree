# Rendering regression and performance harness

Run on an Apple Silicon Mac with the Swift toolchain:

```sh
uv run --no-project python benchmarks/rendering.py --baseline 74b8fe4f097a819ece484a73e08f5368e64c3001 --allow-ring-rounding
```

To isolate the second rendering pass, compare with `--baseline 178d256` instead.
Treemap pixels and all geometry/hit tests still require
exact equality. Retina ring strokes permit only a maximum channel difference
of 5/255 affecting fewer than 0.1% of stored channel bytes per fixture. This
explicit option records the changed-byte histogram and maximum error; without
it any changed pixel fails. Ring gradients retain their original serial raster
path. Non-Retina scenes and scenes with fewer than 24 arcs retain the original
serial stroke too.

Add `--check-only` to omit timings. `--build-only --output /tmp/blitztree-rendering-bench`
builds an executable that can be timed later while other benchmarks are idle.
Use `--rings-only --check-only --scale 1` for the 42-case non-Retina matrix;
repeat with `--scale 2 --allow-ring-rounding` for Retina. `--rings-only` without
`--check-only` also times full-circle ring scenes in nine alternating pairs.
Set `BZ_RENDER_IMAGES` to a directory to export matching baseline/candidate PNGs
for the large balanced fixture. `--profile rings` or `--profile treemap` adds
phase instrumentation to temporary sources for diagnosis only.

The harness compiles the actual baseline and working-tree renderer files as
separate Swift files, widening private visibility only in temporary copies. It
uses the app's `-O`, Swift 6, main actor isolation, and macOS 14 deployment target
without whole-module optimization. A deterministic immutable synthetic Tree
adapter replaces the Rust FFI tree; these are offscreen rendering comparisons,
not end-to-end scan or application responsiveness measurements.

Correctness checks compare bitmap bytes, leaf/directory rectangles, labels,
and ring segments for seven fixtures, two view sizes, and free space on/off.
Additional checks cover scale 1/2, alternate band boundaries, directory/file
roots, 2,000 fractional-boundary raster coverage cases, hover points and arc/leaf
boundaries, and valid-to-tiny-to-valid view invalidation. The coverage cases
include an exact half-pixel rounding regression and distributions ranging from
tiny weights to 10^18.

Timing cases use 2,880 × 1,800 pixel bitmaps. Each case reports the median of
nine alternating baseline/optimized pairs and all raw samples. Treemap timing
includes construction of its hover index; hit testing times 1,000 treemap
queries or 50,000 ring queries over the same deterministic coordinates. The
balanced fixture has 13,280 nodes, the wide fixture 100,001, and the deep fixture
contains a chain of 120 directories. Run timing without concurrent builds or
other performance tests.

The second pass rejected lazy treemap weight access plus per-band operation
lists: the combined candidate regressed the 100,001-node fixture from 13.658 ms
to 28.374 ms against `178d256`, with balanced/deep maps essentially unchanged.
Those algorithm changes are absent from the final source. The raw paired
samples are retained as `results/2026-09-27/render-rejected-treemap.txt`.
