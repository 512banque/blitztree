//! Benchmark harness: compares scan strategies on a real directory tree.
//!
//! Usage: bench <mode> <path> [threads]
//!   modes: bulk        - parallel getattrlistbulk (our engine)
//!          naive       - serial read_dir + per-file lstat (Disk Inventory X style)
//!          naive-par   - parallel read_dir + per-file lstat
//!   BZ_TOP=1 also prints each top-level entry's allocated bytes (for diffing).

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use blitztree::{scan, Progress};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).map(String::as_str).unwrap_or("bulk");
    let path = PathBuf::from(args.get(2).map(String::as_str).unwrap_or("."));
    if let Some(t) = args.get(3) {
        rayon::ThreadPoolBuilder::new()
            .num_threads(t.parse().unwrap())
            .build_global()
            .unwrap();
    }

    let start = Instant::now();
    let (files, dirs, bytes, errors) = match mode {
        "bulk" => {
            let progress = Progress::default();
            let result = scan(&path, &progress);
            let root = &result.nodes[0];
            if std::env::var_os("BZ_TOP").is_some() {
                for &c in &root.children {
                    let n = &result.nodes[c as usize];
                    eprintln!("TOP\t{}\t{}", n.name, n.alloc);
                }
            }
            (
                root.n_files as u64,
                progress.dirs.load(Ordering::Relaxed),
                root.alloc,
                result.errors,
            )
        }
        "bulk-count" => {
            let progress = Progress::default();
            blitztree::scan_count(&path, &progress);
            (
                progress.files.load(Ordering::Relaxed),
                progress.dirs.load(Ordering::Relaxed),
                progress.bytes.load(Ordering::Relaxed),
                progress.errors.load(Ordering::Relaxed),
            )
        }
        "searchfs" => {
            let progress = Progress::default();
            match blitztree::searchfs::catalog_dump(&path, &progress) {
                Ok(entries) => {
                    let e = entries.len();
                    eprintln!("  ({e} catalog entries)");
                }
                Err(err) => eprintln!("  searchfs failed: {err}"),
            }
            (
                progress.files.load(Ordering::Relaxed),
                progress.dirs.load(Ordering::Relaxed),
                progress.bytes.load(Ordering::Relaxed),
                progress.errors.load(Ordering::Relaxed),
            )
        }
        "naive" => {
            let mut c = Counts::default();
            naive_walk(&path, &mut c);
            (c.files, c.dirs, c.bytes, c.errors)
        }
        "naive-par" => {
            let c = AtomicCounts::default();
            rayon::scope(|s| naive_walk_par(s, &path, &c));
            (
                c.files.load(Ordering::Relaxed),
                c.dirs.load(Ordering::Relaxed),
                c.bytes.load(Ordering::Relaxed),
                c.errors.load(Ordering::Relaxed),
            )
        }
        m => {
            eprintln!("unknown mode {m}");
            std::process::exit(1);
        }
    };
    let dt = start.elapsed();

    let total = files + dirs;
    println!(
        "{mode:>9}  {:>8.3}s  {files:>9} files  {dirs:>8} dirs  {:>8.2} GB  {errors:>6} errs  {:>10.0} entries/s",
        dt.as_secs_f64(),
        bytes as f64 / 1e9,
        total as f64 / dt.as_secs_f64()
    );
}

#[derive(Default)]
struct Counts {
    files: u64,
    dirs: u64,
    bytes: u64,
    errors: u64,
}

fn naive_walk(dir: &Path, c: &mut Counts) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        c.errors += 1;
        return;
    };
    for entry in rd.flatten() {
        let (Ok(meta), Ok(ft)) = (entry.metadata(), entry.file_type()) else {
            c.errors += 1;
            continue;
        };
        if ft.is_dir() {
            c.dirs += 1;
            naive_walk(&entry.path(), c);
        } else {
            c.files += 1;
            c.bytes += meta.len();
        }
    }
}

#[derive(Default)]
struct AtomicCounts {
    files: AtomicU64,
    dirs: AtomicU64,
    bytes: AtomicU64,
    errors: AtomicU64,
}

fn naive_walk_par<'s>(scope: &rayon::Scope<'s>, dir: &Path, c: &'s AtomicCounts) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        c.errors.fetch_add(1, Ordering::Relaxed);
        return;
    };
    for entry in rd.flatten() {
        let Ok(meta) = entry.path().symlink_metadata() else {
            c.errors.fetch_add(1, Ordering::Relaxed);
            continue;
        };
        if meta.is_dir() {
            c.dirs.fetch_add(1, Ordering::Relaxed);
            let p = entry.path();
            scope.spawn(move |s| naive_walk_par(s, &p, c));
        } else {
            c.files.fetch_add(1, Ordering::Relaxed);
            c.bytes.fetch_add(meta.len(), Ordering::Relaxed);
        }
    }
}
