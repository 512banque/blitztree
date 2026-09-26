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
    let mut name_blob = Vec::new();

    child_off.push(0u32);
    name_off.push(0u32);
    for node in &s.nodes {
        parents.push(node.parent);
        alloc.push(node.alloc);
        logical.push(node.size);
        n_files.push(node.n_files);
        flags.push(node.is_dir as u8);

        // children sorted by allocated size, descending — treemap layout order
        let mut kids = node.children.clone();
        kids.sort_unstable_by_key(|&c| std::cmp::Reverse(s.nodes[c as usize].alloc));
        children.extend_from_slice(&kids);
        child_off.push(children.len() as u32);

        name_blob.extend_from_slice(node.name.as_bytes());
        name_off.push(name_blob.len() as u32);
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
                eprintln!("[bz] scan {:.2}s  flatten {:.2}s", (t1 - t0).as_secs_f64(), (t2 - t1).as_secs_f64());
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
            h.flat.as_ref().map_or(std::ptr::null(), |f| f.$field.as_ptr())
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
