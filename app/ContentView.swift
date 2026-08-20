import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @State private var model = ScanModel()
    @State private var showTable = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                Color(nsColor: NSColor(calibratedWhite: 0.10, alpha: 1))
                if model.tree != nil {
                    HSplitView {
                        if showTable {
                            OutlinePanel(model: model)
                                .frame(minWidth: 210, idealWidth: 285, maxWidth: 400)
                        }
                        TreemapView(model: model)
                            .frame(minWidth: 400, maxWidth: .infinity)
                    }
                } else if model.scanning {
                    scanningOverlay
                } else if needsFDA {
                    fdaOverlay
                } else {
                    idleOverlay
                }
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 760, minHeight: 500)
        .onAppear {
            // Never start a whole-disk scan without FDA: every protected
            // app container would fire a permission prompt.
            if FDA.isActive() {
                model.startScan()
            } else {
                needsFDA = true
            }
        }
    }

    @State private var needsFDA = false

    private var fdaOverlay: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("BlitzTree needs Full Disk Access")
                .font(.title2.weight(.semibold))
            Text("System Settings → Privacy & Security → Full Disk Access.\nRemove any old BlitzTree rows, then add /Applications/BlitzTree.app.\nmacOS only applies the permission to a freshly launched app.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
            HStack(spacing: 12) {
                Button("Open System Settings") { openFDASettings() }
                Button("I granted it — Relaunch") { FDA.relaunch() }
                    .buttonStyle(.borderedProminent)
            }
            Button("Scan without it") {
                needsFDA = false
                model.startScan()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            if let tree = model.tree {
                breadcrumbs(tree: tree)
            } else {
                Text(model.scanRoot)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if model.scanning {
                liveStats
            }
            Menu {
                Button("Home") { model.startScan(path: FileManager.default.homeDirectoryForCurrentUser.path) }
                Button("Macintosh HD") { model.startScan(path: "/System/Volumes/Data") }
                Divider()
                Button("Choose Folder…") { chooseFolder() }
            } label: {
                Image(systemName: "folder")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.scanning)

            Button {
                model.showFreeSpace.toggle()
            } label: {
                Image(systemName: model.showFreeSpace ? "square.dashed.inset.filled" : "square.dashed")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(model.showFreeSpace ? Color.accentColor : Color.secondary)
            .help("Show free space in the treemap")

            Button {
                showTable.toggle()
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(.borderless)
            .help("Show directory tree")

            Button {
                model.startScan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.scanning)
            .help("Rescan")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func breadcrumbs(tree: Tree) -> some View {
        HStack(spacing: 4) {
            let chain = tree.ancestry(model.viewRoot)
            ForEach(Array(chain.enumerated()), id: \.offset) { i, node in
                if i > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    model.viewRoot = node
                } label: {
                    Text(node == 0 ? displayRootName() : tree.name(node))
                        .font(.system(.body, design: .rounded).weight(i == chain.count - 1 ? .semibold : .regular))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(i == chain.count - 1 ? .primary : .secondary)
            }
        }
    }

    private func displayRootName() -> String {
        let p = model.scanRoot
        if p == "/System/Volumes/Data" { return "Macintosh HD" }
        return (p as NSString).lastPathComponent.isEmpty ? p : (p as NSString).lastPathComponent
    }

    private var liveStats: some View {
        HStack(spacing: 12) {
            Text(Fmt.size(model.bytes))
            Text("\(Fmt.num(model.files)) files")
            Text(String(format: "%.1fs", model.elapsed))
        }
        .font(.system(.callout, design: .monospaced))
        .foregroundStyle(.secondary)
        .contentTransition(.numericText())
    }

    // MARK: overlays

    private var scanningOverlay: some View {
        VStack(spacing: 14) {
            Text(Fmt.size(model.bytes))
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.white)
            Text("\(Fmt.num(model.files)) files · \(Fmt.num(model.dirs)) folders · \(String(format: "%.1f", model.elapsed))s")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        }
        .animation(.default, value: model.bytes)
    }

    private var idleOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Pick a target and scan")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let tree = model.tree {
                if let sel = model.hovered ?? model.selection {
                    Text(tree.displayPath(sel))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    let a = tree.alloc[sel]
                    let rootA = max(tree.alloc[model.viewRoot], 1)
                    Text("\(Fmt.size(a)) · \(String(format: "%.1f%%", 100 * Double(a) / Double(rootA)))")
                        .monospacedDigit()
                } else {
                    Text("\(Fmt.num(UInt64(tree.nFiles[model.viewRoot]))) files · \(Fmt.size(tree.alloc[model.viewRoot]))")
                    Spacer()
                    if tree.errors > 0 {
                        if FDA.isActive() {
                            // Root-owned system dirs: unreadable by design,
                            // not a permissions problem the user can fix.
                            let gap = model.unscannedBytes > 1_000_000_000
                                ? " · ~\(Fmt.size(model.unscannedBytes)) root-only" : ""
                            Text("\(tree.errors) system folders unreadable\(gap)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            Button {
                                openFDASettings()
                            } label: {
                                Label("\(tree.errors) folders skipped — grant Full Disk Access", systemImage: "lock.shield")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Text("scanned in \(String(format: "%.1fs", model.elapsed))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                Text("BlitzTree").foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.startScan(path: url.path)
        }
    }

    private func openFDASettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Left panel: a real NSOutlineView — the same control as Finder's list
/// view. Native disclosure triangles, real file icons, alternating rows,
/// keyboard navigation.
struct OutlinePanel: NSViewRepresentable {
    let model: ScanModel

    final class Item {
        let id: Int
        let tree: Tree
        private var kids: [Item]?
        init(id: Int, tree: Tree) {
            self.id = id
            self.tree = tree
        }
        var children: [Item] {
            if kids == nil { kids = tree.children(id).map { Item(id: Int($0), tree: tree) } }
            return kids!
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var model: ScanModel?
        var tree: Tree?
        var viewRoot = -1
        var roots: [Item] = []
        weak var outline: NSOutlineView?
        private var iconCache: [String: NSImage] = [:]

        func rebuildIfNeeded() {
            guard let model, let t = model.tree else { return }
            if t !== tree || model.viewRoot != viewRoot {
                tree = t
                viewRoot = model.viewRoot
                roots = t.children(viewRoot).map { Item(id: Int($0), tree: t) }
                outline?.reloadData()
            }
        }

        func icon(for name: String, isDir: Bool) -> NSImage {
            let key: String
            if isDir {
                key = "/folder"
            } else if let dot = name.lastIndex(of: "."), dot != name.startIndex {
                key = String(name[name.index(after: dot)...]).lowercased()
            } else {
                key = "/plain"
            }
            if let hit = iconCache[key] { return hit }
            let img: NSImage
            if key == "/folder" {
                img = NSWorkspace.shared.icon(for: .folder)
            } else if key == "/plain" {
                img = NSWorkspace.shared.icon(for: .data)
            } else {
                img = NSWorkspace.shared.icon(for: UTType(filenameExtension: key) ?? .data)
            }
            iconCache[key] = img
            return img
        }

        // MARK: data source
        func outlineView(_ v: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            item == nil ? roots.count : (item as! Item).children.count
        }
        func outlineView(_ v: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            item == nil ? roots[index] : (item as! Item).children[index]
        }
        func outlineView(_ v: NSOutlineView, isItemExpandable item: Any) -> Bool {
            let it = item as! Item
            return it.tree.isDir(it.id) && !it.tree.children(it.id).isEmpty
        }

        // MARK: cells
        func outlineView(_ v: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
            let it = item as! Item
            let tree = it.tree
            let colID = col?.identifier.rawValue ?? "name"
            let reuse = NSUserInterfaceItemIdentifier("cell-\(colID)")

            if colID == "name" {
                let cell = (v.makeView(withIdentifier: reuse, owner: nil) as? NSTableCellView) ?? {
                    let c = NSTableCellView()
                    c.identifier = reuse
                    let iv = NSImageView()
                    iv.translatesAutoresizingMaskIntoConstraints = false
                    let tf = NSTextField(labelWithString: "")
                    tf.translatesAutoresizingMaskIntoConstraints = false
                    tf.font = .systemFont(ofSize: 13)
                    tf.lineBreakMode = .byTruncatingMiddle
                    c.addSubview(iv); c.addSubview(tf)
                    c.imageView = iv; c.textField = tf
                    NSLayoutConstraint.activate([
                        iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                        iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                        iv.widthAnchor.constraint(equalToConstant: 16),
                        iv.heightAnchor.constraint(equalToConstant: 16),
                        tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
                        tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                        tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    ])
                    return c
                }()
                cell.textField?.stringValue = tree.name(it.id)
                cell.imageView?.image = icon(for: tree.name(it.id), isDir: tree.isDir(it.id))
                return cell
            }

            let cell = (v.makeView(withIdentifier: reuse, owner: nil) as? NSTableCellView) ?? {
                let c = NSTableCellView()
                c.identifier = reuse
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                tf.textColor = .secondaryLabelColor
                tf.alignment = .right
                c.addSubview(tf)
                c.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor),
                    tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            if colID == "size" {
                cell.textField?.stringValue = Fmt.size(tree.alloc[it.id])
            } else {
                let parent = Int(tree.parents[it.id])
                let pAlloc = parent == Int(UInt32.max) ? tree.alloc[0] : tree.alloc[parent]
                let pct = pAlloc > 0 ? 100 * Double(tree.alloc[it.id]) / Double(pAlloc) : 0
                cell.textField?.stringValue = pct < 0.5 ? "–" : String(format: "%.0f%%", pct)
                cell.textField?.textColor = .tertiaryLabelColor
            }
            return cell
        }

        func outlineViewSelectionDidChange(_ n: Notification) {
            guard let outline else { return }
            if let it = outline.item(atRow: outline.selectedRow) as? Item {
                model?.selection = it.id
            }
        }

        /// Treemap click → expand ancestors, select and reveal the row here.
        func syncSelection() {
            guard let outline, let tree, let sel = model?.selection else { return }
            if let cur = outline.item(atRow: outline.selectedRow) as? Item, cur.id == sel { return }

            var chain: [Int] = []
            var cur = sel
            while cur != viewRoot {
                if cur == Int(UInt32.max) { return } // outside current view root
                chain.append(cur)
                cur = Int(tree.parents[cur])
            }
            chain.reverse()

            var level = roots
            var target: Item?
            for id in chain {
                guard let it = level.first(where: { $0.id == id }) else { return }
                target = it
                if id != chain.last { outline.expandItem(it) }
                level = it.children
            }
            if let target {
                let row = outline.row(forItem: target)
                if row >= 0 {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                }
            }
        }

        @objc func doubleClicked(_ sender: NSOutlineView) {
            guard let it = sender.item(atRow: sender.clickedRow) as? Item else { return }
            if it.tree.isDir(it.id) {
                model?.viewRoot = it.id
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: it.tree.path(it.id))])
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        outline.style = .plain
        outline.rowSizeStyle = .default
        outline.usesAlternatingRowBackgroundColors = true
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 13
        outline.autoresizesOutlineColumn = false

        let name = NSTableColumn(identifier: .init("name"))
        name.title = "Name"
        name.minWidth = 120
        let size = NSTableColumn(identifier: .init("size"))
        size.title = "Size"
        size.width = 92; size.minWidth = 84; size.maxWidth = 116
        let pct = NSTableColumn(identifier: .init("pct"))
        pct.title = "%"
        pct.width = 34; pct.minWidth = 30; pct.maxWidth = 44

        outline.addTableColumn(name)
        outline.addTableColumn(size)
        outline.addTableColumn(pct)
        outline.outlineTableColumn = name
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let coord = context.coordinator
        coord.model = model
        coord.outline = outline
        outline.dataSource = coord
        outline.delegate = coord
        outline.target = coord
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        coord.rebuildIfNeeded()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.rebuildIfNeeded()
        context.coordinator.syncSelection()
    }
}
