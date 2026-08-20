import AppKit
import Foundation
import Observation

/// Zero-copy view over the Rust engine's flat tree arrays.
final class Tree {
    private let handle: OpaquePointer
    let count: Int
    let parents: UnsafePointer<UInt32>
    let alloc: UnsafePointer<UInt64>
    let logical: UnsafePointer<UInt64>
    let nFiles: UnsafePointer<UInt32>
    let flags: UnsafePointer<UInt8>
    let childOff: UnsafePointer<UInt32>
    let childArr: UnsafePointer<UInt32>
    let nameOff: UnsafePointer<UInt32>
    let nameBlob: UnsafePointer<UInt8>
    let errors: UInt64

    init?(handle: OpaquePointer) {
        let n = bz_take_tree(handle)
        guard n > 0,
              let parents = bz_parents(handle),
              let alloc = bz_alloc(handle),
              let logical = bz_logical(handle),
              let nFiles = bz_nfiles(handle),
              let flags = bz_flags(handle),
              let childOff = bz_child_off(handle),
              let childArr = bz_children(handle),
              let nameOff = bz_name_off(handle),
              let nameBlob = bz_name_blob(handle)
        else { return nil }
        self.handle = handle
        self.count = Int(n)
        self.parents = parents
        self.alloc = alloc
        self.logical = logical
        self.nFiles = nFiles
        self.flags = flags
        self.childOff = childOff
        self.childArr = childArr
        self.nameOff = nameOff
        self.nameBlob = nameBlob
        self.errors = bz_errors(handle)
    }

    deinit { bz_free(handle) }

    func isDir(_ i: Int) -> Bool { flags[i] & 1 != 0 }

    func name(_ i: Int) -> String {
        let start = Int(nameOff[i])
        let end = Int(nameOff[i + 1])
        let buf = UnsafeBufferPointer(start: nameBlob + start, count: end - start)
        return String(decoding: buf, as: UTF8.self)
    }

    func children(_ i: Int) -> UnsafeBufferPointer<UInt32> {
        let start = Int(childOff[i])
        let end = Int(childOff[i + 1])
        return UnsafeBufferPointer(start: childArr + start, count: end - start)
    }

    /// Human-facing path: the Data-volume firmlink prefix reads as "/".
    func displayPath(_ i: Int) -> String {
        let p = path(i)
        let prefix = "/System/Volumes/Data"
        if p.hasPrefix(prefix) {
            let rest = String(p.dropFirst(prefix.count))
            return rest.isEmpty ? "/" : rest
        }
        return p
    }

    /// Full path: root's name is the scanned path itself.
    func path(_ i: Int) -> String {
        var parts: [String] = []
        var cur = i
        while cur != 0 {
            parts.append(name(cur))
            cur = Int(parents[cur])
            if cur == Int(UInt32.max) { break }
        }
        var p = name(0)
        if p.hasSuffix("/") { p.removeLast() }
        for part in parts.reversed() { p += "/" + part }
        return p
    }

    /// Chain of ancestors from root to node (inclusive), for breadcrumbs.
    func ancestry(_ i: Int) -> [Int] {
        var chain = [i]
        var cur = i
        while cur != 0 && cur != Int(UInt32.max) {
            cur = Int(parents[cur])
            chain.append(cur)
        }
        return chain.reversed()
    }
}

enum FDA {
    /// FDA-protected paths deny silently (no dialog), so probing is safe.
    static func isActive() -> Bool {
        let home = NSHomeDirectory()
        for p in ["\(home)/Library/Messages", "\(home)/Library/Mail", "\(home)/Library/Safari"] {
            if (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil {
                return true
            }
        }
        return false
    }

    @MainActor
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }
}

@Observable
@MainActor
final class ScanModel {
    var files: UInt64 = 0
    var dirs: UInt64 = 0
    var bytes: UInt64 = 0
    var scanning = false
    var elapsed: Double = 0
    var tree: Tree?
    var scanRoot: String = {
        // `BlitzTree /some/path` scans that path on launch (also handy for QA).
        if CommandLine.arguments.count > 1 {
            var isDir: ObjCBool = false
            let p = (CommandLine.arguments[1] as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                return p
            }
        }
        // Whole disk by default: the user-data volume of the boot volume group.
        return "/System/Volumes/Data"
    }()
    var viewRoot: Int = 0
    var selection: Int? = nil
    var hovered: Int? = nil
    var freeBytes: UInt64 = 0
    /// Volume-used minus what the scan could see: root-only territory.
    var unscannedBytes: UInt64 = 0
    var showFreeSpace: Bool = UserDefaults.standard.bool(forKey: "bz.showFree") {
        didSet { UserDefaults.standard.set(showFreeSpace, forKey: "bz.showFree") }
    }

    private var handle: OpaquePointer?
    private var timer: Timer?
    private var startedAt: Date?
    private var activity: NSObjectProtocol?

    func startScan(path: String? = nil) {
        if scanning { return }
        if let path { scanRoot = path }
        tree = nil
        viewRoot = 0
        selection = nil
        hovered = nil
        files = 0; dirs = 0; bytes = 0; elapsed = 0
        scanning = true
        startedAt = Date()
        // Keep the process out of App Nap / timer coalescing while scanning.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Disk scan"
        )
        handle = bz_scan_start(scanRoot)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        guard let handle else { return }
        var f: UInt64 = 0, d: UInt64 = 0, b: UInt64 = 0
        var done: Int32 = 0
        bz_progress(handle, &f, &d, &b, &done)
        files = f; dirs = d; bytes = b
        elapsed = -(startedAt?.timeIntervalSinceNow ?? 0)
        if done != 0 {
            timer?.invalidate()
            timer = nil
            tree = Tree(handle: handle)
            self.handle = nil // Tree owns it now
            scanning = false
            if let tree {
                NSLog("BZ scan done: %llu nodes, %llu unreadable dirs", UInt64(tree.count), tree.errors)
            }
            if let vals = try? URL(fileURLWithPath: scanRoot).resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
               let free = vals.volumeAvailableCapacityForImportantUsage {
                freeBytes = UInt64(max(0, free))
            }
            // Coverage honesty: compare scanned bytes with what the volume
            // says it holds. The difference is root-only space (Spotlight
            // index, unified logs, …) no unelevated app can read.
            unscannedBytes = 0
            if scanRoot == "/System/Volumes/Data", let tree,
               let attrs = try? FileManager.default.attributesOfFileSystem(forPath: scanRoot),
               let total = (attrs[.systemSize] as? NSNumber)?.uint64Value,
               let free = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value {
                let used = total > free ? total - free : 0
                let seen = tree.alloc[0]
                if used > seen {
                    unscannedBytes = used - seen
                }
            }
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        }
    }
}

enum Fmt {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    static func size(_ b: UInt64) -> String { bytes.string(fromByteCount: Int64(b)) }
    static func num(_ n: UInt64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
