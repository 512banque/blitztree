import AppKit
import Foundation

private struct Fixture {
    var names = ["/fixture"]
    var parents = [UInt32.max]
    var sizes: [UInt64] = [0]
    var flags: [UInt8] = [1]
    var children: [[UInt32]] = [[]]

    @discardableResult
    mutating func add(_ name: String, to parent: Int = 0, bytes: UInt64 = 0, directory: Bool = true) -> Int {
        let id = names.count
        names.append(name)
        parents.append(UInt32(parent))
        sizes.append(bytes)
        flags.append(directory ? 1 : 0)
        children.append([])
        children[parent].append(UInt32(id))
        return id
    }

    func tree() -> Tree {
        var alloc = sizes
        for id in (1..<names.count).reversed() { alloc[Int(parents[id])] += alloc[id] }
        var offsets: [UInt32] = [0]
        var edges: [UInt32] = []
        var nameOffsets: [UInt32] = [0]
        var blob: [UInt8] = []
        for id in names.indices {
            edges.append(contentsOf: children[id].sorted { alloc[Int($0)] > alloc[Int($1)] })
            offsets.append(UInt32(edges.count))
            blob.append(contentsOf: names[id].utf8)
            nameOffsets.append(UInt32(blob.count))
        }
        let handle = bz_fixture_create(UInt32(names.count), parents, alloc, flags, offsets, edges, nameOffsets, blob)!
        return Tree(handle: handle)!
    }
}

private func signature(_ items: [CleanupItem]) -> [String] {
    items.map { "\($0.node)|\($0.path)|\($0.display)|\($0.kind)|\($0.bytes)" }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private func childrenAreUnmaterialized(_ item: OutlinePanel.Item) -> Bool {
    guard let kids = Mirror(reflecting: item).children.first(where: { $0.label == "kids" }) else {
        fatalError("Item children storage changed; update benchmark inspection")
    }
    return Mirror(reflecting: kids.value).children.isEmpty
}

private func milliseconds(_ work: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    work()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }

@main
struct UIPerformance {
    @MainActor
    static func main() {
        var fixture = Fixture()
        let positive: [(String, String?)] = [
            ("node_modules", nil), (".venv", nil), ("venv", "pyvenv.cfg"),
            ("target", "Cargo.toml"), (".next", "package.json"),
            ("DerivedData", "Xcode"), ("Caches", "Library"), ("Caches", "CoreSimulator"),
            (".cache", nil), (".npm", nil), (".gradle", nil),
            ("iOS DeviceSupport", nil), ("macOS DeviceSupport", nil), ("watchOS DeviceSupport", nil),
        ]
        var expected = Set<Int>()
        for (index, rule) in positive.enumerated() {
            let parentName = ["Xcode", "Library", "CoreSimulator"].contains(rule.1 ?? "") ? rule.1! : "project-\(index)"
            let parent = fixture.add(parentName)
            let match = fixture.add(rule.0, to: parent, bytes: Cleanup.minBytes)
            expected.insert(match)
            if let marker = rule.1, marker == "pyvenv.cfg" { fixture.add(marker, to: match, directory: false) }
            if let marker = rule.1, ["Cargo.toml", "package.json"].contains(marker) { fixture.add(marker, to: parent, directory: false) }
        }
        let bun = fixture.add(".bun")
        let install = fixture.add("install", to: bun)
        expected.insert(fixture.add("cache", to: install, bytes: Cleanup.minBytes))
        let nested = fixture.add("node_modules", bytes: Cleanup.minBytes)
        expected.insert(nested)
        fixture.add(".venv", to: nested, bytes: Cleanup.minBytes)
        let trash = fixture.add(".Trash")
        fixture.add("node_modules", to: trash, bytes: Cleanup.minBytes)
        for name in ["node_modules", ".venv", ".cache", "Caches", "文件😀"] {
            fixture.add(name, bytes: Cleanup.minBytes - 1)
        }
        for name in ["venv", "target", ".next", "DerivedData", "Caches", "cache"] {
            fixture.add(name, bytes: Cleanup.minBytes + 1)
        }
        fixture.add("node_modules", bytes: Cleanup.minBytes + 1, directory: false)
        let edgeTree = fixture.tree()
        check(signature(Cleanup.find(in: edgeTree)) == signature(ReferenceCleanup.find(in: edgeTree)), "Cleanup differs on threshold / marker / nesting cases")
        check(Set(Cleanup.find(in: edgeTree).map(\.node)) == expected, "Cleanup violated explicit matching expectations")

        // Deterministic uneven tree with duplicate sizes, Unicode names, empty
        // folders, and nested rebuildable names. No filesystem mutations.
        var randomFixture = Fixture()
        var state: UInt64 = 0xB1172
        for id in 1...25_000 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let parent = Int(state % UInt64(id))
            let names = ["src", "node_modules", ".cache", "文件😀", "venv", "target", ".Trash", "normal"]
            randomFixture.add(names[Int((state >> 8) % UInt64(names.count))], to: parent,
                              bytes: (state >> 24) % 100_000_000)
        }
        let randomTree = randomFixture.tree()
        check(signature(Cleanup.find(in: randomTree)) == signature(ReferenceCleanup.find(in: randomTree)), "Cleanup differs on randomized tree")

        // Insert qualifying entries last; flattening must sort them ahead of
        // tiny siblings so the threshold break never hides a later match.
        var wideCleanupFixture = Fixture()
        for child in 0..<100_000 { wideCleanupFixture.add("small-\(child)", bytes: 4096, directory: child.isMultiple(of: 2)) }
        wideCleanupFixture.add(".venv", bytes: Cleanup.minBytes - 1)
        let wideMatch = wideCleanupFixture.add("node_modules", bytes: Cleanup.minBytes)
        wideCleanupFixture.add("large-file", bytes: 100_000_000, directory: false)
        let wideCleanupTree = wideCleanupFixture.tree()
        check(signature(Cleanup.find(in: wideCleanupTree)) == signature(ReferenceCleanup.find(in: wideCleanupTree)), "Cleanup differs on wide sorted tree")
        check(Cleanup.find(in: wideCleanupTree).map(\.node) == [wideMatch], "Early break skipped an eligible sibling")

        let outline = NSOutlineView()
        let coordinator = OutlinePanel.Coordinator()
        let item = OutlinePanel.Item(id: 0, tree: randomTree)
        check(childrenAreUnmaterialized(item), "Fresh item eagerly created children")
        let count = coordinator.outlineView(outline, numberOfChildrenOfItem: item)
        check(count == randomTree.children(0).count, "Outline child count differs")
        check(childrenAreUnmaterialized(item), "Counting outline rows allocated child wrappers")

        // A map selection must not allocate the contents of an unopened folder.
        // A real outline is needed here because syncSelection goes through its
        // data source and selection callbacks.
        let model = ScanModel()
        model.tree = randomTree
        model.selection = 1
        coordinator.model = model
        coordinator.outline = outline
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.rebuildIfNeeded()
        coordinator.syncSelection()
        let selected = coordinator.roots.first { $0.id == 1 }!
        check((outline.item(atRow: outline.selectedRow) as? OutlinePanel.Item)?.id == 1, "Selection failed")
        check(childrenAreUnmaterialized(selected), "Selecting collapsed folder allocated its descendants")
        print("PASS: cleanup differential/expected matches; outline count and collapsed selection remain lazy")
        guard !CommandLine.arguments.contains("--check-only") else { return }

        let hasFDA = FDA.isActive()
        let fdaSamples = (0..<31).map { _ in milliseconds { check(FDA.isActive() == hasFDA, "FDA access changed during benchmark") } }
        print(String(format: "FDA probe active=%@ median_ms=%.3f max_ms=%.3f", hasFDA.description, median(fdaSamples), fdaSamples.max()!))

        var largeFixture = Fixture()
        for project in 0..<1_000 {
            let parent = largeFixture.add("project-\(project)")
            largeFixture.add("node_modules", to: parent, bytes: 64_000_000)
            let small = largeFixture.add("sources", to: parent)
            for child in 0..<512 {
                largeFixture.add("directory-with-a-long-name-\(child)", to: small, bytes: 4096)
            }
        }
        let largeTree = largeFixture.tree()
        let expectedItems = ReferenceCleanup.find(in: largeTree)
        check(signature(Cleanup.find(in: largeTree)) == signature(expectedItems), "Large cleanup fixture differs")
        var before: [Double] = [], after: [Double] = []
        for trial in 0..<9 {
            func old() { before.append(milliseconds { check(ReferenceCleanup.find(in: largeTree).count == 1_000, "Baseline count") }) }
            func new() { after.append(milliseconds { check(Cleanup.find(in: largeTree).count == 1_000, "Optimized count") }) }
            if trial.isMultiple(of: 2) { old(); new() } else { new(); old() }
        }
        print(String(format: "cleanup nodes=%d matches=%d baseline_ms=%.3f optimized_ms=%.3f speedup=%.2fx", largeTree.count, expectedItems.count, median(before), median(after), median(before) / median(after)))
        print("cleanup baseline_ms samples=\(before) optimized_ms samples=\(after)")
        before = []; after = []
        for trial in 0..<9 {
            func old() { before.append(milliseconds { check(ReferenceCleanup.find(in: wideCleanupTree).count == 1, "Baseline wide cleanup count") }) }
            func new() { after.append(milliseconds { check(Cleanup.find(in: wideCleanupTree).count == 1, "Optimized wide cleanup count") }) }
            if trial.isMultiple(of: 2) { old(); new() } else { new(); old() }
        }
        print(String(format: "cleanup wide_siblings=%d baseline_ms=%.3f optimized_ms=%.6f", wideCleanupTree.children(0).count, median(before), median(after)))

        var wideFixture = Fixture()
        let wideParent = wideFixture.add("wide-folder")
        for child in 0..<100_000 { wideFixture.add("child-\(child)", to: wideParent) }
        let wideTree = wideFixture.tree()
        before = []; after = []
        for _ in 0..<9 {
            let oldItem = OutlinePanel.Item(id: wideParent, tree: wideTree)
            before.append(milliseconds { check(oldItem.children.count == 100_000, "Baseline outline count") })
            check(!childrenAreUnmaterialized(oldItem), "Baseline did not materialize wrappers")
            let newItem = OutlinePanel.Item(id: wideParent, tree: wideTree)
            after.append(milliseconds { check(coordinator.outlineView(outline, numberOfChildrenOfItem: newItem) == 100_000, "Optimized outline count") })
            check(childrenAreUnmaterialized(newItem), "Wide count allocated wrappers")
        }
        print(String(format: "outline child_count=100000 baseline_ms=%.3f optimized_ms=%.6f baseline_wrappers=100000 optimized_wrappers=0", median(before), median(after)))
    }
}
