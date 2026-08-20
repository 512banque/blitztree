//! searchfs(2) whole-volume catalog scan — the closest macOS analog to
//! WizTree's NTFS MFT read. The kernel iterates the filesystem catalog
//! directly; we never open() a single directory. Entries arrive flat
//! (with parent object IDs) and the tree is reconstructed afterwards.

use std::ffi::{c_char, c_int, c_uint, c_ulong, c_void, CString};
use std::path::Path;
use std::sync::atomic::Ordering;

use crate::Progress;

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

#[repr(C)]
struct FsSearchBlock {
    returnattrs: *mut AttrList,
    returnbuffer: *mut c_void,
    returnbuffersize: usize,
    maxmatches: c_ulong,
    timelimit: libc::timeval,
    searchparams1: *mut c_void,
    sizeofsearchparams1: usize,
    searchparams2: *mut c_void,
    sizeofsearchparams2: usize,
    searchattrs: AttrList,
}

#[repr(C)]
struct SearchState {
    reserved: [u8; 556],
}

// packed_name_attr: leading size u32, attrreference, then the name bytes.
#[repr(C)]
struct PackedNameAttr {
    size: u32,
    attr_off: i32,
    attr_len: u32,
    name: [u8; 4],
}

#[repr(C)]
struct PackedAttrRef {
    size: u32,
    attr_off: i32,
    attr_len: u32,
}

extern "C" {
    fn searchfs(
        path: *const c_char,
        searchblock: *mut FsSearchBlock,
        nummatches: *mut c_ulong,
        scriptcode: c_uint,
        options: c_uint,
        state: *mut SearchState,
    ) -> c_int;
}

const ATTR_BIT_MAP_COUNT: u16 = 5;
const ATTR_CMN_NAME: u32 = 0x0000_0001;
const ATTR_CMN_OBJTYPE: u32 = 0x0000_0008;
const ATTR_CMN_OBJID: u32 = 0x0000_0020;
const ATTR_CMN_PAROBJID: u32 = 0x0000_0080;
const ATTR_FILE_TOTALSIZE: u32 = 0x0000_0002;
const ATTR_FILE_ALLOCSIZE: u32 = 0x0000_0004;

const SRCHFS_START: c_uint = 0x0000_0001;
const SRCHFS_MATCHPARTIALNAMES: c_uint = 0x0000_0002;
const SRCHFS_MATCHDIRS: c_uint = 0x0000_0004;
const SRCHFS_MATCHFILES: c_uint = 0x0000_0008;

const VDIR: u32 = 2;

const RESULT_BUF: usize = 4 * 1024 * 1024;

pub struct CatEntry {
    pub name: Box<str>,
    pub obj_id: u32,
    pub parent_id: u32,
    pub is_dir: bool,
    pub size: u64,
    pub alloc: u64,
}

fn u32_at(b: &[u8], off: usize) -> u32 {
    u32::from_le_bytes(b[off..off + 4].try_into().unwrap())
}
fn u64_at(b: &[u8], off: usize) -> u64 {
    u64::from_le_bytes(b[off..off + 8].try_into().unwrap())
}

/// Dump the entire catalog of the volume mounted at `vol_path`.
pub fn catalog_dump(vol_path: &Path, progress: &Progress) -> std::io::Result<Vec<CatEntry>> {
    let cpath = CString::new(vol_path.as_os_str().as_encoded_bytes()).unwrap();

    let mut returnattrs = AttrList {
        bitmapcount: ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_OBJID | ATTR_CMN_PAROBJID,
        volattr: 0,
        dirattr: 0,
        fileattr: ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE,
        forkattr: 0,
    };

    // Match-all: partial-name match against the empty (NUL-only) string.
    let mut name_param = PackedNameAttr {
        size: 8 + 1, // attrreference + 1 byte of name (the NUL)
        attr_off: 8, // name data starts right after the attrreference
        attr_len: 1,
        name: [0u8; 4],
    };
    let mut param2 = PackedAttrRef {
        size: 8,
        attr_off: 8,
        attr_len: 0,
    };

    let mut result_buf = vec![0u8; RESULT_BUF];
    let mut state = SearchState { reserved: [0u8; 556] };
    let mut entries: Vec<CatEntry> = Vec::with_capacity(1 << 21);

    let mut options =
        SRCHFS_START | SRCHFS_MATCHPARTIALNAMES | SRCHFS_MATCHDIRS | SRCHFS_MATCHFILES;
    let mut ebusy_retries = 0;

    loop {
        let mut block = FsSearchBlock {
            returnattrs: &mut returnattrs,
            returnbuffer: result_buf.as_mut_ptr() as *mut c_void,
            returnbuffersize: RESULT_BUF,
            maxmatches: 1_000_000,
            timelimit: libc::timeval { tv_sec: 5, tv_usec: 0 },
            searchparams1: &mut name_param as *mut PackedNameAttr as *mut c_void,
            sizeofsearchparams1: (name_param.size + 4) as usize,
            searchparams2: &mut param2 as *mut PackedAttrRef as *mut c_void,
            sizeofsearchparams2: std::mem::size_of::<PackedAttrRef>(),
            searchattrs: AttrList {
                bitmapcount: ATTR_BIT_MAP_COUNT,
                reserved: 0,
                commonattr: ATTR_CMN_NAME,
                volattr: 0,
                dirattr: 0,
                fileattr: 0,
                forkattr: 0,
            },
        };

        let mut nummatches: c_ulong = 0;
        let rc = unsafe {
            searchfs(
                cpath.as_ptr(),
                &mut block,
                &mut nummatches,
                0,
                options,
                &mut state,
            )
        };
        let err = if rc == 0 {
            0
        } else {
            std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
        };
        options &= !SRCHFS_START;

        if (err == 0 || err == libc::EAGAIN) && nummatches > 0 {
            parse_matches(&result_buf, nummatches as usize, &mut entries, progress);
        }

        match err {
            0 => break,
            libc::EAGAIN => continue,
            libc::EBUSY if ebusy_retries < 5 => {
                // catalog changed mid-search: restart from scratch
                ebusy_retries += 1;
                entries.clear();
                options |= SRCHFS_START;
                continue;
            }
            e => return Err(std::io::Error::from_raw_os_error(e)),
        }
    }
    Ok(entries)
}

/// Result records hold the requested attrs in canonical order:
/// NAME (attrreference), OBJTYPE, OBJID, PAROBJID, then file sizes.
fn parse_matches(buf: &[u8], n: usize, out: &mut Vec<CatEntry>, progress: &Progress) {
    let mut off = 0usize;
    for _ in 0..n {
        let rec = &buf[off..];
        let len = u32_at(rec, 0) as usize;
        let mut p = 4usize;

        let name_off = u32_at(rec, p) as i32 as isize;
        let name_len = u32_at(rec, p + 4) as usize;
        let nstart = (p as isize + name_off) as usize;
        let name = std::str::from_utf8(&rec[nstart..nstart + name_len.saturating_sub(1)])
            .unwrap_or("")
            .to_owned();
        p += 8;

        let objtype = u32_at(rec, p);
        p += 4;
        let is_dir = objtype == VDIR;

        let obj_id = u32_at(rec, p); // fsobj_id_t.fid_objno
        p += 8;
        let parent_id = u32_at(rec, p);
        p += 8;

        let mut size = 0u64;
        let mut alloc = 0u64;
        if !is_dir && p + 16 <= len {
            size = u64_at(rec, p);
            alloc = u64_at(rec, p + 8);
        }

        if is_dir {
            progress.dirs.fetch_add(1, Ordering::Relaxed);
        } else {
            progress.files.fetch_add(1, Ordering::Relaxed);
            progress.bytes.fetch_add(alloc, Ordering::Relaxed);
        }
        out.push(CatEntry {
            name: name.into_boxed_str(),
            obj_id,
            parent_id,
            is_dir,
            size,
            alloc,
        });
        off += len;
    }
}
