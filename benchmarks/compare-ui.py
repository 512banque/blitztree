#!/usr/bin/env python3
"""Alternate full-window harness processes and retain visible-handoff samples."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--baseline", type=Path, required=True)
p.add_argument("--candidate", type=Path, required=True)
p.add_argument("--path", required=True)
p.add_argument("--output", type=Path, required=True)
p.add_argument("--pairs", type=int, default=3)
p.add_argument("--scans", type=int, default=4)
a = p.parse_args()
if a.pairs < 1 or a.scans < 2:
    p.error("Need at least one pair and two scans per process")
records = []
for pair in range(a.pairs):
    for label in (["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]):
        result = subprocess.run([str(getattr(a, label).resolve()), a.path, str(a.scans)],
                                env={**os.environ, "BZ_TIMING": "1", "BZ_HOVER_PROBE": "1"},
                                capture_output=True, text=True, check=True)
        log = result.stdout + result.stderr
        samples = list(map(float, re.findall(r"BZ visible handoff: ([\d.]+) ms", log)))
        assert len(samples) == a.scans, log
        record = dict(pair=pair, build=label, visible_ms=samples,
                      root_bodies=list(map(int, re.findall(r"BZ trial \d+ root body evaluations=(\d+)", log))),
                      hover_root_bodies=int(re.search(r"BZ hover 120 updates: root body evaluations=(\d+)", log)[1]),
                      nodes=list(map(int, re.findall(r"BZ trial \d+ visible nodes=(\d+)", log))))
        records.append(record)
        print(json.dumps(record), flush=True)
        a.output.parent.mkdir(parents=True, exist_ok=True)
        a.output.with_name(f"{a.output.stem}-{pair}-{label}.txt").write_text(log)
summary = {}
for label in ("baseline", "candidate"):
    rows = [r for r in records if r["build"] == label]
    first = [r["visible_ms"][0] for r in rows]
    warm = [v for r in rows for v in r["visible_ms"][1:]]
    summary[label] = dict(first_median_ms=statistics.median(first),
                          rescan_median_ms=statistics.median(warm), rescan_range_ms=[min(warm), max(warm)],
                          hover_root_bodies=[r["hover_root_bodies"] for r in rows])
assert len({n for r in records for n in r["nodes"]}) == 1, "Scan targets changed during comparison"
a.output.write_text(json.dumps(dict(summary=summary, measurements=records, path=a.path,
    binary_sha256={label: hashlib.sha256(getattr(a, label).read_bytes()).hexdigest()
                   for label in ("baseline", "candidate")}), indent=2) + "\n")
print(json.dumps(summary, indent=2), flush=True)
