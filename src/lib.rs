//! Ultra-fast APFS directory tree scanner using getattrlistbulk(2).
//!
//! getattrlistbulk returns a whole batch of directory entries *with* their
//! metadata (name, type, sizes) per syscall, so we never pay the classic
//! readdir-then-stat-per-file cost that makes naive scanners slow on macOS.

pub mod ffi;
pub mod searchfs;

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{c_int, c_void, CString};
use std::ops::Range;
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
const ATTR_CMN_DEVID: u32 = 0x0000_0002;
const ATTR_CMN_OBJTYPE: u32 = 0x0000_0008;
const ATTR_CMN_FLAGS: u32 = 0x0004_0000;
const ATTR_CMN_FILEID: u32 = 0x0200_0000;
const ATTR_CMN_ERROR: u32 = 0x2000_0000;
const ATTR_CMN_RETURNED_ATTRS: u32 = 0x8000_0000;
const ATTR_DIR_MOUNTSTATUS: u32 = 0x0000_0004;
const DIR_MNTSTATUS_MNTPOINT: u32 = 0x0000_0001;
const ATTR_FILE_LINKCOUNT: u32 = 0x0000_0001;
const ATTR_FILE_TOTALSIZE: u32 = 0x0000_0002;
const ATTR_FILE_ALLOCSIZE: u32 = 0x0000_0004;

const VDIR: u32 = 2;
/// Contents live in the cloud (iCloud Drive, File Provider). Opening such a
/// directory asks the provider to materialize it, i.e. download.
const SF_DATALESS: u32 = 0x4000_0000;

const BUF_SIZE: usize = 256 * 1024;

thread_local! {
    // A worker reads one directory at a time, and releases the buffer before
    // spawning its children. Reuse its allocation instead of allocating and
    // zeroing 256 KiB for every directory (including empty directories).
    static BULK_BUFFER: RefCell<Vec<u8>> = RefCell::new(vec![0; BUF_SIZE]);
}

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
    /// False when an entry was unreadable or a cloud/mount boundary was skipped
    /// anywhere in this subtree. The observed sizes then describe a partial walk.
    pub complete: bool,
    /// Subtree file count after aggregate().
    pub n_files: u32,
    /// Direct children occupy one contiguous arena batch, all after this
    /// node. The arena lock covers the entire sibling append and publication
    /// of this range. Files and unread/empty directories have an empty range;
    /// the FFI conversion expands and sorts IDs in its own final buffer.
    pub children: Range<u32>,
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
    pub entry_errors: AtomicU64,
    pub invalid_names: AtomicU64,
    pub skipped_cloud_dirs: AtomicU64,
    pub skipped_mount_points: AtomicU64,
}

struct RawEntry {
    name: Box<str>,
    is_dir: bool,
    dataless: bool,
    /// Another volume is mounted here (a disk image, Recovery, a simulator
    /// runtime, autofs). Not descended: a scan measures one volume.
    mount_point: bool,
    size: u64,
    alloc: u64,
    /// `(device, file id)` when the file has more than one hard link.
    hardlink: Option<(u32, u64)>,
}

/// Read all entries of one directory in bulk. Returns None if the dir can't be opened.
fn read_dir_bulk(path: &Path, progress: &Progress) -> Option<(Vec<RawEntry>, bool)> {
    BULK_BUFFER.with_borrow_mut(|buf| read_dir_bulk_buffered(path, buf, progress))
}

fn read_dir_bulk_buffered(
    path: &Path,
    buf: &mut [u8],
    progress: &Progress,
) -> Option<(Vec<RawEntry>, bool)> {
    let cpath = CString::new(path.as_os_str().as_encoded_bytes())
        .ok()
        .or_else(|| {
            progress.errors.fetch_add(1, Ordering::Relaxed);
            None
        })?;
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
        commonattr: ATTR_CMN_RETURNED_ATTRS
            | ATTR_CMN_ERROR
            | ATTR_CMN_NAME
            | ATTR_CMN_DEVID
            | ATTR_CMN_OBJTYPE
            | ATTR_CMN_FLAGS
            | ATTR_CMN_FILEID,
        volattr: 0,
        dirattr: ATTR_DIR_MOUNTSTATUS,
        fileattr: ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE,
        forkattr: 0,
    };

    let mut entries = Vec::new();
    let mut complete = true;
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
                complete = false;
            }
            break;
        }
        let mut off = 0usize;
        for _ in 0..n {
            let entry = &buf[off..];
            let len = u32_at(entry, 0) as usize;
            complete &= parse_entry(&entry[..len], &mut entries, progress);
            off += len;
        }
    }
    unsafe { libc::close(fd) };
    Some((entries, complete))
}

fn u32_at(b: &[u8], off: usize) -> u32 {
    u32::from_le_bytes(b[off..off + 4].try_into().unwrap())
}

fn i64_at(b: &[u8], off: usize) -> i64 {
    i64::from_le_bytes(b[off..off + 8].try_into().unwrap())
}

fn u64_at(b: &[u8], off: usize) -> u64 {
    u64::from_le_bytes(b[off..off + 8].try_into().unwrap())
}

/// Parse one getattrlistbulk entry. Attribute order within an entry is fixed:
/// RETURNED_ATTRS, ERROR, then common attrs by bit (NAME, DEVID, OBJTYPE,
/// FLAGS, FILEID), then dir attrs (MOUNTSTATUS), then file attrs (LINKCOUNT,
/// TOTALSIZE, ALLOCSIZE). Dir attrs come back only for directories and file
/// attrs only for files.
fn parse_entry(e: &[u8], out: &mut Vec<RawEntry>, progress: &Progress) -> bool {
    let mut off = 4usize; // skip length
    let ret_common = u32_at(e, off);
    let ret_dir = u32_at(e, off + 8);
    let ret_file = u32_at(e, off + 12);
    off += 20; // attribute_set_t: 5 x u32

    if ret_common & ATTR_CMN_ERROR != 0 {
        let err = u32_at(e, off);
        off += 4;
        if err != 0 {
            progress.entry_errors.fetch_add(1, Ordering::Relaxed);
            progress.errors.fetch_add(1, Ordering::Relaxed);
            return false;
        }
    }

    let mut name = "";
    if ret_common & ATTR_CMN_NAME != 0 {
        let data_off = u32_at(e, off) as i32 as isize;
        let data_len = u32_at(e, off + 4) as usize;
        let start = (off as isize + data_off) as usize;
        // data_len includes the trailing NUL
        let raw = &e[start..start + data_len.saturating_sub(1)];
        name = match std::str::from_utf8(raw) {
            Ok(name) => name,
            Err(_) => {
                progress.invalid_names.fetch_add(1, Ordering::Relaxed);
                progress.errors.fetch_add(1, Ordering::Relaxed);
                return false;
            }
        };
        off += 8;
    }

    let mut dev = 0u32;
    if ret_common & ATTR_CMN_DEVID != 0 {
        dev = u32_at(e, off);
        off += 4;
    }

    let mut is_dir = false;
    if ret_common & ATTR_CMN_OBJTYPE != 0 {
        is_dir = u32_at(e, off) == VDIR;
        off += 4;
    }

    let mut flags = 0u32;
    if ret_common & ATTR_CMN_FLAGS != 0 {
        flags = u32_at(e, off);
        off += 4;
    }

    let mut file_id = 0u64;
    if ret_common & ATTR_CMN_FILEID != 0 {
        file_id = u64_at(e, off);
        off += 8;
    }

    let mut mount_point = false;
    if ret_dir & ATTR_DIR_MOUNTSTATUS != 0 {
        mount_point = u32_at(e, off) & DIR_MNTSTATUS_MNTPOINT != 0;
        off += 4;
    }

    let mut links = 1u32;
    if ret_file & ATTR_FILE_LINKCOUNT != 0 {
        links = u32_at(e, off);
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
        progress.invalid_names.fetch_add(1, Ordering::Relaxed);
        progress.errors.fetch_add(1, Ordering::Relaxed);
        return false;
    }
    out.push(RawEntry {
        name: name.into(),
        is_dir,
        dataless: flags & SF_DATALESS != 0,
        mount_point,
        size,
        alloc,
        hardlink: (!is_dir && links > 1).then_some((dev, file_id)),
    });
    true
}

// ---- Parallel walk ----

struct Arena {
    nodes: Vec<Node>,
    /// Attribute an inode's bytes to its lexicographically first scanned path,
    /// independently of worker scheduling. This is accounting, not an estimate
    /// of how many bytes deleting any one of its links would reclaim.
    hardlinks: HashMap<(u32, u64), u32>,
}

impl Arena {
    fn path_parts(&self, mut i: u32) -> Vec<&str> {
        let mut parts = Vec::new();
        while i != NO_PARENT {
            let node = &self.nodes[i as usize];
            parts.push(node.name.as_ref());
            i = node.parent;
        }
        parts.reverse();
        parts
    }

    /// Called under the arena lock after inserting a file node, before totals
    /// are aggregated. Returns newly accounted bytes for the progress counter.
    fn account_file(&mut self, i: u32, hardlink: Option<(u32, u64)>) -> u64 {
        let Some(key) = hardlink else {
            return self.nodes[i as usize].alloc;
        };
        let Some(&previous) = self.hardlinks.get(&key) else {
            self.hardlinks.insert(key, i);
            return self.nodes[i as usize].alloc;
        };
        let loser = if self.path_parts(i) < self.path_parts(previous) {
            self.nodes[i as usize].size = self.nodes[previous as usize].size;
            self.nodes[i as usize].alloc = self.nodes[previous as usize].alloc;
            self.hardlinks.insert(key, i);
            previous
        } else {
            i
        };
        self.nodes[loser as usize].size = 0;
        self.nodes[loser as usize].alloc = 0;
        0
    }
}

struct Shared<'a> {
    arena: Mutex<Arena>,
    progress: &'a Progress,
}

fn walk<'s>(scope: &rayon::Scope<'s>, shared: &'s Shared<'s>, dir_path: PathBuf, dir_idx: u32) {
    let Some((entries, complete)) = read_dir_bulk(&dir_path, shared.progress) else {
        shared.arena.lock().unwrap().nodes[dir_idx as usize].complete = false;
        return;
    };
    if entries.is_empty() {
        if !complete {
            shared.arena.lock().unwrap().nodes[dir_idx as usize].complete = false;
        }
        return;
    }
    let mut n_files = 0u64;
    let mut n_dirs = 0u64;
    let mut bytes = 0u64;
    let mut subdirs = Vec::new();
    for (i, e) in entries.iter().enumerate() {
        if e.is_dir {
            n_dirs += 1;
            if e.mount_point {
                shared
                    .progress
                    .skipped_mount_points
                    .fetch_add(1, Ordering::Relaxed);
            } else if e.dataless {
                shared
                    .progress
                    .skipped_cloud_dirs
                    .fetch_add(1, Ordering::Relaxed);
            } else {
                subdirs.push((i as u32, dir_path.join(&*e.name)));
            }
        } else {
            n_files += 1;
        }
    }
    shared.progress.files.fetch_add(n_files, Ordering::Relaxed);
    shared.progress.dirs.fetch_add(n_dirs, Ordering::Relaxed);
    // Keep upstream's contiguous child batches and move names into the arena.
    let base = {
        let mut arena = shared.arena.lock().unwrap();
        arena.nodes[dir_idx as usize].complete = complete;
        let base = arena.nodes.len() as u32;
        let end = base + entries.len() as u32;
        debug_assert!(dir_idx < base);
        arena.nodes.reserve(entries.len());
        for e in entries {
            let index = arena.nodes.len() as u32;
            arena.nodes.push(Node {
                name: e.name,
                parent: dir_idx,
                size: e.size,
                alloc: e.alloc,
                is_dir: e.is_dir,
                complete: !e.is_dir || (!e.dataless && !e.mount_point),
                n_files: 0,
                children: 0..0,
            });
            if !e.is_dir {
                bytes += arena.account_file(index, e.hardlink);
            }
        }
        debug_assert_eq!(arena.nodes.len(), end as usize);
        arena.nodes[dir_idx as usize].children = base..end;
        base
    };
    shared.progress.bytes.fetch_add(bytes, Ordering::Relaxed);
    for (i, child_path) in subdirs {
        let child_idx = base + i;
        scope.spawn(move |s| walk(s, shared, child_path, child_idx));
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

const QOS_CLASS_USER_INITIATED: u32 = 0x19;

/// Rayon pool whose workers run at USER_INITIATED QoS. That still puts them
/// on the performance cores inside a GUI app (at the app's default QoS they
/// land on efficiency cores and scan twice as slowly), and it scans as fast
/// as USER_INTERACTIVE did, but it no longer outranks the UI and the system
/// compositor: at USER_INTERACTIVE a worker on every core made the window
/// (and screen recordings) skip frames for a quarter second mid-scan.
fn fast_pool() -> rayon::ThreadPool {
    rayon::ThreadPoolBuilder::new()
        .start_handler(|_| unsafe {
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
        })
        .build()
        .expect("thread pool")
}

/// Scan `root` and return the finished tree with aggregated subtree sizes.
pub fn scan(root: &Path, progress: &Progress) -> Scan {
    let root_name: Box<str> = root.to_string_lossy().into_owned().into_boxed_str();
    let arena = Mutex::new(Arena {
        nodes: vec![Node {
            name: root_name,
            parent: NO_PARENT,
            size: 0,
            alloc: 0,
            is_dir: true,
            complete: true,
            n_files: 0,
            children: 0..0,
        }],
        hardlinks: HashMap::new(),
    });
    let shared = Shared { arena, progress };

    use std::os::macos::fs::MetadataExt;
    let root_is_cloud_only =
        std::fs::symlink_metadata(root).is_ok_and(|m| m.st_flags() & SF_DATALESS != 0);
    if root_is_cloud_only {
        progress.skipped_cloud_dirs.fetch_add(1, Ordering::Relaxed);
        shared.arena.lock().unwrap().nodes[0].complete = false;
    } else {
        fast_pool().scope(|s| walk(s, &shared, root.to_path_buf(), 0));
    }

    let mut nodes = shared.arena.into_inner().unwrap().nodes;
    aggregate(&mut nodes);
    Scan {
        nodes,
        errors: progress.errors.load(Ordering::Relaxed),
    }
}

/// Count-only walk with no tree building: measures the pure syscall floor.
pub fn scan_count(root: &Path, progress: &Progress) {
    fn go<'s>(scope: &rayon::Scope<'s>, progress: &'s Progress, dir: PathBuf) {
        let Some((entries, _complete)) = read_dir_bulk(&dir, progress) else {
            return;
        };
        let mut n_files = 0u64;
        let mut n_dirs = 0u64;
        let mut bytes = 0u64;
        for e in entries {
            if e.is_dir {
                n_dirs += 1;
                if e.dataless || e.mount_point {
                    continue;
                }
                let p = dir.join(&*e.name);
                scope.spawn(move |s| go(s, progress, p));
            } else {
                n_files += 1;
                bytes += e.alloc;
            }
        }
        progress.files.fetch_add(n_files, Ordering::Relaxed);
        progress.dirs.fetch_add(n_dirs, Ordering::Relaxed);
        progress.bytes.fetch_add(bytes, Ordering::Relaxed);
    }
    rayon::scope(|s| go(s, progress, root.to_path_buf()));
}

/// Bottom-up subtree totals. Children always have higher indices than their
/// parent, so one reverse pass suffices.
fn aggregate(nodes: &mut [Node]) {
    for i in (1..nodes.len()).rev() {
        let parent = nodes[i].parent as usize;
        let (size, alloc, nf, complete) = {
            let n = &nodes[i];
            (
                n.size,
                n.alloc,
                if n.is_dir { n.n_files } else { 1 },
                n.complete,
            )
        };
        let p = &mut nodes[parent];
        p.size += size;
        p.alloc += alloc;
        p.n_files += nf;
        p.complete &= complete;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bulk_record(name: &str, is_dir: bool, flags: u32, mount_status: u32, links: u32) -> Vec<u8> {
        let mut e = vec![0u8; 4];
        let common = ATTR_CMN_RETURNED_ATTRS
            | ATTR_CMN_ERROR
            | ATTR_CMN_NAME
            | ATTR_CMN_DEVID
            | ATTR_CMN_OBJTYPE
            | ATTR_CMN_FLAGS
            | ATTR_CMN_FILEID;
        let dir = if is_dir { ATTR_DIR_MOUNTSTATUS } else { 0 };
        let file = if is_dir {
            0
        } else {
            ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE
        };
        for value in [common, 0, dir, file, 0, 0] {
            e.extend_from_slice(&value.to_le_bytes());
        }
        let name_ref = e.len();
        e.extend_from_slice(&[0u8; 8]);
        for value in [17u32, if is_dir { VDIR } else { 1 }, flags] {
            e.extend_from_slice(&value.to_le_bytes());
        }
        e.extend_from_slice(&123456u64.to_le_bytes());
        if is_dir {
            e.extend_from_slice(&mount_status.to_le_bytes());
        } else {
            e.extend_from_slice(&links.to_le_bytes());
            e.extend_from_slice(&12345i64.to_le_bytes());
            e.extend_from_slice(&16384i64.to_le_bytes());
        }
        let name_offset = (e.len() - name_ref) as u32;
        e[name_ref..name_ref + 4].copy_from_slice(&name_offset.to_le_bytes());
        e[name_ref + 4..name_ref + 8].copy_from_slice(&(name.len() as u32 + 1).to_le_bytes());
        e.extend_from_slice(name.as_bytes());
        e.push(0);
        let len = e.len() as u32;
        e[..4].copy_from_slice(&len.to_le_bytes());
        e
    }

    #[test]
    fn bulk_parser_preserves_cloud_mount_and_hardlink_metadata() {
        let mut entries = Vec::new();
        parse_entry(
            &bulk_record("cloud", true, SF_DATALESS, 0, 1),
            &mut entries,
            &Progress::default(),
        );
        parse_entry(
            &bulk_record("mounted", true, 0, DIR_MNTSTATUS_MNTPOINT, 1),
            &mut entries,
            &Progress::default(),
        );
        parse_entry(
            &bulk_record("linked-é", false, 0, 0, 2),
            &mut entries,
            &Progress::default(),
        );
        assert_eq!(entries.len(), 3);
        assert!(entries[0].is_dir && entries[0].dataless && !entries[0].mount_point);
        assert!(entries[1].is_dir && !entries[1].dataless && entries[1].mount_point);
        assert_eq!(&*entries[2].name, "linked-é");
        assert_eq!(entries[2].hardlink, Some((17, 123456)));
        assert_eq!((entries[2].size, entries[2].alloc), (12345, 16384));
    }

    #[test]
    fn scan_preserves_parent_links_empty_dirs_and_symlinks() {
        use std::os::unix::fs::symlink;
        let root = std::env::temp_dir().join(format!("bz-tree-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("nested/empty")).unwrap();
        std::fs::write(root.join("nested/document-é"), [7u8; 17]).unwrap();
        symlink(&root, root.join("loop")).unwrap();
        let result = scan(&root, &Progress::default());
        let _ = std::fs::remove_dir_all(&root);
        assert_eq!(result.errors, 0);
        assert_eq!(result.nodes.len(), 5, "directory symlinks are not followed");
        assert_eq!(result.nodes[0].n_files, 2);
        for (parent, node) in result.nodes.iter().enumerate() {
            for child in node.children.clone() {
                assert!(child as usize > parent);
                assert_eq!(result.nodes[child as usize].parent as usize, parent);
            }
        }
        let empty = result
            .nodes
            .iter()
            .find(|node| &*node.name == "empty")
            .unwrap();
        assert!(empty.is_dir && empty.children.is_empty());
        let file = result
            .nodes
            .iter()
            .find(|node| &*node.name == "document-é")
            .unwrap();
        assert_eq!(file.size, 17);
    }

    #[test]
    fn parallel_child_ranges_partition_wide_and_deep_tree() {
        let root = std::env::temp_dir().join(format!("bz-ranges-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let mut deep = root.clone();
        for depth in 1..=96 {
            deep.push("d");
            std::fs::create_dir(&deep).unwrap();
            std::fs::write(deep.join("data"), vec![1u8; depth]).unwrap();
        }
        for width in 0..64 {
            let dir = root.join(format!("wide-{width}"));
            std::fs::create_dir_all(dir.join("empty")).unwrap();
            std::fs::write(dir.join("data"), [1u8; 19]).unwrap();
        }
        let result = scan(&root, &Progress::default());
        let _ = std::fs::remove_dir_all(&root);
        assert_eq!(result.errors, 0);
        assert_eq!(result.nodes.len(), 385);
        assert_eq!(result.nodes[0].n_files, 160);
        assert_eq!(result.nodes[0].size, 5872);
        let mut seen = vec![false; result.nodes.len()];
        seen[0] = true;
        for (parent, node) in result.nodes.iter().enumerate() {
            if !node.is_dir {
                assert!(node.children.is_empty());
            }
            for child in node.children.clone() {
                let child = child as usize;
                assert!(
                    child > parent,
                    "aggregation requires parent-before-child order"
                );
                assert!(!seen[child], "a child belongs to exactly one directory");
                seen[child] = true;
                assert_eq!(result.nodes[child].parent as usize, parent);
            }
        }
        assert!(
            seen.iter().all(|&visited| visited),
            "every node is reachable"
        );
    }

    fn node(name: &str, parent: u32, is_dir: bool) -> Node {
        Node {
            name: name.into(),
            parent,
            size: if is_dir { 0 } else { 8192 },
            alloc: if is_dir { 0 } else { 4096 },
            is_dir,
            complete: true,
            n_files: 0,
            children: 0..0,
        }
    }

    #[test]
    fn hardlink_owner_does_not_depend_on_discovery_order() {
        for order in [[3, 4, 5], [5, 3, 4], [4, 5, 3]] {
            let mut arena = Arena {
                nodes: vec![
                    node("/root", NO_PARENT, true),
                    node("a", 0, true),
                    node("z", 0, true),
                    node("a", 2, false),
                    node("z", 1, false),
                    node("y", 1, false),
                ],
                hardlinks: HashMap::new(),
            };
            let added: u64 = order
                .into_iter()
                .map(|i| arena.account_file(i, Some((7, 42))))
                .sum();
            assert_eq!(added, 4096, "progress counts the inode once");
            assert_eq!(arena.nodes[3].alloc, 0); // /root/z/a
            assert_eq!(arena.nodes[4].alloc, 0); // /root/a/z
            assert_eq!(arena.nodes[5].alloc, 4096); // /root/a/y wins every time
            assert_eq!(arena.nodes[5].size, 8192);
            aggregate(&mut arena.nodes);
            assert_eq!(arena.nodes[0].alloc, 4096);
            assert_eq!(arena.nodes[0].size, 8192);
            assert_eq!(arena.nodes[0].n_files, 3);
        }
    }

    #[test]
    fn incomplete_subtrees_propagate_without_hiding_healthy_siblings() {
        let mut nodes = vec![
            node("/root", NO_PARENT, true),
            node("partial", 0, true),
            node("healthy", 0, true),
            node("unreadable-or-skipped", 1, true),
            node("file", 2, false),
        ];
        nodes[3].complete = false;
        aggregate(&mut nodes);
        assert!(!nodes[0].complete);
        assert!(!nodes[1].complete);
        assert!(nodes[2].complete);
        assert_eq!(
            nodes[0].alloc, 4096,
            "partial scans still expose observed bytes"
        );
    }

    #[test]
    fn entry_errors_are_reported_instead_of_silently_dropped() {
        let mut bytes = vec![0u8; 28];
        bytes[4..8].copy_from_slice(&ATTR_CMN_ERROR.to_le_bytes());
        bytes[24..28].copy_from_slice(&(libc::EACCES as u32).to_le_bytes());
        let progress = Progress::default();
        let mut entries = Vec::new();
        parse_entry(&bytes, &mut entries, &progress);
        assert!(entries.is_empty());
        assert_eq!(progress.errors.load(Ordering::Relaxed), 1);
        assert_eq!(progress.entry_errors.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn invalid_utf8_is_not_replaced_with_an_actionable_path() {
        let mut bytes = vec![0u8; 34];
        bytes[4..8].copy_from_slice(&ATTR_CMN_NAME.to_le_bytes());
        bytes[24..28].copy_from_slice(&8u32.to_le_bytes());
        bytes[28..32].copy_from_slice(&2u32.to_le_bytes());
        bytes[32] = 0xff;
        let progress = Progress::default();
        let mut entries = Vec::new();
        parse_entry(&bytes, &mut entries, &progress);
        assert!(entries.is_empty());
        assert_eq!(progress.errors.load(Ordering::Relaxed), 1);
        assert_eq!(progress.invalid_names.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn hardlinks_count_once() {
        let root = std::env::temp_dir().join(format!("bz-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("sub")).unwrap();
        std::fs::write(root.join("file"), vec![7u8; 1 << 20]).unwrap();
        std::fs::hard_link(root.join("file"), root.join("sub/link")).unwrap();

        let result = scan(&root, &Progress::default());
        let _ = std::fs::remove_dir_all(&root);

        let tree = &result.nodes[0];
        assert_eq!(tree.n_files, 2, "both names are listed");
        assert_eq!(tree.size, 1 << 20, "but the bytes count once");
    }
}
