import Foundation

/// Read-only real-tree counterpart to the synthetic UI harness. The scan is
/// excluded from cleanup timings; both algorithms inspect the same snapshot.
@main
struct UICleanupScan {
    @MainActor
    static func main() {
        precondition(CommandLine.arguments.count > 1, "Usage: ui-cleanup-scan PATH [PATH ...]")
        for path in CommandLine.arguments.dropFirst() { measureScan(path) }
    }

    @MainActor
    static func measureScan(_ path: String) {
        guard let handle = bz_scan_start(path) else { fatalError("Could not start scan") }
        var files: UInt64 = 0, dirs: UInt64 = 0, bytes: UInt64 = 0, done: Int32 = 0
        repeat {
            Thread.sleep(forTimeInterval: 0.01)
            bz_progress(handle, &files, &dirs, &bytes, &done)
        } while done == 0
        guard let tree = Tree(handle: handle) else { bz_free(handle); fatalError("Scan produced no tree") }
        func signature(_ items: [CleanupItem]) -> [String] {
            items.map { "\($0.node)|\($0.path)|\($0.display)|\($0.kind)|\($0.bytes)" }
        }
        let expected = signature(ReferenceCleanup.find(in: tree))
        precondition(signature(Cleanup.find(in: tree)) == expected, "Cleanup output changed")
        func measured(_ find: (Tree) -> [CleanupItem]) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            let found = find(tree)
            let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            precondition(signature(found) == expected, "Cleanup output changed")
            return duration
        }
        var before: [Double] = [], after: [Double] = []
        for trial in 0..<9 {
            if trial.isMultiple(of: 2) {
                before.append(measured(ReferenceCleanup.find)); after.append(measured(Cleanup.find))
            } else {
                after.append(measured(Cleanup.find)); before.append(measured(ReferenceCleanup.find))
            }
        }
        print("scan_path=\(path)")
        print(String(format: "real cleanup nodes=%d matches=%d unreadable=%llu baseline_ms=%.3f optimized_ms=%.3f speedup=%.2fx", tree.count, expected.count, tree.errors, before.sorted()[4], after.sorted()[4], before.sorted()[4] / after.sorted()[4]))
        print("baseline_ms=\(before) optimized_ms=\(after)")
    }
}
