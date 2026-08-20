//! Ultra-fast APFS directory tree scanner using getattrlistbulk(2).
//!
//! getattrlistbulk returns a whole batch of directory entries *with* their
//! metadata (name, type, sizes) per syscall, so we never pay the classic
//! readdir-then-stat-per-file cost that makes naive scanners slow on macOS.

pub mod ffi;
pub mod searchfs;

use std::ffi::{c_int, c_void, CString};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

// ---- FFI: getattrlistbulk ----

#[repr(C)]
struct AttrList {
    bitmapcount: u16,
    reserved: u16,
    commonattr: u32,
    volattr: u32,
    dirattr: u32,
    fileattr: u32,
    forkattr: u32,
}

extern "C" {
    fn getattrlistbulk(
        dirfd: c_int,
        attr_list: *mut AttrList,
        attr_buf: *mut c_void,
        attr_buf_size: usize,
        options: u64,
    ) -> c_int;
}

const ATTR_BIT_MAP_COUNT: u16 = 5;
const ATTR_CMN_NAME: u32 = 0x0000_0001;
const ATTR_CMN_OBJTYPE: u32 = 0x0000_0008;
const ATTR_CMN_ERROR: u32 = 0x2000_0000;
const ATTR_CMN_RETURNED_ATTRS: u32 = 0x8000_0000;
const ATTR_FILE_TOTALSIZE: u32 = 0x0000_0002;
const ATTR_FILE_ALLOCSIZE: u32 = 0x0000_0004;

const VDIR: u32 = 2;

const BUF_SIZE: usize = 256 * 1024;

// ---- Tree model ----

pub const NO_PARENT: u32 = u32::MAX;

pub struct Node {
    pub name: Box<str>,
    pub parent: u32,
    /// Logical size in bytes (own size for files; subtree total after aggregate()).
    pub size: u64,
    /// Allocated (on-disk) size in bytes; subtree total after aggregate().
    pub alloc: u64,
    pub is_dir: bool,
    /// Subtree file count after aggregate().
    pub n_files: u32,
    pub children: Vec<u32>,
}

pub struct Scan {
    pub nodes: Vec<Node>,
    pub errors: u64,
}

#[derive(Default)]
pub struct Progress {
    pub files: AtomicU64,
    pub dirs: AtomicU64,
    pub bytes: AtomicU64,
    pub errors: AtomicU64,
}

struct RawEntry {
    name: Box<str>,
    is_dir: bool,
    size: u64,
    alloc: u64,
}

/// Read all entries of one directory in bulk. Returns None if the dir can't be opened.
fn read_dir_bulk(path: &Path, buf: &mut Vec<u8>, progress: &Progress) -> Option<Vec<RawEntry>> {
    let cpath = CString::new(path.as_os_str().as_encoded_bytes()).ok()?;
    let fd = unsafe {
        libc::open(
            cpath.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        progress.errors.fetch_add(1, Ordering::Relaxed);
        if std::env::var_os("BZ_LOG_ERRORS").is_some() {
            eprintln!(
                "[bz] skip {} ({})",
                path.display(),
                std::io::Error::last_os_error()
            );
        }
        return None;
    }

    let mut attrlist = AttrList {
        bitmapcount: ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE,
        volattr: 0,
        dirattr: 0,
        fileattr: ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE,
        forkattr: 0,
    };

    let mut entries = Vec::new();
    loop {
        let n = unsafe {
            getattrlistbulk(
                fd,
                &mut attrlist,
                buf.as_mut_ptr() as *mut c_void,
                BUF_SIZE,
                0,
            )
        };
        if n <= 0 {
            if n < 0 {
                progress.errors.fetch_add(1, Ordering::Relaxed);
            }
            break;
        }
        let mut off = 0usize;
        for _ in 0..n {
            let entry = &buf[off..];
            let len = u32_at(entry, 0) as usize;
            parse_entry(&entry[..len], &mut entries);
            off += len;
        }
    }
    unsafe { libc::close(fd) };
    Some(entries)
}

fn u32_at(b: &[u8], off: usize) -> u32 {
    u32::from_le_bytes(b[off..off + 4].try_into().unwrap())
}

fn i64_at(b: &[u8], off: usize) -> i64 {
    i64::from_le_bytes(b[off..off + 8].try_into().unwrap())
}

/// Parse one getattrlistbulk entry. Attribute order within an entry is fixed:
/// RETURNED_ATTRS, ERROR, NAME, OBJTYPE, then file attrs (TOTALSIZE, ALLOCSIZE).
fn parse_entry(e: &[u8], out: &mut Vec<RawEntry>) {
    let mut off = 4usize; // skip length
    let ret_common = u32_at(e, off);
    let ret_file = u32_at(e, off + 12);
    off += 20; // attribute_set_t: 5 x u32

    if ret_common & ATTR_CMN_ERROR != 0 {
        let err = u32_at(e, off);
        off += 4;
        if err != 0 {
            return;
        }
    }

    let mut name = "";
    if ret_common & ATTR_CMN_NAME != 0 {
        let data_off = u32_at(e, off) as i32 as isize;
        let data_len = u32_at(e, off + 4) as usize;
        let start = (off as isize + data_off) as usize;
        // data_len includes the trailing NUL
        let raw = &e[start..start + data_len.saturating_sub(1)];
        name = std::str::from_utf8(raw).unwrap_or("");
        off += 8;
    }

    let mut is_dir = false;
    if ret_common & ATTR_CMN_OBJTYPE != 0 {
        is_dir = u32_at(e, off) == VDIR;
        off += 4;
    }

    let mut size = 0u64;
    let mut alloc = 0u64;
    if ret_file & ATTR_FILE_TOTALSIZE != 0 {
        size = i64_at(e, off).max(0) as u64;
        off += 8;
    }
    if ret_file & ATTR_FILE_ALLOCSIZE != 0 {
        alloc = i64_at(e, off).max(0) as u64;
    }

    if name.is_empty() {
        return;
    }
    out.push(RawEntry {
        name: name.into(),
        is_dir,
        size,
        alloc,
    });
}

// ---- Parallel walk ----

struct Shared<'a> {
    arena: Mutex<Vec<Node>>,
    progress: &'a Progress,
}

fn walk<'s>(scope: &rayon::Scope<'s>, shared: &'s Shared<'s>, dir_path: PathBuf, dir_idx: u32) {
    let mut buf = vec![0u8; BUF_SIZE];
    let Some(entries) = read_dir_bulk(&dir_path, &mut buf, shared.progress) else {
        return;
    };
    drop(buf);

    let mut n_files = 0u64;
    let mut n_dirs = 0u64;
    let mut bytes = 0u64;
    for e in &entries {
        if e.is_dir {
            n_dirs += 1;
        } else {
            n_files += 1;
            bytes += e.alloc;
        }
    }
    shared.progress.files.fetch_add(n_files, Ordering::Relaxed);
    shared.progress.dirs.fetch_add(n_dirs, Ordering::Relaxed);
    shared.progress.bytes.fetch_add(bytes, Ordering::Relaxed);

    // Reserve arena slots for all children under one short lock.
    let base = {
        let mut arena = shared.arena.lock().unwrap();
        let base = arena.len() as u32;
        for e in &entries {
            arena.push(Node {
                name: e.name.clone(),
                parent: dir_idx,
                size: e.size,
                alloc: e.alloc,
                is_dir: e.is_dir,
                n_files: 0,
                children: Vec::new(),
            });
        }
        arena[dir_idx as usize].children = (base..base + entries.len() as u32).collect();
        base
    };

    for (i, e) in entries.iter().enumerate() {
        if e.is_dir {
            let child_idx = base + i as u32;
            let child_path = dir_path.join(&*e.name);
            scope.spawn(move |s| walk(s, shared, child_path, child_idx));
        }
    }
}

extern "C" {
    fn pthread_set_qos_class_self_np(qos_class: u32, relative_priority: c_int) -> c_int;
}
const QOS_CLASS_USER_INTERACTIVE: u32 = 0x21;

/// # Safety
/// Only affects the calling thread's scheduling class.
pub unsafe fn set_thread_qos_user_interactive() {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
}

/// Rayon pool with USER_INTERACTIVE QoS so scan workers run on P-cores even
/// inside a GUI app process (default app-thread QoS lands on E-cores).
fn fast_pool() -> rayon::ThreadPool {
    rayon::ThreadPoolBuilder::new()
        .start_handler(|_| unsafe {
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        })
        .build()
        .expect("thread pool")
}

/// Scan `root` and return the finished tree with aggregated subtree sizes.
pub fn scan(root: &Path, progress: &Progress) -> Scan {
    let root_name: Box<str> = root.to_string_lossy().into_owned().into_boxed_str();
    let arena = Mutex::new(vec![Node {
        name: root_name,
        parent: NO_PARENT,
        size: 0,
        alloc: 0,
        is_dir: true,
        n_files: 0,
        children: Vec::new(),
    }]);
    let shared = Shared { arena, progress };

    fast_pool().scope(|s| walk(s, &shared, root.to_path_buf(), 0));

    let mut nodes = shared.arena.into_inner().unwrap();
    aggregate(&mut nodes);
    Scan {
        nodes,
        errors: progress.errors.load(Ordering::Relaxed),
    }
}

/// Count-only walk with no tree building: measures the pure syscall floor.
pub fn scan_count(root: &Path, progress: &Progress) {
    fn go<'s>(scope: &rayon::Scope<'s>, progress: &'s Progress, dir: PathBuf) {
        let mut buf = vec![0u8; BUF_SIZE];
        let Some(entries) = read_dir_bulk(&dir, &mut buf, progress) else {
            return;
        };
        drop(buf);
        for e in entries {
            if e.is_dir {
                progress.dirs.fetch_add(1, Ordering::Relaxed);
                let p = dir.join(&*e.name);
                scope.spawn(move |s| go(s, progress, p));
            } else {
                progress.files.fetch_add(1, Ordering::Relaxed);
                progress.bytes.fetch_add(e.alloc, Ordering::Relaxed);
            }
        }
    }
    rayon::scope(|s| go(s, progress, root.to_path_buf()));
}

/// Bottom-up subtree totals. Children always have higher indices than their
/// parent, so one reverse pass suffices.
fn aggregate(nodes: &mut [Node]) {
    for i in (1..nodes.len()).rev() {
        let parent = nodes[i].parent as usize;
        let (size, alloc, nf) = {
            let n = &nodes[i];
            (n.size, n.alloc, if n.is_dir { n.n_files } else { 1 })
        };
        let p = &mut nodes[parent];
        p.size += size;
        p.alloc += alloc;
        p.n_files += nf;
    }
}
