import AppKit
import SwiftUI

/// A folder that is safe to delete because a tool rebuilds or re-downloads
/// it on demand: package installs, build output, caches.
nonisolated struct CleanupItem: Identifiable, Sendable {
    let node: Int
    let path: String
    let display: String
    let kind: String
    let bytes: UInt64
    var id: Int { node }
}

nonisolated enum Cleanup {
    /// Smaller finds aren't worth a line in the list.
    static let minBytes: UInt64 = 50_000_000

    /// Walks the tree once, top-down. A match is not descended into, so a
    /// node_modules inside a node_modules is never counted twice.
    static func find(in tree: Tree) -> [CleanupItem] {
        let home = NSHomeDirectory()
        var found: [CleanupItem] = []
        var stack = [0]
        while let i = stack.popLast() {
            for c in tree.children(i) {
                let child = Int(c)
                // Already-trashed things aren't worth offering again.
                guard tree.isDir(child), tree.name(child) != ".Trash" else { continue }
                if let kind = kind(of: child, in: tree) {
                    if tree.alloc[child] >= minBytes {
                        let path = tree.path(child)
                        var display = tree.displayPath(child)
                        if display.hasPrefix(home) { display = "~" + display.dropFirst(home.count) }
                        found.append(CleanupItem(node: child, path: path, display: display,
                                                 kind: kind, bytes: tree.alloc[child]))
                    }
                } else {
                    stack.append(child)
                }
            }
        }
        return found.sorted { $0.bytes > $1.bytes }
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

/// Right-hand inspector: what can be reclaimed, pick, trash, rescan.
struct CleanupPanel: View {
    let model: ScanModel
    @State private var picked: Set<Int> = []
    @State private var confirming = false
    @State private var failures: [String] = []

    private var pickedItems: [CleanupItem] { model.cleanup.filter { picked.contains($0.id) } }
    private var pickedBytes: UInt64 { pickedItems.reduce(0) { $0 + $1.bytes } }
    private var totalBytes: UInt64 { model.cleanup.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reclaimable")
                    .font(.headline)
                Text(model.cleanup.isEmpty ? "Nothing large to clean up"
                     : "\(Fmt.size(totalBytes)) in \(model.cleanup.count) folders")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            List(model.cleanup) { item in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { picked.contains(item.id) },
                        set: { on in if on { picked.insert(item.id) } else { picked.remove(item.id) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.display)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text(item.kind)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(Fmt.size(item.bytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .help(item.display)
                .onTapGesture { model.selection = item.node }
                .contextMenu {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            Button {
                confirming = true
            } label: {
                Text(picked.isEmpty ? "Select folders to clean up"
                     : "Move \(picked.count) to Trash · \(Fmt.size(pickedBytes))")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(picked.isEmpty || model.scanning)
            .padding(12)
        }
        .confirmationDialog(picked.count == 1 ? "Move 1 folder to the Trash?" : "Move \(picked.count) folders to the Trash?", isPresented: $confirming) {
            Button("Move to Trash (\(Fmt.size(pickedBytes)))", role: .destructive) { trashPicked() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can put them back from the Trash until you empty it. The tools that made them rebuild them when needed.")
        }
        .alert("Some folders couldn't be moved", isPresented: .constant(!failures.isEmpty)) {
            Button("OK") { failures = [] }
        } message: {
            Text(failures.joined(separator: "\n"))
        }
    }

    private func trashPicked() {
        var failed: [String] = []
        for item in pickedItems {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
            } catch {
                failed.append("\(item.display): \(error.localizedDescription)")
            }
        }
        picked = []
        failures = failed
        // Rescan so every size on screen matches the disk again.
        model.startScan()
    }
}
