# Benchmarks

M4 MacBook (10 cores), macOS 27.0, APFS, warm cache. Median of three runs,
alternating tools. Reproduce with `cargo run --release --bin bench -- <mode> <path>`.

## Home directory: 2.8M entries, 197 GB

| strategy                                   | time       |
|--------------------------------------------|------------|
| **BlitzTree** (parallel `getattrlistbulk`) | **8.1 s**  |
| syscall floor (same walk, no tree built)   | 7.5 s      |
| parallel `readdir` + per-file `lstat`      | 11.8 s     |
| [disktree](https://github.com/tobi/disktree) 0.10.1 engine | 12.2 s |
| `du -sk`                                   | 56.7 s     |

## Whole data volume: 3.7M entries, 274 GB

| strategy                                   | time       |
|--------------------------------------------|------------|
| **BlitzTree**                              | **9.8 s**  |
| disktree 0.10.1 engine                     | 15.2 s     |

Both tools report the same total for the home directory (197.36 GB, equal to
`du`): each counts a hard-linked file once.

Peak memory of the scan engine alone (home directory): BlitzTree 317 MB,
disktree 598 MB. The two finished apps settle at about the same footprint,
roughly 720 MB, with a 2.8M-entry tree loaded.

## Findings

- `searchfs(2)`, the closest thing macOS has to reading NTFS's MFT, was 5×
  slower than the parallel walk on an earlier 1.9M-entry volume (38 s vs
  7.1 s): it is one sequential kernel iteration over the catalog and cannot be
  split across cores. The code is kept in
  `src/searchfs.rs` for reference.
- The walk is within 10% of the syscall floor; building the tree costs about
  0.6 s.
- Thread count sweet spot is about the core count. 32+ threads regress ~40%.
- Scan threads run at `QOS_CLASS_USER_INTERACTIVE`. At a GUI app's default
  QoS they land on efficiency cores and the scan takes twice as long.
- Without Full Disk Access about 430 directories are unreadable.
