#!/usr/bin/env python3
"""Compile real before/after rendering sources against deterministic tree fixtures.

uv run --no-project python benchmarks/rendering.py --baseline <git-ref> [--check-only]
Private access is widened only in temporary benchmark copies; production code
needs no test hooks. AppKit/CoreGraphics run offscreen, without opening windows.
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--baseline", required=True)
parser.add_argument("--check-only", action="store_true")
parser.add_argument("--build-only", action="store_true")
parser.add_argument("--output", type=pathlib.Path)
args = parser.parse_args()
work = pathlib.Path(tempfile.mkdtemp(prefix="blitztree-rendering-"))
sources = ["Treemap.swift", "TreemapView.swift", "SunburstView.swift"]
renames = ["TMRect", "TMLabel", "TMLeafIndex", "Squarify", "TypeColor", "TreemapNSView", "NodeMenu",
           "TreemapView", "SBSegment", "SunburstNSView", "SunburstView"]
files = []
for legacy in (True, False):
    for name in sources:
        source = (subprocess.check_output(["git", "show", f"{args.baseline}:app/{name}"], cwd=ROOT).decode()
                  if legacy else (ROOT / "app" / name).read_text())
        source = re.sub(r"\bprivate\s+", "", source)
        if legacy:
            for symbol in renames:
                source = re.sub(rf"\b{symbol}\b", "Legacy" + symbol, source)
            source = source.replace("rounded()", "legacyRounded()") if name == "SunburstView.swift" else source
            # Only the font convenience method gets renamed, not CGFloat.rounded().
            source = source.replace(".legacyRounded()", ".rounded()")
            source = source.replace(".semibold).rounded()", ".semibold).legacyRounded()")
        path = work / (("Legacy" if legacy else "") + name)
        path.write_text(source)
        files.append(str(path))
binary = args.output.resolve() if args.output else work / "rendering"
subprocess.run(["swiftc", *files, str(ROOT / "benchmarks" / "rendering.swift"),
                "-O", "-parse-as-library", "-swift-version", "6", "-default-isolation", "MainActor",
                "-target", "arm64-apple-macos14.0",
                "-framework", "AppKit", "-framework", "SwiftUI", "-o", str(binary)], check=True, cwd=ROOT)
print(f"Renderer benchmark binary: {binary}", flush=True)
if not args.build_only:
    subprocess.run([str(binary), *(["--check-only"] if args.check_only else [])], check=True, cwd=ROOT)
if not args.build_only or args.output:
    shutil.rmtree(work)
