// Baseline algorithm retained for differential correctness and timing.
import Foundation

nonisolated enum ReferenceCleanup {
    /// Smaller finds aren't worth a line in the list.
    static let minBytes: UInt64 = 50_000_000

    /// Walks the tree once, top-down. A match is not descended into, so a
    /// node_modules inside a node_modules is never counted twice.
    static func find(in tree: Tree) -> [CleanupItem] {
        let home = NSHomeDirectory()
        var found: [CleanupItem] = []
        var stack: [Int]
        if let rootKind = rootGranularKind(in: tree) {
            appendGranularChildren(0, kind: rootKind, in: tree, home: home, found: &found)
            stack = []
        } else {
            stack = [0]
        }
        while let i = stack.popLast() {
            for c in tree.children(i) {
                let child = Int(c)
                // Already-trashed things aren't worth offering again.
                guard tree.isDir(child), tree.name(child) != ".Trash" else { continue }
                if let kind = kind(of: child, in: tree) {
                    if tree.alloc[child] >= minBytes {
                        if isGranularContainer(child, kind: kind, in: tree) {
                            appendGranularChildren(child, kind: kind, in: tree, home: home, found: &found)
                        } else {
                            found.append(item(in: tree, home: home, node: child, kind: kind))
                        }
                    }
                } else {
                    stack.append(child)
                }
            }
        }
        return found.sorted { $0.bytes > $1.bytes }
    }

    private static func appendGranularChildren(
        _ container: Int, kind: String, in tree: Tree, home: String, found: inout [CleanupItem]
    ) {
        if kind == "App caches, rebuilt automatically" && isSystemCacheContainer(container, in: tree) {
            return
        }
        for raw in tree.children(container) {
            let node = Int(raw)
            guard tree.isDir(node), tree.alloc[node] >= minBytes,
                  tree.name(node) != ".Trash",
                  !isAppleManagedCache(node, in: tree) else { continue }
            found.append(item(in: tree, home: home, node: node, kind: kind))
        }
    }

    private static func item(in tree: Tree, home: String, node: Int, kind: String) -> CleanupItem {
        let path = tree.path(node)
        var display = tree.displayPath(node)
        if display.hasPrefix(home) { display = "~" + display.dropFirst(home.count) }
        return CleanupItem(node: node, path: path, display: display,
                          kind: kind, bytes: tree.alloc[node])
    }

    private static func isGranularContainer(_ node: Int, kind: String, in tree: Tree) -> Bool {
        kind == "App caches, rebuilt automatically"
            || (kind == "Caches, rebuilt or re-downloaded when needed" && tree.name(node) == ".cache")
    }

    private static func rootGranularKind(in tree: Tree) -> String? {
        let components = tree.path(0).split(separator: "/")
        guard let last = components.last else { return nil }
        if last == ".cache" { return "Caches, rebuilt or re-downloaded when needed" }
        guard last == "Caches", let parent = components.dropLast().last,
              parent == "Library" || parent == "CoreSimulator" else { return nil }
        return "App caches, rebuilt automatically"
    }

    private static func isAppleManagedCache(_ node: Int, in tree: Tree) -> Bool {
        tree.name(node) == "com.apple" || tree.name(node).hasPrefix("com.apple.")
    }

    private static func isSystemCacheContainer(_ node: Int, in tree: Tree) -> Bool {
        let components = tree.path(node).split(separator: "/")
        guard let first = components.first else { return false }
        if first == "Library" { return true }
        guard first == "System" else { return false }
        let rest = Array(components.dropFirst())
        return !(rest.count >= 3 && rest[0] == "Volumes" && rest[1] == "Data" && rest[2] == "Users")
    }

    private static func kind(of i: Int, in tree: Tree) -> String? {
        let name = tree.name(i)
        let parent = Int(tree.parents[i])
        let parentName = parent == Int(UInt32.max) ? "" : tree.name(parent)
        switch name {
        case "node_modules":
            return "npm packages, reinstallable"
        case ".venv":
            return "Python environment, reinstallable"
        case "venv" where contains(i, "pyvenv.cfg", in: tree):
            return "Python environment, reinstallable"
        case "target" where contains(parent, "Cargo.toml", in: tree):
            return "Rust build output"
        case ".next" where contains(parent, "package.json", in: tree):
            return "Next.js build output"
        case "DerivedData" where parentName == "Xcode":
            return "Xcode build data"
        case "iOS DeviceSupport", "macOS DeviceSupport", "watchOS DeviceSupport":
            return "Device symbols, re-downloaded when needed"
        case "Caches" where parentName == "Library" || parentName == "CoreSimulator":
            return "App caches, rebuilt automatically"
        case ".cache", ".npm", ".gradle":
            return "Caches, rebuilt or re-downloaded when needed"
        case "cache" where parentName == "install" && grandparentName(of: parent, in: tree) == ".bun":
            return "Bun package cache, re-downloaded when needed"
        default:
            return nil
        }
    }

    private static func grandparentName(of parent: Int, in tree: Tree) -> String {
        guard parent != Int(UInt32.max) else { return "" }
        let gp = Int(tree.parents[parent])
        return gp == Int(UInt32.max) ? "" : tree.name(gp)
    }

    /// Whether directory `dir` directly contains an entry named `name`.
    private static func contains(_ dir: Int, _ name: String, in tree: Tree) -> Bool {
        guard dir != Int(UInt32.max) else { return false }
        return tree.children(dir).contains { tree.name(Int($0)) == name }
    }
}
