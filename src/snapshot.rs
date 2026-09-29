//! Versioned, read-only snapshots and comparisons.
//!
//! A snapshot contains one entry for every directory in a finished scan.  It
//! deliberately does not contain files or a top-K view: the complete directory
//! inventory is what makes two runs comparable without doing another scan.

use crate::{Tree, NO_PARENT};
use serde_json::{json, Map, Value};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs::OpenOptions;
use std::io::{self, Write};
use std::path::{Component, Path, PathBuf};

pub const SCHEMA_VERSION: u64 = 1;
pub const DEFAULT_LIMIT: usize = 100;
pub const MAX_LIMIT: usize = 1_000;
pub const MAX_SNAPSHOT_BYTES: usize = 64 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
struct Coverage {
    complete: bool,
    errors: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Entry {
    path: String,
    allocated_bytes: u64,
    logical_bytes: u64,
    complete: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Snapshot {
    root: String,
    generated_at_unix: u64,
    coverage: Coverage,
    entries: Vec<Entry>,
}

#[derive(Clone, Debug)]
struct Change {
    path: String,
    before_bytes: Option<u64>,
    after_bytes: Option<u64>,
    delta_bytes: Option<i128>,
    status: &'static str,
}

/// Normalize an absolute path lexically, without resolving symlinks or
/// opening any directory.  The CLI passes a path resolved by its no-cloud
/// policy; the FFI uses this helper because a GUI snapshot must not start a
/// second filesystem walk just to write its root name.  Parent components are
/// rejected before normalization because a symlink can make the kernel resolve
/// `a/../b` differently from lexical path processing.
pub fn normalize_root(root: &Path) -> Result<String, String> {
    let absolute = if root.is_absolute() {
        root.to_owned()
    } else {
        std::env::current_dir()
            .map_err(|e| format!("Cannot resolve snapshot root: {e}"))?
            .join(root)
    };
    let mut normalized = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::Prefix(_) => {
                return Err("Snapshot root has an unsupported path prefix".into())
            }
            Component::RootDir => normalized.push("/"),
            Component::CurDir => {}
            Component::ParentDir => {
                return Err("Snapshot root cannot contain '..' components".into());
            }
            Component::Normal(part) => normalized.push(part),
        }
    }
    let text = normalized
        .to_str()
        .ok_or_else(|| "Snapshot root must be a UTF-8 path".to_string())?;
    if text.is_empty() || !text.starts_with('/') || text.as_bytes().contains(&0) {
        return Err("Snapshot root must be an absolute path".into());
    }
    Ok(text.to_string())
}

struct BoundedJsonWriter {
    bytes: Vec<u8>,
    exceeded: bool,
}

impl BoundedJsonWriter {
    fn new() -> Self {
        Self {
            bytes: Vec::new(),
            exceeded: false,
        }
    }
}

impl Write for BoundedJsonWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let remaining = MAX_SNAPSHOT_BYTES.saturating_sub(self.bytes.len());
        if bytes.len() > remaining {
            self.exceeded = true;
            return Err(io::Error::new(
                io::ErrorKind::WriteZero,
                "snapshot exceeds 64 MiB",
            ));
        }
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Serialize a snapshot JSON value without ever producing more than the
/// public 64 MiB payload limit.  The same bound is used by the CLI and C/Swift
/// bridge so a large tree cannot be copied into an unbounded JSON string.
pub fn serialize_bounded(value: &Value) -> Result<String, String> {
    let mut writer = BoundedJsonWriter::new();
    let result = serde_json::to_writer(&mut writer, value);
    if writer.exceeded {
        return Err("Snapshot is larger than 64 MiB".into());
    }
    result.map_err(|e| format!("Cannot serialize snapshot: {e}"))?;
    String::from_utf8(writer.bytes)
        .map_err(|_| "Serialized snapshot is not valid UTF-8".to_string())
}

fn validate_canonical_root(root: &str) -> Result<(), String> {
    if root.is_empty() || root.as_bytes().contains(&0) {
        return Err("Snapshot root must be a non-empty absolute path".into());
    }
    let path = Path::new(root);
    if !path.is_absolute() {
        return Err("Snapshot root must be absolute".into());
    }
    let normalized = normalize_root(path)?;
    if normalized != root {
        return Err("Snapshot root must be canonical and normalized".into());
    }
    Ok(())
}

fn field<'a>(object: &'a Map<String, Value>, name: &str) -> Result<&'a Value, String> {
    object
        .get(name)
        .ok_or_else(|| format!("Snapshot is missing {name}"))
}

fn string_field(object: &Map<String, Value>, name: &str) -> Result<String, String> {
    field(object, name)?
        .as_str()
        .map(ToOwned::to_owned)
        .ok_or_else(|| format!("Snapshot field {name} must be a string"))
}

fn bool_field(object: &Map<String, Value>, name: &str) -> Result<bool, String> {
    field(object, name)?
        .as_bool()
        .ok_or_else(|| format!("Snapshot field {name} must be a boolean"))
}

fn u64_field(object: &Map<String, Value>, name: &str) -> Result<u64, String> {
    field(object, name)?
        .as_u64()
        .ok_or_else(|| format!("Snapshot field {name} must be an unsigned integer"))
}

fn validate_relative_path(path: &str) -> Result<(), String> {
    if path == "." {
        return Ok(());
    }
    if path.is_empty() || path.starts_with('/') || path.ends_with('/') || path.contains('\0') {
        return Err(format!("Invalid snapshot entry path: {path:?}"));
    }
    let mut saw_component = false;
    for component in path.split('/') {
        saw_component = true;
        if component.is_empty() || component == "." || component == ".." {
            return Err(format!("Invalid snapshot entry path: {path:?}"));
        }
    }
    if !saw_component {
        return Err(format!("Invalid snapshot entry path: {path:?}"));
    }
    Ok(())
}

fn parent_path(path: &str) -> &str {
    path.rsplit_once('/').map_or(".", |(parent, _)| parent)
}

fn parse_snapshot(value: &Value) -> Result<Snapshot, String> {
    let object = value
        .as_object()
        .ok_or_else(|| "Snapshot must be a JSON object".to_string())?;
    if field(object, "kind")?.as_str() != Some("blitztree_snapshot") {
        return Err("Snapshot kind must be blitztree_snapshot".into());
    }
    if field(object, "schema_version")?.as_u64() != Some(SCHEMA_VERSION) {
        return Err("Unsupported snapshot schema_version".into());
    }
    let root = string_field(object, "root")?;
    validate_canonical_root(&root)?;
    let generated_at_unix = u64_field(object, "generated_at_unix")?;

    let coverage_object = field(object, "coverage")?
        .as_object()
        .ok_or_else(|| "Snapshot coverage must be an object".to_string())?;
    let coverage = Coverage {
        complete: bool_field(coverage_object, "complete")?,
        errors: u64_field(coverage_object, "errors")?,
    };
    if coverage.complete && coverage.errors != 0 {
        return Err("Snapshot coverage cannot be complete with errors".into());
    }

    let values = field(object, "entries")?
        .as_array()
        .ok_or_else(|| "Snapshot entries must be an array".to_string())?;
    if values.is_empty() {
        return Err("Snapshot entries must include the root directory".into());
    }
    let mut entries = Vec::with_capacity(values.len());
    let mut paths = HashSet::with_capacity(values.len());
    for value in values {
        let entry_object = value
            .as_object()
            .ok_or_else(|| "Snapshot entry must be an object".to_string())?;
        let path = string_field(entry_object, "path")?;
        validate_relative_path(&path)?;
        if !paths.insert(path.clone()) {
            return Err("Snapshot entries contain a duplicate path".into());
        }
        entries.push(Entry {
            path,
            allocated_bytes: u64_field(entry_object, "allocated_bytes")?,
            logical_bytes: u64_field(entry_object, "logical_bytes")?,
            complete: bool_field(entry_object, "complete")?,
        });
    }
    if !paths.contains(".") {
        return Err("Snapshot entries must include path '.' for the root".into());
    }
    let complete_by_path: HashMap<_, _> = entries
        .iter()
        .map(|entry| (entry.path.as_str(), entry.complete))
        .collect();
    let root_complete = *complete_by_path
        .get(".")
        .ok_or_else(|| "Snapshot entries must include path '.' for the root".to_string())?;
    if root_complete != coverage.complete {
        return Err("Snapshot root completeness disagrees with coverage.complete".into());
    }
    for entry in &entries {
        if entry.path != "." && !paths.contains(parent_path(&entry.path)) {
            return Err(format!(
                "Snapshot entry {} has no recorded ancestor",
                entry.path
            ));
        }
        if entry.path != "." {
            let Some(&parent_complete) = complete_by_path.get(parent_path(&entry.path)) else {
                return Err(format!(
                    "Snapshot entry {} has no recorded ancestor",
                    entry.path
                ));
            };
            if parent_complete && !entry.complete {
                return Err(format!(
                    "Snapshot entry {} is incomplete below a complete ancestor",
                    entry.path
                ));
            }
        }
    }
    entries.sort_unstable_by(|a, b| a.path.cmp(&b.path));
    Ok(Snapshot {
        root,
        generated_at_unix,
        coverage,
        entries,
    })
}

fn checked_tree_shape(tree: &Tree) -> Result<(), String> {
    let n = tree.len();
    if n == 0 {
        return Err("Cannot snapshot an empty tree".into());
    }
    if tree.parents.len() != n
        || tree.alloc.len() != n
        || tree.logical.len() != n
        || tree.flags.len() != n
        || tree.complete.len() != n
        || tree.name_off.len() != n + 1
    {
        return Err("Scan tree has inconsistent arrays".into());
    }
    if tree.parents[0] != NO_PARENT || tree.flags[0] & 1 == 0 {
        return Err("Scan tree has an invalid root".into());
    }
    if tree.name_off.windows(2).any(|w| w[0] > w[1])
        || tree.name_off.last().copied().unwrap_or(0) as usize > tree.name_blob.len()
    {
        return Err("Scan tree has invalid names".into());
    }
    Ok(())
}

fn safe_tree_name<'a>(tree: &'a Tree, i: usize) -> Result<&'a str, String> {
    let start = *tree
        .name_off
        .get(i)
        .ok_or_else(|| "Scan tree has an invalid name offset".to_string())?
        as usize;
    let end = *tree
        .name_off
        .get(i + 1)
        .ok_or_else(|| "Scan tree has an invalid name offset".to_string())? as usize;
    let bytes = tree
        .name_blob
        .get(start..end)
        .ok_or_else(|| "Scan tree has an invalid name range".to_string())?;
    std::str::from_utf8(bytes).map_err(|_| "Scan tree contains a non-UTF-8 name".into())
}

fn tree_relative_path(tree: &Tree, node: usize) -> Result<String, String> {
    let mut current = node;
    let mut components = Vec::new();
    let mut visited = HashSet::new();
    while current != 0 {
        if !visited.insert(current) {
            return Err("Scan tree contains a parent cycle".into());
        }
        let parent = *tree
            .parents
            .get(current)
            .ok_or_else(|| "Scan tree contains an invalid parent".to_string())?;
        if parent == NO_PARENT || parent as usize >= tree.len() {
            return Err("Scan tree contains a disconnected node".into());
        }
        if tree.flags[parent as usize] & 1 == 0 {
            return Err("Scan tree has a file as a directory parent".into());
        }
        let name = safe_tree_name(tree, current)?;
        if name.is_empty()
            || name == "."
            || name == ".."
            || name.contains('/')
            || name.contains('\0')
        {
            return Err("Scan tree contains an invalid directory name".into());
        }
        components.push(name);
        current = parent as usize;
    }
    components.reverse();
    Ok(if components.is_empty() {
        ".".into()
    } else {
        components.join("/")
    })
}

/// Build a version-1 snapshot from a finished scan.  `root` must already be
/// the path selected by the caller's no-cloud root policy; this function only
/// normalizes it lexically and never opens it.
pub fn snapshot_value(
    root: &Path,
    tree: &Tree,
    generated_at_unix: u64,
    errors: u64,
) -> Result<Value, String> {
    checked_tree_shape(tree)?;
    let root = normalize_root(root)?;
    let mut entries = Vec::new();
    let mut paths = HashSet::new();
    for i in 0..tree.len() {
        if tree.flags[i] & 1 == 0 {
            continue;
        }
        let path = tree_relative_path(tree, i)?;
        if !paths.insert(path.clone()) {
            return Err("Scan tree contains duplicate directory paths".into());
        }
        entries.push(json!({
            "path": path,
            "allocated_bytes": tree.alloc[i],
            "logical_bytes": tree.logical[i],
            "complete": tree.complete[i],
        }));
    }
    entries.sort_unstable_by(|a, b| {
        a.get("path")
            .and_then(Value::as_str)
            .cmp(&b.get("path").and_then(Value::as_str))
    });
    Ok(json!({
        "kind": "blitztree_snapshot",
        "schema_version": SCHEMA_VERSION,
        "root": root,
        "generated_at_unix": generated_at_unix,
        "coverage": {"complete": tree.complete[0], "errors": errors},
        "entries": entries,
    }))
}

fn validate_limit(limit: usize) -> Result<usize, String> {
    if !(1..=MAX_LIMIT).contains(&limit) {
        return Err(format!("limit must be between 1 and {MAX_LIMIT}"));
    }
    Ok(limit)
}

fn certified_absence(entries: &HashMap<String, &Entry>, path: &str) -> bool {
    let mut parent = parent_path(path);
    loop {
        let Some(entry) = entries.get(parent) else {
            if parent == "." {
                return false;
            }
            parent = parent_path(parent);
            continue;
        };
        return entry.complete;
    }
}

fn signed_delta(before: u64, after: u64) -> i128 {
    i128::from(after) - i128::from(before)
}

fn status_for_delta(delta: i128) -> Option<&'static str> {
    if delta > 0 {
        Some("grew")
    } else if delta < 0 {
        Some("shrunk")
    } else {
        None
    }
}

/// Compare two parsed snapshot JSON objects.  Changes are path-sorted and
/// limited after all certainty checks, so an uncertain entry cannot be hidden
/// by an early size-only filter.
pub fn compare_snapshot_values(
    before_value: &Value,
    after_value: &Value,
    limit: usize,
) -> Result<Value, String> {
    let limit = validate_limit(limit)?;
    let before = parse_snapshot(before_value)?;
    let after = parse_snapshot(after_value)?;
    if before.root != after.root {
        return Err("Snapshots have different roots".into());
    }

    let before_map: HashMap<_, _> = before.entries.iter().map(|e| (e.path.clone(), e)).collect();
    let after_map: HashMap<_, _> = after.entries.iter().map(|e| (e.path.clone(), e)).collect();
    let mut paths = BTreeSet::new();
    paths.extend(before_map.keys().cloned());
    paths.extend(after_map.keys().cloned());

    let mut changes = Vec::new();
    for path in paths {
        // The root totals are carried by the top-level before/after and
        // total_delta_bytes fields.  Listing "." as a change would dominate
        // every child and make the limited table much less useful.
        if path == "." {
            continue;
        }
        let old = before_map.get(&path).copied();
        let new = after_map.get(&path).copied();
        let old_bytes = old.map(|e| e.allocated_bytes);
        let new_bytes = new.map(|e| e.allocated_bytes);
        let (delta, status) = match (old, new) {
            (Some(old), Some(new)) if old.complete && new.complete => {
                let delta = signed_delta(old.allocated_bytes, new.allocated_bytes);
                (Some(delta), status_for_delta(delta))
            }
            (Some(old), None) if old.complete && certified_absence(&after_map, &path) => {
                let delta = -i128::from(old.allocated_bytes);
                (Some(delta), Some("removed"))
            }
            (None, Some(new)) if new.complete && certified_absence(&before_map, &path) => {
                let delta = i128::from(new.allocated_bytes);
                (Some(delta), Some("added"))
            }
            _ => (None, Some("uncertain")),
        };
        let Some(status) = status else { continue };
        changes.push(Change {
            path,
            before_bytes: old_bytes,
            after_bytes: new_bytes,
            delta_bytes: delta,
            status,
        });
    }
    let total_delta = before_map
        .get(".")
        .zip(after_map.get("."))
        .map(|(old, new)| signed_delta(old.allocated_bytes, new.allocated_bytes))
        .ok_or_else(|| "Snapshots must include the root directory".to_string())?;
    let complete = before.coverage.complete && after.coverage.complete;
    changes.sort_by(|a, b| {
        let rank = |change: &Change| match change.delta_bytes {
            Some(delta) if delta > 0 => 0,
            Some(_) => 1,
            None => 2,
        };
        rank(a)
            .cmp(&rank(b))
            .then_with(|| match (a.delta_bytes, b.delta_bytes) {
                (Some(a), Some(b)) => b.cmp(&a),
                _ => std::cmp::Ordering::Equal,
            })
            .then_with(|| a.path.cmp(&b.path))
    });
    let total_changes = changes.len();
    changes.truncate(limit);
    let changes: Vec<Value> = changes
        .into_iter()
        .map(|change| {
            json!({
                "path": change.path,
                "before_bytes": change.before_bytes,
                "after_bytes": change.after_bytes,
                "delta_bytes": change.delta_bytes,
                "status": change.status,
            })
        })
        .collect();
    let before_bytes = before_map.get(".").map(|entry| entry.allocated_bytes);
    let after_bytes = after_map.get(".").map(|entry| entry.allocated_bytes);
    Ok(json!({
        "kind": "blitztree_comparison",
        "schema_version": SCHEMA_VERSION,
        "root": before.root,
        "before_generated_at_unix": before.generated_at_unix,
        "after_generated_at_unix": after.generated_at_unix,
        "complete": complete,
        "before_bytes": before_bytes,
        "after_bytes": after_bytes,
        "total_delta_bytes": if complete { json!(total_delta) } else { Value::Null },
        "total_changes": total_changes,
        "changes": changes,
    }))
}

pub fn compare_snapshot_json(before: &str, after: &str, limit: usize) -> Result<Value, String> {
    let before: Value =
        serde_json::from_str(before).map_err(|e| format!("Invalid before snapshot JSON: {e}"))?;
    let after: Value =
        serde_json::from_str(after).map_err(|e| format!("Invalid after snapshot JSON: {e}"))?;
    compare_snapshot_values(&before, &after, limit)
}

/// Save a snapshot with exclusive creation and owner-only permissions.  The
/// caller supplies the complete JSON text, so this helper is also used by the
/// FFI and CLI and cannot accidentally rescan or overwrite an old baseline.
pub fn save_exclusive(path: &Path, text: &str) -> Result<(), String> {
    if text.len() > MAX_SNAPSHOT_BYTES {
        return Err("Snapshot is larger than 64 MiB".into());
    }
    #[cfg(unix)]
    use std::os::unix::fs::OpenOptionsExt;
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(0o600);
    let mut file = options
        .open(path)
        .map_err(|e| format!("Cannot create {}: {e}", path.display()))?;
    file.write_all(text.as_bytes())
        .and_then(|_| file.sync_all())
        .map_err(|e| format!("Cannot write {}: {e}", path.display()))?;
    Ok(())
}

pub fn snapshot_entry_count(value: &Value) -> Result<usize, String> {
    Ok(parse_snapshot(value)?.entries.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Tree;
    use std::fs;

    fn tree(root: &str, entries: &[(&str, u64, bool)]) -> Tree {
        let mut tree = Tree::with_root(root);
        for (path, bytes, complete) in entries {
            let mut parent = 0;
            for (depth, name) in path.split('/').enumerate() {
                let existing = tree
                    .parents
                    .iter()
                    .enumerate()
                    .skip(1)
                    .find(|&(i, &p)| p == parent && tree.name(i) == name)
                    .map(|(i, _)| i as u32);
                parent = if let Some(i) = existing {
                    i
                } else {
                    tree.push(name, parent, 0, 0, true)
                };
                if depth + 1 == path.split('/').count() {
                    tree.alloc[parent as usize] = *bytes;
                    tree.logical[parent as usize] = *bytes;
                    tree.complete[parent as usize] = *complete;
                }
            }
        }
        tree.alloc[0] = entries.iter().map(|(_, bytes, _)| bytes).sum();
        tree.logical[0] = tree.alloc[0];
        tree.link_children();
        tree
    }

    fn snapshot(root: &str, entries: &[(&str, u64, bool)], complete: bool) -> Value {
        let mut value = snapshot_value(
            Path::new(root),
            &tree(root, entries),
            10,
            u64::from(!complete),
        )
        .unwrap();
        value["coverage"]["complete"] = json!(complete);
        value
    }

    #[test]
    fn snapshot_contains_only_directories_and_root_relative_paths() {
        let value = snapshot_value(
            Path::new("/Users/test"),
            &tree("/Users/test", &[("a/b", 42, true)]),
            12,
            0,
        )
        .unwrap();
        assert_eq!(value["kind"], "blitztree_snapshot");
        assert_eq!(value["entries"][0]["path"], ".");
        assert!(value["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v["path"] == "a"));
        assert!(value["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v["path"] == "a/b"));
    }

    #[test]
    fn growth_and_certified_add_remove_are_signed() {
        let before = snapshot("/root", &[("a", 100, true), ("gone", 50, true)], true);
        let after = snapshot("/root", &[("a", 160, true), ("new", 20, true)], true);
        let diff = compare_snapshot_values(&before, &after, 100).unwrap();
        assert_eq!(diff["total_delta_bytes"], 30);
        assert_eq!(diff["before_bytes"], 150);
        assert_eq!(diff["after_bytes"], 180);
        let changes = diff["changes"].as_array().unwrap();
        assert!(changes
            .iter()
            .any(|v| v["path"] == "a" && v["status"] == "grew" && v["delta_bytes"] == 60));
        assert!(changes
            .iter()
            .any(|v| v["path"] == "gone" && v["status"] == "removed" && v["delta_bytes"] == -50));
        assert!(changes
            .iter()
            .any(|v| v["path"] == "new" && v["status"] == "added" && v["delta_bytes"] == 20));
        assert_eq!(changes[0]["path"], "a");
        assert_eq!(diff["total_changes"], 3);
        assert!(!changes.iter().any(|v| v["path"] == "."));
    }

    #[test]
    fn incomplete_entries_do_not_claim_a_delta_or_disappearance() {
        let before = snapshot("/root", &[("a", 100, true), ("gone", 50, true)], true);
        let mut after = snapshot("/root", &[("a", 160, true)], false);
        after["entries"] = json!([{
            "path": ".", "allocated_bytes": 160, "logical_bytes": 160, "complete": false
        }, {
            "path": "a", "allocated_bytes": 160, "logical_bytes": 160, "complete": true
        }]);
        let diff = compare_snapshot_values(&before, &after, 100).unwrap();
        assert!(!diff["complete"].as_bool().unwrap());
        assert!(diff["total_delta_bytes"].is_null());
        let gone = diff["changes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["path"] == "gone")
            .unwrap();
        assert_eq!(gone["status"], "uncertain");
        assert!(gone["delta_bytes"].is_null());
        let a = diff["changes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["path"] == "a")
            .unwrap();
        assert_eq!(a["status"], "grew");
        assert_eq!(a["delta_bytes"], 60);
    }

    #[test]
    fn malformed_paths_duplicates_and_roots_are_rejected() {
        let base = json!({
            "kind": "blitztree_snapshot", "schema_version": 1, "root": "/root",
            "generated_at_unix": 1, "coverage": {"complete": true, "errors": 0},
            "entries": [{"path": ".", "allocated_bytes": 0, "logical_bytes": 0, "complete": true}]
        });
        for path in ["/absolute", "a/../b", "a//b"] {
            let mut value = base.clone();
            value["entries"] = json!([{"path": path, "allocated_bytes": 0, "logical_bytes": 0, "complete": true}, {"path": ".", "allocated_bytes": 0, "logical_bytes": 0, "complete": true}]);
            assert!(parse_snapshot(&value).is_err(), "accepted {path}");
        }
        let mut duplicate = base.clone();
        duplicate["entries"] = json!([
            {"path": ".", "allocated_bytes": 0, "logical_bytes": 0, "complete": true},
            {"path": ".", "allocated_bytes": 0, "logical_bytes": 0, "complete": true}
        ]);
        assert!(parse_snapshot(&duplicate).is_err());
        let mut missing_parent = base;
        missing_parent["entries"] = json!([
            {"path": ".", "allocated_bytes": 0, "logical_bytes": 0, "complete": true},
            {"path": "a/b", "allocated_bytes": 0, "logical_bytes": 0, "complete": true}
        ]);
        assert!(parse_snapshot(&missing_parent).is_err());

        let mut inconsistent_root = json!({
            "kind": "blitztree_snapshot", "schema_version": 1, "root": "/root",
            "generated_at_unix": 1, "coverage": {"complete": true, "errors": 0},
            "entries": [{"path": ".", "allocated_bytes": 0, "logical_bytes": 0, "complete": false}]
        });
        assert!(parse_snapshot(&inconsistent_root).is_err());
        inconsistent_root["coverage"]["complete"] = json!(false);
        inconsistent_root["entries"] = json!([
            {"path": ".", "allocated_bytes": 0, "logical_bytes": 0, "complete": false},
            {"path": "a", "allocated_bytes": 0, "logical_bytes": 0, "complete": false}
        ]);
        assert!(parse_snapshot(&inconsistent_root).is_ok());
        inconsistent_root["entries"][1]["complete"] = json!(true);
        inconsistent_root["entries"][0]["complete"] = json!(true);
        inconsistent_root["coverage"]["complete"] = json!(true);
        assert!(parse_snapshot(&inconsistent_root).is_ok());
        inconsistent_root["entries"][1]["complete"] = json!(false);
        assert!(parse_snapshot(&inconsistent_root).is_err());
    }

    #[test]
    fn exclusive_save_never_clobbers() {
        let path = std::env::temp_dir().join(format!("blitztree-snapshot-{}", std::process::id()));
        let _ = fs::remove_file(&path);
        save_exclusive(&path, "{}\n").unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "{}\n");
        assert!(save_exclusive(&path, "changed").is_err());
        let _ = fs::remove_file(path);
    }

    #[test]
    fn normalize_root_rejects_parent_components() {
        assert!(normalize_root(Path::new("/root/a/../b")).is_err());
        assert_eq!(
            normalize_root(Path::new("/root/a/./b")).unwrap(),
            "/root/a/b"
        );
        assert!(validate_canonical_root("relative").is_err());
        assert!(validate_canonical_root("/root/../b").is_err());
    }

    #[test]
    fn bounded_serialization_rejects_oversize_payload() {
        let value = json!({"payload": "x".repeat(MAX_SNAPSHOT_BYTES)});
        assert_eq!(
            serialize_bounded(&value).unwrap_err(),
            "Snapshot is larger than 64 MiB"
        );
    }

    #[test]
    fn extreme_unsigned_sizes_produce_exact_signed_json_without_panic() {
        let before = snapshot("/root", &[("huge", u64::MAX, true)], true);
        let after = snapshot("/root", &[("huge", 0, true)], true);
        let diff = compare_snapshot_values(&before, &after, 100).unwrap();
        assert_eq!(diff["changes"][0]["delta_bytes"].as_i64(), None);
        assert_eq!(
            diff["changes"][0]["delta_bytes"].to_string(),
            format!("-{}", u64::MAX)
        );
        assert_eq!(
            diff["total_delta_bytes"].to_string(),
            format!("-{}", u64::MAX)
        );
    }
}
