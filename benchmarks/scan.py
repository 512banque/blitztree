#!/usr/bin/env python3
"""Alternate two release bench binaries; retain every measurement and total.

uv run benchmarks/scan.py --baseline build/perf-baseline-source/target/release/bench \
    --candidate target/release/bench --path /Applications --output build/perf-results/apps.json
"""

import argparse
import hashlib
import json
import os
import platform
import re
import statistics
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--path", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=("bulk", "ffi"), default="ffi")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--threads", type=int)
    args = parser.parse_args()
    if args.runs < 1 or (args.threads is not None and args.threads < 1):
        parser.error("runs and threads must be positive")
    environment = {**os.environ, "BZ_JSON": "1"}
    records = []

    def run(label):
        command = ["/usr/bin/time", "-l", str(getattr(args, label).resolve()), args.mode, str(args.path.resolve())]
        if args.threads:
            command.append(str(args.threads))
        result = subprocess.run(command, env=environment, capture_output=True, text=True, check=True)
        record = {"build": label, **json.loads(result.stdout)}
        for key, pattern in (
            ("max_rss_bytes", r"(\d+)\s+maximum resident set size"),
            ("peak_footprint_bytes", r"(\d+)\s+peak memory footprint"),
        ):
            match = re.search(pattern, result.stderr)
            if match:
                record[key] = int(match[1])
        return record

    # Warm both code/data paths before measured AB/BA pairs.
    for label in ("baseline", "candidate"):
        run(label)
    for index in range(args.runs):
        order = ("baseline", "candidate") if index % 2 == 0 else ("candidate", "baseline")
        for label in order:
            record = {"pair": index + 1, **run(label)}
            records.append(record)
            print(json.dumps(record), flush=True)

    totals = {(r["files"], r["dirs"], r["bytes"], r["errors"]) for r in records}
    summary = {}
    for label in ("baseline", "candidate"):
        rows = [r for r in records if r["build"] == label]
        summary[label] = {
            "median_seconds": statistics.median(r["seconds"] for r in rows),
            "min_seconds": min(r["seconds"] for r in rows),
            "max_seconds": max(r["seconds"] for r in rows),
            "median_peak_footprint_bytes": statistics.median(r["peak_footprint_bytes"] for r in rows),
        }
    summary["speedup"] = summary["baseline"]["median_seconds"] / summary["candidate"]["median_seconds"]
    summary["all_totals_identical"] = len(totals) == 1
    output = {
        "platform": platform.platform(), "cpus": os.cpu_count(),
        "path": str(args.path.resolve()), "mode": args.mode, "threads": args.threads,
        "binary_sha256": {
            label: hashlib.sha256(getattr(args, label).read_bytes()).hexdigest()
            for label in ("baseline", "candidate")
        },
        "summary": summary, "measurements": records,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2) + "\n")
    print(json.dumps(summary, indent=2), flush=True)
    if len(totals) != 1:
        print("Totals changed: inspect the live tree or a correctness regression before comparing speed.", flush=True)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
