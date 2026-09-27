//! The Clean Up panel's folder recognition, shared with the JSON CLI.
//! These are name/structure heuristics, not authorization to delete anything.
use crate::{Scan, NO_PARENT};

pub const MIN_BYTES: u64 = 50_000_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    NodeModules,
    PythonEnvironment,
    RustBuild,
    NextBuild,
    XcodeDerivedData,
    DeviceSupport,
    AppCaches,
    ToolCaches,
    BunCache,
}

impl Kind {
    pub fn id(self) -> &'static str {
        match self {
            Self::NodeModules => "node_modules",
            Self::PythonEnvironment => "python_environment",
            Self::RustBuild => "rust_build",
            Self::NextBuild => "next_build",
            Self::XcodeDerivedData => "xcode_derived_data",
            Self::DeviceSupport => "device_support",
            Self::AppCaches => "app_caches",
            Self::ToolCaches => "tool_caches",
            Self::BunCache => "bun_cache",
        }
    }

    /// Existing panel labels; kept here so both interfaces describe the same rule.
    pub fn description(self) -> &'static str {
        match self {
            Self::NodeModules => "npm packages, reinstallable",
            Self::PythonEnvironment => "Python environment, reinstallable",
            Self::RustBuild => "Rust build output",
            Self::NextBuild => "Next.js build output",
            Self::XcodeDerivedData => "Xcode build data",
            Self::DeviceSupport => "Device symbols, re-downloaded when needed",
            Self::AppCaches => "App caches, rebuilt automatically",
            Self::ToolCaches => "Caches, rebuilt or re-downloaded when needed",
            Self::BunCache => "Bun package cache, re-downloaded when needed",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Candidate {
    pub node: u32,
    pub kind: Kind,
}

fn contains(scan: &Scan, directory: u32, name: &str) -> bool {
    directory != NO_PARENT
        && scan.nodes[directory as usize]
            .children
            .clone()
            .any(|i| &*scan.nodes[i as usize].name == name)
}

fn kind(scan: &Scan, i: u32) -> Option<Kind> {
    let node = &scan.nodes[i as usize];
    let parent = node.parent;
    let parent_node = (parent != NO_PARENT).then(|| &scan.nodes[parent as usize]);
    let parent_name = parent_node.map_or("", |n| &*n.name);
    // Marker lookups happen only for the named artifact, not every sibling.
    match &*node.name {
        "node_modules" => Some(Kind::NodeModules),
        ".venv" => Some(Kind::PythonEnvironment),
        "venv" if contains(scan, i, "pyvenv.cfg") => Some(Kind::PythonEnvironment),
        "target" if contains(scan, parent, "Cargo.toml") => Some(Kind::RustBuild),
        ".next" if contains(scan, parent, "package.json") => Some(Kind::NextBuild),
        "DerivedData" if parent_name == "Xcode" => Some(Kind::XcodeDerivedData),
        "iOS DeviceSupport" | "macOS DeviceSupport" | "watchOS DeviceSupport" => {
            Some(Kind::DeviceSupport)
        }
        "Caches" if parent_name == "Library" || parent_name == "CoreSimulator" => {
            Some(Kind::AppCaches)
        }
        ".cache" | ".npm" | ".gradle" => Some(Kind::ToolCaches),
        "cache"
            if parent_name == "install"
                && parent_node.is_some_and(|n| {
                    n.parent != NO_PARENT && &*scan.nodes[n.parent as usize].name == ".bun"
                }) =>
        {
            Some(Kind::BunCache)
        }
        _ => None,
    }
}

/// Existing panel semantics: visit descendants (not the scan root), skip
/// `.Trash`, and never descend into a recognized folder, even below threshold.
/// Size ties use paths so parallel scan scheduling cannot reorder the report.
pub fn find(scan: &Scan, min_bytes: u64) -> Vec<Candidate> {
    let mut found = Vec::new();
    if scan.nodes.is_empty() {
        return found;
    }
    let mut stack = vec![0];
    while let Some(i) = stack.pop() {
        for child in scan.nodes[i].children.clone() {
            let node = &scan.nodes[child as usize];
            // Child ranges are unsorted; skip this subtree, not later siblings.
            if node.alloc < min_bytes || !node.is_dir || &*node.name == ".Trash" {
                continue;
            }
            if let Some(kind) = kind(scan, child) {
                found.push(Candidate { node: child, kind });
            } else {
                stack.push(child as usize);
            }
        }
    }
    found.sort_by(|a, b| {
        scan.nodes[b.node as usize]
            .alloc
            .cmp(&scan.nodes[a.node as usize].alloc)
            .then_with(|| scan.path(a.node as usize).cmp(&scan.path(b.node as usize)))
    });
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Node;

    fn add(scan: &mut Scan, parent: u32, name: &str, is_dir: bool, bytes: u64) -> u32 {
        let index = scan.nodes.len() as u32;
        scan.nodes.push(Node {
            name: name.into(),
            parent,
            is_dir,
            alloc: bytes,
            size: bytes,
            complete: true,
            n_files: 0,
            children: 0..0,
        });
        if parent != NO_PARENT {
            let children = &mut scan.nodes[parent as usize].children;
            if children.start == children.end {
                *children = index..index + 1;
            } else {
                assert_eq!(children.end, index);
                children.end += 1;
            }
        }
        index
    }

    #[test]
    fn recognizes_all_existing_panel_rules_and_no_new_ones() {
        // Each row has an independent context, including the legacy name-only
        // marker behavior. No filesystem access is needed for classification.
        let cases = [
            (
                "node_modules",
                "project",
                "",
                "",
                "",
                Some(Kind::NodeModules),
            ),
            (
                ".venv",
                "project",
                "",
                "",
                "",
                Some(Kind::PythonEnvironment),
            ),
            (
                "venv",
                "project",
                "",
                "",
                "pyvenv.cfg",
                Some(Kind::PythonEnvironment),
            ),
            ("venv", "project", "", "", "", None),
            (
                "target",
                "project",
                "",
                "Cargo.toml",
                "",
                Some(Kind::RustBuild),
            ),
            ("target", "project", "", "", "", None),
            (
                ".next",
                "project",
                "",
                "package.json",
                "",
                Some(Kind::NextBuild),
            ),
            (".next", "project", "", "", "", None),
            (
                "DerivedData",
                "Xcode",
                "",
                "",
                "",
                Some(Kind::XcodeDerivedData),
            ),
            ("DerivedData", "other", "", "", "", None),
            (
                "iOS DeviceSupport",
                "any",
                "",
                "",
                "",
                Some(Kind::DeviceSupport),
            ),
            (
                "macOS DeviceSupport",
                "any",
                "",
                "",
                "",
                Some(Kind::DeviceSupport),
            ),
            (
                "watchOS DeviceSupport",
                "any",
                "",
                "",
                "",
                Some(Kind::DeviceSupport),
            ),
            ("Caches", "Library", "", "", "", Some(Kind::AppCaches)),
            ("Caches", "CoreSimulator", "", "", "", Some(Kind::AppCaches)),
            ("Caches", "other", "", "", "", None),
            (".cache", "any", "", "", "", Some(Kind::ToolCaches)),
            (".npm", "any", "", "", "", Some(Kind::ToolCaches)),
            (".gradle", "any", "", "", "", Some(Kind::ToolCaches)),
            ("cache", "install", ".bun", "", "", Some(Kind::BunCache)),
            ("cache", "install", "other", "", "", None),
            ("cache", "other", ".bun", "", "", None),
            (".build", "project", "", "Package.swift", "", None),
            ("Downloads", "home", "", "", "", None),
        ];
        for (name, parent, grandparent, sibling, child, expected) in cases {
            let mut scan = Scan {
                nodes: Vec::new(),
                errors: 0,
            };
            add(&mut scan, NO_PARENT, "/root", true, 0);
            let gp = add(&mut scan, 0, grandparent, true, MIN_BYTES);
            let p = add(&mut scan, gp, parent, true, MIN_BYTES);
            let i = add(&mut scan, p, name, true, MIN_BYTES);
            if !sibling.is_empty() {
                add(&mut scan, p, sibling, false, 0);
            }
            if !child.is_empty() {
                add(&mut scan, i, child, false, 0);
            }
            assert_eq!(kind(&scan, i), expected, "{grandparent}/{parent}/{name}");
            assert_eq!(
                find(&scan, MIN_BYTES),
                expected
                    .map(|kind| Candidate { node: i, kind })
                    .into_iter()
                    .collect::<Vec<_>>()
            );
        }
    }

    #[test]
    fn preserves_panel_traversal_threshold_and_partial_candidates() {
        let mut scan = Scan {
            nodes: Vec::new(),
            errors: 0,
        };
        add(
            &mut scan,
            NO_PARENT,
            "/root/node_modules",
            true,
            MIN_BYTES * 10,
        );
        let trash = add(&mut scan, 0, ".Trash", true, MIN_BYTES * 2);
        add(&mut scan, 0, ".cache", false, MIN_BYTES * 2);
        let matched = add(&mut scan, 0, "node_modules", true, MIN_BYTES);
        let small = add(&mut scan, 0, ".gradle", true, MIN_BYTES - 1);
        add(&mut scan, trash, "node_modules", true, MIN_BYTES * 2);
        add(&mut scan, matched, ".venv", true, MIN_BYTES);
        // Deliberately inconsistent size catches descent under a small match.
        add(&mut scan, small, ".venv", true, MIN_BYTES);
        scan.nodes[matched as usize].complete = false;
        assert_eq!(
            find(&scan, MIN_BYTES),
            vec![Candidate {
                node: matched,
                kind: Kind::NodeModules
            }]
        );
    }

    #[test]
    fn size_ties_are_lexical_independent_of_discovery_order() {
        for names in [["z", "a"], ["a", "z"]] {
            let mut scan = Scan {
                nodes: Vec::new(),
                errors: 0,
            };
            add(&mut scan, NO_PARENT, "/root", true, 0);
            let first = add(&mut scan, 0, names[0], true, MIN_BYTES);
            let second = add(&mut scan, 0, names[1], true, MIN_BYTES);
            let large = add(&mut scan, 0, ".npm", true, MIN_BYTES * 2);
            let first_cache = add(&mut scan, first, ".cache", true, MIN_BYTES);
            let second_cache = add(&mut scan, second, ".cache", true, MIN_BYTES);
            let expected = if names[0] == "a" {
                vec![large, first_cache, second_cache]
            } else {
                vec![large, second_cache, first_cache]
            };
            assert_eq!(
                find(&scan, MIN_BYTES)
                    .iter()
                    .map(|c| c.node)
                    .collect::<Vec<_>>(),
                expected
            );
        }
    }
}
