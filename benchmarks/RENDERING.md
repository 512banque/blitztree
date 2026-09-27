# Rendering regression and performance harness

Run on an Apple Silicon Mac with the Swift toolchain:

```sh
uv run --no-project python benchmarks/rendering.py --baseline 74b8fe4f097a819ece484a73e08f5368e64c3001
```

Add `--check-only` to omit timings. `--build-only --output /tmp/blitztree-rendering-bench`
builds an executable that can be timed later while other benchmarks are idle.

The harness compiles the actual baseline and working-tree renderer files as
separate Swift files, widening private visibility only in temporary copies. It
uses the app's `-O`, Swift 6, main actor isolation, and macOS 14 deployment target
without whole-module optimization. A deterministic immutable synthetic Tree
adapter replaces the Rust FFI tree; these are offscreen rendering comparisons,
not end-to-end scan or application responsiveness measurements.

Correctness checks compare all bitmap bytes, leaf/directory rectangles, labels,
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
