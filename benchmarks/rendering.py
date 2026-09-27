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
parser.add_argument("--profile", choices=["rings", "treemap"])
parser.add_argument("--rings-only", action="store_true")
parser.add_argument("--allow-ring-rounding", action="store_true")
parser.add_argument("--scale", type=int, choices=[1, 2], default=2)
args = parser.parse_args()
work = pathlib.Path(tempfile.mkdtemp(prefix="blitztree-rendering-"))
sources = ["Treemap.swift", "TreemapView.swift", "SunburstView.swift"]
renames = ["TMRect", "TMLabel", "TMLeafIndex", "Squarify", "TypeColor", "TreemapNSView", "NodeMenu",
           "TreemapView", "SBSegment", "SunburstNSView", "SunburstView"]
files = []
baseline_has_layout = False
for legacy in (True, False):
    for name in sources:
        source = (subprocess.check_output(["git", "show", f"{args.baseline}:app/{name}"], cwd=ROOT).decode()
                  if legacy else (ROOT / "app" / name).read_text())
        source = re.sub(r"\bprivate\s+", "", source)
        source = source.replace("window?.backingScaleFactor ?? 2", "window?.backingScaleFactor ?? renderingScale")
        if legacy and name == "Treemap.swift":
            baseline_has_layout = "struct Layout" in source
        if args.profile == "rings" and not legacy and name == "SunburstView.swift":
            if "func paintBase" in source:
                source = source.replace("    func render() -> CGImage? {", "    func render() -> CGImage? {\n        let profileStart = DispatchTime.now().uptimeNanoseconds")
                source = source.replace("        Self.paintBase(scene, in: ctx, scale: scale)", "        let profilePrepared = DispatchTime.now().uptimeNanoseconds\n        Self.paintBase(scene, in: ctx, scale: scale)\n        let profileBase = DispatchTime.now().uptimeNanoseconds")
                end = "        return ctx.makeImage()\n    }\n\n    nonisolated static func paintBase"
                diagnostic = '''        let profileFinished = DispatchTime.now().uptimeNanoseconds
        print("phase,rings,prepare,\\(Double(profilePrepared - profileStart) / 1e6),fill_shade,\\(Double(profileBase - profilePrepared) / 1e6),stroke_center,\\(Double(profileFinished - profileBase) / 1e6)")
'''
                source = source.replace(end, diagnostic + end)
            else:
                source = source.replace("        // Soft depth:", "        let profileFilled = DispatchTime.now().uptimeNanoseconds\n\n        // Soft depth:")
                source = source.replace("        // Hairline gaps", "        let profileShaded = DispatchTime.now().uptimeNanoseconds\n\n        // Hairline gaps")
                source = source.replace("        // Centre disc:", "        let profileStroked = DispatchTime.now().uptimeNanoseconds\n\n        // Centre disc:")
                source = source.replace("        ctx.fill(bounds)\n", "        ctx.fill(bounds)\n        let profileStart = DispatchTime.now().uptimeNanoseconds\n")
                diagnostic = '''        let profileFinished = DispatchTime.now().uptimeNanoseconds
        print("phase,rings,fill,\\(Double(profileFilled - profileStart) / 1e6),shade,\\(Double(profileShaded - profileFilled) / 1e6),stroke,\\(Double(profileStroked - profileShaded) / 1e6),center,\\(Double(profileFinished - profileStroked) / 1e6)")
'''
                source = source.replace("        return ctx.makeImage()", diagnostic + "        return ctx.makeImage()")
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
runner = (ROOT / "benchmarks" / "rendering.swift").read_text()
if baseline_has_layout:
    runner = runner.replace("let legacy = LegacySquarify.layoutItems(items, rect: rect)",
                            "let legacy = LegacySquarify.layoutItems(items, rect: rect).tiles")
runner_path = work / "RenderingBench.swift"
runner_path.write_text(runner)
subprocess.run(["swiftc", *files, str(runner_path),
                "-O", "-parse-as-library", "-swift-version", "6", "-default-isolation", "MainActor",
                "-target", "arm64-apple-macos14.0",
                "-framework", "AppKit", "-framework", "SwiftUI", "-o", str(binary)], check=True, cwd=ROOT)
print(f"Renderer benchmark binary: {binary}", flush=True)
if not args.build_only:
    mode = [f"--profile-{args.profile}"] if args.profile else (["--check-only"] if args.check_only else [])
    if args.rings_only:
        mode.append("--rings-only")
    if args.allow_ring_rounding:
        mode.append("--allow-ring-rounding")
    if args.scale == 1:
        mode.append("--scale1")
    subprocess.run([str(binary), *mode], check=True, cwd=ROOT)
if not args.build_only or args.output:
    shutil.rmtree(work)
