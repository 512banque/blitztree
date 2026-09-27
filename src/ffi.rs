//! C ABI for the Swift UI. A scan runs on background threads; the UI polls
//! progress counters, then receives the finished tree as flat arrays
//! (zero-copy: Swift reads the buffers in place until bz_free).

use std::ffi::{c_char, c_int, CStr};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use crate::{scan, Progress};

pub struct BzScan {
    progress: Arc<Progress>,
    done: Arc<AtomicBool>,
    result: Arc<std::sync::Mutex<Option<Flat>>>,
    // Kept alive for the lifetime of the handle; Swift holds raw pointers in.
    flat: Option<Box<Flat>>,
}

#[cfg_attr(test, derive(Debug, PartialEq, Eq))]
struct Flat {
    parents: Vec<u32>,
    alloc: Vec<u64>,
    logical: Vec<u64>,
    n_files: Vec<u32>,
    flags: Vec<u8>, // bit0 = is_dir
    child_off: Vec<u32>,
    children: Vec<u32>,
    name_off: Vec<u32>,
    name_blob: Vec<u8>,
    errors: u64,
}

fn build_flat(s: crate::Scan) -> Flat {
    let n = s.nodes.len();
    let mut parents = Vec::with_capacity(n);
    let mut alloc = Vec::with_capacity(n);
    let mut logical = Vec::with_capacity(n);
    let mut n_files = Vec::with_capacity(n);
    let mut flags = Vec::with_capacity(n);
    let mut child_off = Vec::with_capacity(n + 1);
    let mut children: Vec<u32> = Vec::with_capacity(n.saturating_sub(1));
    let mut name_off = Vec::with_capacity(n + 1);
    let mut name_blob = Vec::with_capacity(s.nodes.iter().map(|node| node.name.len()).sum());

    child_off.push(0u32);
    name_off.push(0u32);
    for node in s.nodes {
        parents.push(node.parent);
        alloc.push(node.alloc);
        logical.push(node.size);
        n_files.push(node.n_files);
        flags.push(node.is_dir as u8);

        children.extend(node.children);
        child_off.push(children.len() as u32);

        name_blob.extend_from_slice(node.name.as_bytes());
        name_off.push(name_blob.len() as u32);
    }
    // Sort in the final buffer, using the compact allocation column rather
    // than copying every child list and randomly reading the large node arena.
    for offsets in child_off.windows(2) {
        children[offsets[0] as usize..offsets[1] as usize]
            .sort_unstable_by_key(|&c| std::cmp::Reverse(alloc[c as usize]));
    }
    Flat {
        parents,
        alloc,
        logical,
        n_files,
        flags,
        child_off,
        children,
        name_off,
        name_blob,
        errors: s.errors,
    }
}

/// Start a scan on background threads. Returns a handle immediately.
#[no_mangle]
pub extern "C" fn bz_scan_start(path: *const c_char) -> *mut BzScan {
    let path = unsafe { CStr::from_ptr(path) };
    let path = PathBuf::from(String::from_utf8_lossy(path.to_bytes()).into_owned());

    let progress = Arc::new(Progress::default());
    let done = Arc::new(AtomicBool::new(false));
    let result = Arc::new(std::sync::Mutex::new(None));

    {
        let progress = progress.clone();
        let done = done.clone();
        let result = result.clone();
        std::thread::spawn(move || {
            unsafe { crate::set_thread_qos_user_interactive() };
            let t0 = std::time::Instant::now();
            let s = scan(&path, &progress);
            let t1 = std::time::Instant::now();
            let flat = build_flat(s);
            let t2 = std::time::Instant::now();
            if std::env::var_os("BZ_TIMING").is_some() {
                eprintln!(
                    "[bz] scan {:.2}s  flatten {:.2}s",
                    (t1 - t0).as_secs_f64(),
                    (t2 - t1).as_secs_f64()
                );
            }
            *result.lock().unwrap() = Some(flat);
            done.store(true, Ordering::Release);
        });
    }

    Box::into_raw(Box::new(BzScan {
        progress,
        done,
        result,
        flat: None,
    }))
}

#[no_mangle]
pub extern "C" fn bz_progress(
    h: *mut BzScan,
    files: *mut u64,
    dirs: *mut u64,
    bytes: *mut u64,
    done: *mut c_int,
) {
    let h = unsafe { &mut *h };
    unsafe {
        *files = h.progress.files.load(Ordering::Relaxed);
        *dirs = h.progress.dirs.load(Ordering::Relaxed);
        *bytes = h.progress.bytes.load(Ordering::Relaxed);
        *done = h.done.load(Ordering::Acquire) as c_int;
    }
}

/// After done: materialize the flat tree in the handle. Returns node count.
#[no_mangle]
pub extern "C" fn bz_take_tree(h: *mut BzScan) -> u64 {
    let h = unsafe { &mut *h };
    if h.flat.is_none() {
        if let Some(f) = h.result.lock().unwrap().take() {
            h.flat = Some(Box::new(f));
        }
    }
    h.flat.as_ref().map_or(0, |f| f.parents.len() as u64)
}

macro_rules! getter {
    ($name:ident, $field:ident, $ty:ty) => {
        #[no_mangle]
        pub extern "C" fn $name(h: *mut BzScan) -> *const $ty {
            let h = unsafe { &*h };
            h.flat
                .as_ref()
                .map_or(std::ptr::null(), |f| f.$field.as_ptr())
        }
    };
}

getter!(bz_parents, parents, u32);
getter!(bz_alloc, alloc, u64);
getter!(bz_logical, logical, u64);
getter!(bz_nfiles, n_files, u32);
getter!(bz_flags, flags, u8);
getter!(bz_child_off, child_off, u32);
getter!(bz_children, children, u32);
getter!(bz_name_off, name_off, u32);
getter!(bz_name_blob, name_blob, u8);

#[no_mangle]
pub extern "C" fn bz_errors(h: *mut BzScan) -> u64 {
    let h = unsafe { &*h };
    h.flat.as_ref().map_or(0, |f| f.errors)
}

#[no_mangle]
pub extern "C" fn bz_free(h: *mut BzScan) {
    if !h.is_null() {
        drop(unsafe { Box::from_raw(h) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Node, Scan, NO_PARENT};

    fn fixture(dirs: usize, files_per_dir: usize) -> Scan {
        let mut nodes = vec![Node {
            name: "/fixture".into(),
            parent: NO_PARENT,
            size: 0,
            alloc: 0,
            is_dir: true,
            n_files: 0,
            children: 1..dirs as u32 + 1,
        }];
        for dir in 0..dirs {
            let start = (dirs + 1 + dir * files_per_dir) as u32;
            nodes.push(Node {
                name: format!("directory-{dir}").into_boxed_str(),
                parent: 0,
                size: 0,
                alloc: 0,
                is_dir: true,
                n_files: 0,
                children: start..start + files_per_dir as u32,
            });
        }
        for dir in 0..dirs {
            for file in 0..files_per_dir {
                let size = (file as u64 * 7919 + dir as u64 * 104729) % 1_000_000;
                nodes.push(Node {
                    name: format!("document-{dir}-{file}-é-日本語.txt").into_boxed_str(),
                    parent: dir as u32 + 1,
                    size,
                    alloc: size.div_ceil(4096) * 4096,
                    is_dir: false,
                    n_files: 0,
                    children: 0..0,
                });
            }
        }
        crate::aggregate(&mut nodes);
        Scan { nodes, errors: 3 }
    }

    // Keep the original conversion as an independent reference for both exact
    // ABI regression coverage and an isolated, repeatable flatten benchmark.
    fn reference_flat(s: Scan) -> Flat {
        let n = s.nodes.len();
        let mut flat = Flat {
            parents: Vec::with_capacity(n),
            alloc: Vec::with_capacity(n),
            logical: Vec::with_capacity(n),
            n_files: Vec::with_capacity(n),
            flags: Vec::with_capacity(n),
            child_off: Vec::with_capacity(n + 1),
            children: Vec::with_capacity(n.saturating_sub(1)),
            name_off: Vec::with_capacity(n + 1),
            name_blob: Vec::new(),
            errors: s.errors,
        };
        flat.child_off.push(0);
        flat.name_off.push(0);
        for node in &s.nodes {
            flat.parents.push(node.parent);
            flat.alloc.push(node.alloc);
            flat.logical.push(node.size);
            flat.n_files.push(node.n_files);
            flat.flags.push(node.is_dir as u8);
            let mut kids: Vec<_> = node.children.clone().collect();
            kids.sort_unstable_by_key(|&c| std::cmp::Reverse(s.nodes[c as usize].alloc));
            flat.children.extend_from_slice(&kids);
            flat.child_off.push(flat.children.len() as u32);
            flat.name_blob.extend_from_slice(node.name.as_bytes());
            flat.name_off.push(flat.name_blob.len() as u32);
        }
        flat
    }

    #[test]
    fn flatten_preserves_every_abi_column_and_child_order() {
        for (dirs, files) in [(0, 0), (3, 0), (1, 1024), (128, 4)] {
            assert_eq!(
                build_flat(fixture(dirs, files)),
                reference_flat(fixture(dirs, files))
            );
        }
    }

    #[test]
    #[ignore = "isolated performance measurement; run in release with --nocapture"]
    fn flatten_benchmark() {
        // Alternate execution order to avoid favoring either implementation.
        for round in 0..10 {
            for variant in [round % 2, 1 - round % 2] {
                let scan = fixture(256, 1024);
                let start = std::time::Instant::now();
                let flat = if variant == 0 {
                    reference_flat(scan)
                } else {
                    build_flat(scan)
                };
                let elapsed = start.elapsed();
                std::hint::black_box(&flat);
                println!("flatten,{round},{variant},{}", elapsed.as_nanos());
            }
        }
    }
}
