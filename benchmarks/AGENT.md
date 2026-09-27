# Offline agent data benchmarks

`benchmarks/run-agent.sh` checks the production agent data algorithms and prints
nine alternating before/after timings. `--check-only` runs the correctness
checks without timing workloads. It uses the same `-O`, Swift 6, main actor
isolation and macOS 14 target as the app build. The runner freezes production
sources and logs their SHA256s before compiling.

The old parser, JSONL reader and complete prompt formatter from `178d256` are
retained in `AgentReference.swift`. The current formatter must produce exactly
the same prompt bytes, including equal-size node ordering and output limits.
The fixture adapter uses the actual `Tree` C bridge with immutable synthetic
sizes, names, and aggregated file counts. This benchmark measures CPU
work on already-scanned data, not scanning or agent response/network latency.

The benchmark makes no agent, auth, or network calls and never moves anything
to the user's Trash. Its frozen source copy replaces only the process launch
call and agent starts with counters and the manual Trash operation
with a controlled fake.
A test-only gate pauses prompt generation to force cancellation at the exact
race boundary. Production sources contain no injected launch/trash hooks.

Correctness checks include:

- Every split position in a complete item, fixed-width and 200 randomized
  delta patterns, escapes, surrogate escapes, Unicode, nested values,
  incomplete input and invalid items. Valid output is checked independently
  against decoding the complete JSON, in addition to baseline parity.
- Both Claude and Codex event streams, fragmented from one byte to entire
  batches, including invalid lines, restart events and outgoing request/event
  ordering. The Codex fixtures follow the documented stdio JSONL and streamed
  message lifecycle, checked with the OpenAI developer documentation MCP:
  [Codex App Server](https://developers.openai.com/codex/app-server).
- Prompt threshold boundaries, pass-through directories, and equal-size ties
  crossing the 250-folder and 80-file cutoffs.
- Cancellation before and during detached prompt preparation; an uncancelled
  run reaches the fake launch exactly once.
- A blocked fake Trash operation runs away from the UI thread while the main
  actor continues handling work. The batch rejects duplicate starts, preserves
  its captured selection and individual failures, clears busy state, and
  invokes the completion/rescan callback exactly once. Becoming ready during a
  busy cleanup does not consume or duplicate the model's one-shot launch
  panel, and the launch scan never starts an agent without a click. Cleanup
  failures remain on the model-owned controller after the inspector's
  callback is discarded and after a later successful batch; only explicit
  dismissal clears them.

The timed cases cover a normal 12-item plan, a larger plan grouping 144 paths
whose individual lengths remain under macOS path limits, 4,000 notifications
read in 16 KB batches, and one 512 KB record arriving in 512-byte fragments.
The latter is a stress case for long incomplete records, not normal per-event
traffic. Prompt timing uses 1,008,001 nodes representing approximately 223 GB
of projects with many small source files and 2,000 qualifying build folders.

A bounded heap alternative was rejected: selecting from the pruned candidate
list took 0.214 ms with the heap versus 0.027 ms with a normal sort. The
production implementation retains the simpler sort.

Measured 2026-09-27, arm64, Swift 6.4, with team benchmark workloads serialized:

| Workload | Before median | After median |
|---|---:|---:|
| Incremental parser, 12 items / 3,983 bytes / 244 deltas | 1.208 ms | 0.055 ms |
| Incremental parser, 12 items / 144 paths / 61,773 bytes | 169.604 ms | 0.351 ms |
| JSONL, 4,000 notifications in 16 KB batches | 14.511 ms | 13.279 ms |
| JSONL stress, 512 KB record in 512-byte fragments | 688.319 ms | 2.148 ms |
| Complete prompt, 1,008,001 nodes | 2.386 ms | 1.307 ms |

The complete prompts are byte-for-byte identical. These measurements describe
local CPU work and do not predict model/network response-time improvements.
Manual Trash responsiveness and cancellation are correctness regressions tested
with controlled offline delays, not claimed filesystem throughput gains.
Full timing samples and source hashes:
[agent-final.txt](results/2026-09-27/agent-final.txt).
The later cleanup error-ownership fix does not change timed parser or prompt
algorithms. Its separate correctness run and current source hashes are in
[agent-checks-final.txt](results/2026-09-27/agent-checks-final.txt).
