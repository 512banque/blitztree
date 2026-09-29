//! C ABI for the Swift UI. A scan runs on background threads; the UI polls
//! progress counters, then receives the finished tree as flat arrays
//! (zero-copy: Swift reads the buffers in place until bz_free).

use std::ffi::{c_char, c_int, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use crate::{cleanup, scan, snapshot, Progress, Tree};

pub struct BzScan {
    progress: Arc<Progress>,
    done: Arc<AtomicBool>,
    result: Arc<std::sync::Mutex<Option<Flat>>>,
    // Kept alive for the lifetime of the handle; Swift holds raw pointers in.
    flat: Option<Box<Flat>>,
    root: PathBuf,
}

/// The scanned tree (already in the flat layout) plus Clean Up's candidates.
struct Flat {
    tree: Tree,
    cleanup_nodes: Vec<u32>,
    cleanup_descriptions: Vec<CString>,
}

fn with_cleanup(tree: Tree) -> Flat {
    let candidates = cleanup::find(&tree, cleanup::MIN_BYTES);
    Flat {
        cleanup_nodes: candidates.iter().map(|c| c.node).collect(),
        cleanup_descriptions: candidates
            .iter()
            .map(|c| CString::new(c.kind.description()).expect("static cleanup label has no NUL"))
            .collect(),
        tree,
    }
}

/// Start a scan on background threads. Returns a handle immediately.
#[no_mangle]
pub extern "C" fn bz_scan_start(path: *const c_char) -> *mut BzScan {
    if path.is_null() {
        return std::ptr::null_mut();
    }
    let path = unsafe { CStr::from_ptr(path) };
    let path = PathBuf::from(String::from_utf8_lossy(path.to_bytes()).into_owned());
    let scan_path = path.clone();

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
            let tree = scan(&scan_path, &progress);
            let t1 = std::time::Instant::now();
            let flat = with_cleanup(tree);
            if std::env::var_os("BZ_TIMING").is_some() {
                eprintln!(
                    "[bz] scan {:.3}s  cleanup {:.1}ms",
                    (t1 - t0).as_secs_f64(),
                    t1.elapsed().as_secs_f64() * 1e3
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
        root: path,
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
    h.flat.as_ref().map_or(0, |f| f.tree.len() as u64)
}

macro_rules! getter {
    ($name:ident, $field:ident, $ty:ty) => {
        #[no_mangle]
        pub extern "C" fn $name(h: *mut BzScan) -> *const $ty {
            let h = unsafe { &*h };
            h.flat
                .as_ref()
                .map_or(std::ptr::null(), |f| f.tree.$field.as_ptr())
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

/// # Safety
/// `h` must be a live scan handle, with no concurrent mutation or free.
#[no_mangle]
pub unsafe extern "C" fn bz_cleanup_count(h: *mut BzScan) -> u64 {
    let h = unsafe { &*h };
    h.flat.as_ref().map_or(0, |f| f.cleanup_nodes.len() as u64)
}

/// # Safety
/// `h` must be a live scan handle, with no concurrent mutation or free.
/// Read at most `bz_cleanup_count(h)` elements, before `bz_free(h)`.
#[no_mangle]
pub unsafe extern "C" fn bz_cleanup_nodes(h: *mut BzScan) -> *const u32 {
    let h = unsafe { &*h };
    h.flat
        .as_ref()
        .map_or(std::ptr::null(), |f| f.cleanup_nodes.as_ptr())
}

/// Label at a candidate-list index (not a tree node index), valid until bz_free.
///
/// # Safety
/// `h` must be a live scan handle, with no concurrent mutation or free.
#[no_mangle]
pub unsafe extern "C" fn bz_cleanup_description(h: *mut BzScan, index: u64) -> *const c_char {
    let h = unsafe { &*h };
    h.flat
        .as_ref()
        .and_then(|f| f.cleanup_descriptions.get(index as usize))
        .map_or(std::ptr::null(), |s| s.as_ptr())
}

#[no_mangle]
pub extern "C" fn bz_errors(h: *mut BzScan) -> u64 {
    let h = unsafe { &*h };
    h.flat.as_ref().map_or(0, |f| f.tree.errors)
}

#[no_mangle]
pub extern "C" fn bz_free(h: *mut BzScan) {
    if !h.is_null() {
        drop(unsafe { Box::from_raw(h) });
    }
}

fn error_json(message: impl Into<String>) -> String {
    json!({"error": {"message": message.into()}}).to_string()
}

fn owned_json(result: Result<String, String>) -> *mut c_char {
    let text = result.unwrap_or_else(error_json);
    // JSON escaping prevents NUL bytes.  Keep a fallback in case a future
    // serializer change violates that assumption; an FFI error must never
    // panic while trying to report another error.
    CString::new(text)
        .or_else(|_| CString::new(error_json("JSON result contained a NUL byte")))
        .expect("static JSON error has no NUL")
        .into_raw()
}

fn ffi_result<F>(operation: F) -> *mut c_char
where
    F: FnOnce() -> Result<String, String> + std::panic::UnwindSafe,
{
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(result) => owned_json(result),
        Err(_) => owned_json(Err("internal snapshot error".into())),
    }
}

fn snapshot_for_handle(h: *mut BzScan) -> Result<Value, String> {
    if h.is_null() {
        return Err("scan handle is null".into());
    }
    // The GUI may call this from a detached task while Swift renders the
    // already-materialized flat arrays.  Keep this path immutable: callers
    // must have called bz_take_tree first, and no result/flat ownership is
    // transferred here.
    let h = unsafe { &*h };
    if !h.done.load(Ordering::Acquire) {
        return Err("scan is not complete".into());
    }
    let flat = h
        .flat
        .as_ref()
        .ok_or_else(|| "call bz_take_tree before requesting a snapshot".to_string())?;
    let generated = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    snapshot::snapshot_value(&h.root, &flat.tree, generated, flat.tree.errors)
}

fn c_string(value: *const c_char, name: &str) -> Result<String, String> {
    if value.is_null() {
        return Err(format!("{name} JSON pointer is null"));
    }
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .map(ToOwned::to_owned)
        .map_err(|_| format!("{name} JSON must be UTF-8"))
}

fn bounded_json_string(value: *const c_char, name: &str) -> Result<String, String> {
    let value = c_string(value, name)?;
    if value.len() > snapshot::MAX_SNAPSHOT_BYTES {
        return Err(format!("{name} JSON is larger than 64 MiB"));
    }
    Ok(value)
}

/// Return a newly allocated, versioned snapshot JSON string.  The caller owns
/// it and must release it with `bz_json_free`.
#[no_mangle]
pub extern "C" fn bz_snapshot_json(h: *mut BzScan) -> *mut c_char {
    ffi_result(|| snapshot_for_handle(h).and_then(|value| snapshot::serialize_bounded(&value)))
}

/// Compare two snapshot JSON strings without scanning or touching the
/// filesystem.  `limit == 0` selects the documented default of 100.
#[no_mangle]
pub extern "C" fn bz_compare_snapshots(
    before: *const c_char,
    after: *const c_char,
    limit: u32,
) -> *mut c_char {
    ffi_result(|| {
        let before = bounded_json_string(before, "before")?;
        let after = bounded_json_string(after, "after")?;
        let limit = if limit == 0 {
            snapshot::DEFAULT_LIMIT
        } else {
            usize::try_from(limit).map_err(|_| "limit is too large".to_string())?
        };
        snapshot::compare_snapshot_json(&before, &after, limit).map(|value| value.to_string())
    })
}

/// Save the current scan snapshot using exclusive creation and owner-only
/// permissions.  It returns a small acknowledgement JSON string owned by the
/// caller; failures use the same `{\"error\":{\"message\":...}}` shape.
#[no_mangle]
pub extern "C" fn bz_save_snapshot(h: *mut BzScan, destination: *const c_char) -> *mut c_char {
    ffi_result(|| {
        let destination = c_string(destination, "destination")?;
        if destination.is_empty() {
            return Err("destination cannot be empty".into());
        }
        let value = snapshot_for_handle(h)?;
        let text = snapshot::serialize_bounded(&value)?;
        let path = PathBuf::from(destination);
        snapshot::save_exclusive(&path, &text)?;
        Ok(json!({
            "ok": true,
            "kind": "blitztree_snapshot",
            "schema_version": snapshot::SCHEMA_VERSION,
            "path": path,
            "root": value["root"],
            "generated_at_unix": value["generated_at_unix"],
            "coverage": value["coverage"],
        })
        .to_string())
    })
}

/// Release a JSON string returned by any snapshot/comparison function.
#[no_mangle]
pub extern "C" fn bz_json_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::NO_PARENT;

    #[test]
    fn bridge_exposes_the_shared_candidates_and_labels() {
        for bytes in [0, cleanup::MIN_BYTES] {
            let mut tree = Tree::with_root("/root");
            tree.push("node_modules", 0, bytes, bytes, true);
            (tree.alloc[0], tree.logical[0]) = (bytes, bytes);
            tree.link_children();
            assert_eq!(tree.parents, [NO_PARENT, 0]);
            let expected = cleanup::find(&tree, cleanup::MIN_BYTES);
            assert_eq!(expected.len(), (bytes > 0) as usize);
            let mut handle = BzScan {
                progress: Arc::new(Progress::default()),
                done: Arc::new(AtomicBool::new(true)),
                result: Arc::new(std::sync::Mutex::new(None)),
                flat: Some(Box::new(with_cleanup(tree))),
                root: PathBuf::from("/root"),
            };
            let h = &mut handle as *mut BzScan;
            assert_eq!(unsafe { bz_cleanup_count(h) } as usize, expected.len());
            let nodes = unsafe { std::slice::from_raw_parts(bz_cleanup_nodes(h), expected.len()) };
            for (i, candidate) in expected.iter().enumerate() {
                assert_eq!(nodes[i], candidate.node);
                let label = unsafe { CStr::from_ptr(bz_cleanup_description(h, i as u64)) };
                assert_eq!(label.to_str().unwrap(), candidate.kind.description());
            }
            assert!(unsafe { bz_cleanup_description(h, expected.len() as u64) }.is_null());
        }
    }

    #[test]
    fn snapshot_ffi_uses_owned_json_and_reports_invalid_inputs() {
        let mut tree = Tree::with_root("/root");
        tree.link_children();
        let mut handle = BzScan {
            progress: Arc::new(Progress::default()),
            done: Arc::new(AtomicBool::new(true)),
            result: Arc::new(std::sync::Mutex::new(None)),
            flat: Some(Box::new(with_cleanup(tree))),
            root: PathBuf::from("/root"),
        };
        let snapshot_ptr = bz_snapshot_json(&mut handle);
        let snapshot = unsafe { CStr::from_ptr(snapshot_ptr) }
            .to_str()
            .unwrap()
            .to_owned();
        bz_json_free(snapshot_ptr);
        assert!(snapshot.contains("\"kind\":\"blitztree_snapshot\""));

        let before = CString::new(snapshot).unwrap();
        let comparison_ptr = bz_compare_snapshots(before.as_ptr(), before.as_ptr(), 0);
        let comparison = unsafe { CStr::from_ptr(comparison_ptr) }
            .to_str()
            .unwrap()
            .to_owned();
        bz_json_free(comparison_ptr);
        assert!(comparison.contains("\"kind\":\"blitztree_comparison\""));

        let error_ptr = bz_compare_snapshots(std::ptr::null(), before.as_ptr(), 100);
        let error = unsafe { CStr::from_ptr(error_ptr) }
            .to_str()
            .unwrap()
            .to_owned();
        bz_json_free(error_ptr);
        assert!(error.contains("\"error\""));

        let error_ptr = bz_snapshot_json(std::ptr::null_mut());
        let error = unsafe { CStr::from_ptr(error_ptr) }
            .to_str()
            .unwrap()
            .to_owned();
        bz_json_free(error_ptr);
        assert!(error.contains("\"error\""));
    }
}
