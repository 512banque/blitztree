import AppKit
import SwiftUI

@main
struct ComparisonChecks {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("blitztree-comparison-\(UUID().uuidString)")
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("scan")
        let growing = root.appendingPathComponent("growing/file")
        let removed = root.appendingPathComponent("removed/file")
        for file in [growing, removed] {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 65, count: 131_072).write(to: file)
        }
        func scan() async -> Tree {
            let handle = root.path.withCString { bz_scan_start($0) }!
            var files: UInt64 = 0, dirs: UInt64 = 0, bytes: UInt64 = 0
            var done: Int32 = 0
            repeat {
                bz_progress(handle, &files, &dirs, &bytes, &done)
                if done == 0 { try? await Task.sleep(for: .milliseconds(5)) }
            } while done == 0
            return Tree(handle: handle)!
        }
        let before = await scan()
        let saved = fixture.appendingPathComponent("before.json")
        try before.saveSnapshot(to: saved)
        let savedBytes = try Data(contentsOf: saved)
        let attributes = try fm.attributesOfItem(atPath: saved.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        do {
            try before.saveSnapshot(to: saved)
            preconditionFailure("Saving must not overwrite an existing file")
        } catch {}
        let preservedBytes = try Data(contentsOf: saved)
        precondition(preservedBytes == savedBytes)

        try Data(repeating: 66, count: 1_048_576).write(to: growing)
        try fm.removeItem(at: removed.deletingLastPathComponent())
        let after = await scan()
        let current = try after.snapshotJSON()
        let diff = try SnapshotIO.compare(baseline: saved, current: current)
        precondition(diff.complete)
        precondition(diff.changes.contains { $0.path == "growing" && $0.status == "grew" })
        precondition(diff.changes.contains { $0.path == "removed" && $0.status == "removed" })
        precondition(!diff.changes.contains { $0.path.contains("file") }, "Only folder metadata belongs in snapshots")

        var partial = try JSONSerialization.jsonObject(with: current) as! [String: Any]
        partial["coverage"] = ["complete": false, "errors": 1]
        var entries = partial["entries"] as! [[String: Any]]
        for i in entries.indices { entries[i]["complete"] = false }
        partial["entries"] = entries
        let partialData = try JSONSerialization.data(withJSONObject: partial)
        let uncertain = try SnapshotIO.compare(baseline: saved, current: partialData)
        precondition(!uncertain.complete)
        precondition(uncertain.changes.allSatisfy { $0.status == "uncertain" && $0.delta == "Unknown" },
                     "An inaccessible folder must not appear as space freed in the UI")

        let bad = fixture.appendingPathComponent("invalid.json")
        try Data("{\"schema_version\":99}".utf8).write(to: bad)
        do {
            _ = try SnapshotIO.compare(baseline: bad, current: current)
            preconditionFailure("A foreign format must fail visibly")
        } catch { precondition(!error.localizedDescription.isEmpty) }
        precondition(ScanDifference.size(UInt64.max).hasSuffix(" B"))
        precondition(ScanDifference.delta(before: 10, after: 0).hasPrefix("−"))

        // Optional real SwiftUI rendering for visual review, without launching
        // the app, discovering agents or scanning anything outside the fixture.
        if CommandLine.arguments.count > 1 {
            _ = NSApplication.shared
            let view = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
                Text("What grew?").font(.title2.bold())
                ScanDifferenceResults(diff: diff)
            }.padding(24).frame(width: 800, height: 460).preferredColorScheme(.dark))
            view.frame = NSRect(x: 0, y: 0, width: 800, height: 460)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(300))
            view.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
            window.orderOut(nil)
        }
        print("PASS: snapshot save/compare through the real Rust bridge, private no-clobber files, growth/removal, invalid input and display bounds")
    }
}
