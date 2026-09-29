import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Rust engine owns the inventory format and comparison rules for both UIs.
nonisolated enum SnapshotIO {
    static let maxFileBytes = 64 * 1024 * 1024

    static func failure(_ message: String) -> NSError {
        NSError(domain: "BlitzTree.Snapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func consume(_ pointer: UnsafeMutablePointer<CChar>?) throws -> Data {
        guard let pointer else { throw failure("The snapshot could not be created.") }
        defer { bz_json_free(pointer) }
        let data = Data(bytes: pointer, count: strlen(pointer))
        struct Envelope: Decodable { let error: Detail? }
        struct Detail: Decodable { let message: String }
        if let error = try JSONDecoder().decode(Envelope.self, from: data).error {
            throw failure(error.message)
        }
        return data
    }

    static func compare(baseline url: URL, current: Data) throws -> ScanDifference {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw failure("Choose a regular JSON snapshot file.")
        }
        // Bound the read even if another process is extending this file.
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let data = try input.read(upToCount: maxFileBytes + 1) ?? Data()
        guard data.count <= maxFileBytes else { throw failure("The snapshot exceeds the 64 MB limit.") }
        guard !data.contains(0), !current.contains(0),
              let before = String(data: data, encoding: .utf8),
              let after = String(data: current, encoding: .utf8) else {
            throw failure("The snapshot must be valid UTF-8 JSON.")
        }
        let result = try before.withCString { a in
            try after.withCString { b in try consume(bz_compare_snapshots(a, b, 100)) }
        }
        return try JSONDecoder().decode(ScanDifference.self, from: result)
    }
}

nonisolated struct ScanDifference: Decodable, Sendable {
    struct Change: Decodable, Identifiable, Sendable {
        let path: String
        let before_bytes: UInt64?
        let after_bytes: UInt64?
        let status: String
        var id: String { path }

        var delta: String {
            guard status != "uncertain" else { return "Unknown" }
            return ScanDifference.delta(before: before_bytes ?? 0, after: after_bytes ?? 0)
        }
    }

    let root: String
    let complete: Bool
    let before_generated_at_unix: UInt64
    let after_generated_at_unix: UInt64
    let before_bytes: UInt64
    let after_bytes: UInt64
    let total_changes: Int
    let changes: [Change]

    static func size(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        // Saved files are untrusted input; avoid Fmt.size's signed conversion.
        guard bytes <= UInt64(Int64.max) else { return "\(bytes.formatted()) B" }
        return Fmt.size(bytes)
    }

    static func delta(before: UInt64, after: UInt64) -> String {
        if after == before { return "0 B" }
        return after > before ? "+" + size(after - before) : "−" + size(before - after)
    }
}

/// Explicit save/compare only: no background scans or automatic history files.
struct ScanComparisonView: View {
    let tree: Tree
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false
    @State private var difference: ScanDifference?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("What grew?").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(tree.displayPath(0))
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .lineLimit(2).truncationMode(.middle)
            Text("Save this scan, then compare it with a later scan of the same folder.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Save Snapshot…", action: save).disabled(busy)
                Button("Compare Snapshot…", action: compare).disabled(busy)
                    .help("Compare a saved snapshot with the scan currently on screen")
                if busy { ProgressView().controlSize(.small) }
            }
            if let message {
                Text(message).font(.callout)
                    .foregroundStyle(failed ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
            }
            if let difference {
                ScanDifferenceResults(diff: difference)
            } else {
                ContentUnavailableView("Compare two scans", systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Snapshots contain folder paths and sizes, never file contents."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
        .frame(width: 800, height: 560)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "BlitzTree-\(Date().formatted(.iso8601.year().month().day())).json"
        panel.message = "Choose a new file. Snapshots stay on your Mac and include folder paths."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; message = nil; failed = false
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { [tree] in try tree.saveSnapshot(to: url) }.value
                message = "Saved \(url.lastPathComponent). Rescan later, then compare with this file."
            } catch {
                failed = true; message = error.localizedDescription
            }
            busy = false
        }
    }

    private func compare() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an earlier snapshot of the same folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; message = nil; failed = false; difference = nil
        Task {
            do {
                difference = try await Task.detached(priority: .userInitiated) { [tree] in
                    try SnapshotIO.compare(baseline: url, current: tree.snapshotJSON())
                }.value
            } catch {
                failed = true; message = error.localizedDescription
            }
            busy = false
        }
    }
}

struct ScanDifferenceResults: View {
    let diff: ScanDifference

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(diff.complete
                 ? "Total change: \(ScanDifference.delta(before: diff.before_bytes, after: diff.after_bytes))"
                 : "Partial scans: unknown changes are not counted as space freed.")
                .font(.headline)
            Text("\(date(diff.before_generated_at_unix)) → \(date(diff.after_generated_at_unix))")
                .font(.caption).foregroundStyle(.secondary)
            Table(diff.changes) {
                TableColumn("Folder") { change in
                    Text(change.path == "." ? "Entire scan" : change.path)
                        .lineLimit(1).truncationMode(.middle).help(change.path)
                        .textSelection(.enabled)
                }.width(min: 220)
                TableColumn("Before") { Text(ScanDifference.size($0.before_bytes)).monospacedDigit() }
                    .width(90)
                TableColumn("Now") { Text(ScanDifference.size($0.after_bytes)).monospacedDigit() }
                    .width(90)
                TableColumn("Change") { Text($0.delta).monospacedDigit() }.width(100)
                TableColumn("Status") { Text($0.status.capitalized).foregroundStyle(.secondary) }.width(80)
            }
            if diff.total_changes == 0 { Text("No folder-size changes found.").foregroundStyle(.secondary) }
            Text("Showing \(diff.changes.count) of \(diff.total_changes) changes. Folder sizes include their children; do not add these rows together.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func date(_ seconds: UInt64) -> String {
        Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .abbreviated, time: .shortened)
    }

}
