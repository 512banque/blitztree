import AppKit
import Foundation
import Observation
import SwiftUI

// "Clean up with Claude Code / Codex": the agent runs headless in the
// background, read-only, and only writes a plan from the scan BlitzTree
// already has. Its steps and plan cards stream into the side panel as they
// happen. BlitzTree then does the cleanup itself, behind its own guards:
// moving folders to the Trash or running the owning tool's cleanup command.

// MARK: - Agents on this Mac

nonisolated enum AgentKind: String, CaseIterable, Sendable {
    case claude, codex

    var name: String { self == .claude ? "Claude Code" : "Codex" }
}

nonisolated struct InstalledAgent: Identifiable, Hashable, Sendable {
    let kind: AgentKind
    /// Absolute path to the CLI.
    let path: String
    /// Signed in to an account, so a run can start right away.
    let signedIn: Bool
    var id: String { kind.rawValue }
}

nonisolated struct AgentEnvironment: Sendable {
    var agents: [InstalledAgent] = []
    /// The user's shell PATH: cleanup tools live in Homebrew, ~/.local/bin,
    /// nvm… none of which an app's PATH has.
    var path: String = "/usr/bin:/bin:/usr/sbin:/sbin"
    /// Set once the lookup has finished (an empty list then means none).
    var loaded = false

    var ready: [InstalledAgent] { agents.filter(\.signedIn) }
}

nonisolated enum AgentLocator {
    nonisolated(unsafe) private static var qaFaked = false

    /// Asks the user's interactive login shell once where the CLIs are and
    /// what its PATH is, falls back to the usual install locations, then
    /// checks each one is signed in.
    static func find() async -> AgentEnvironment {
        await Task.detached(priority: .userInitiated) { locate() }.value
    }

    private static func locate() -> AgentEnvironment {
        var env = AgentEnvironment(loaded: true)
        // QA: pretend neither agent is installed, to see the setup offer.
        if ProcessInfo.processInfo.environment["BZ_QA_NO_AGENTS"] != nil, !qaFaked {
            qaFaked = true
            return env
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let text = run(shell, ["-lic", "echo \"BZPATH=$PATH\"; command -v claude; command -v codex"]).out
        var fromShell: [AgentKind: String] = [:]
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("BZPATH=") { env.path = String(line.dropFirst(7)) }
            guard line.hasPrefix("/") else { continue }
            for kind in AgentKind.allCases where line.hasSuffix("/\(kind.rawValue)") {
                fromShell[kind] = fromShell[kind] ?? line
            }
        }
        let home = NSHomeDirectory()
        // Where BlitzTree's own setup installs them, even if no shell knows yet.
        if !env.path.split(separator: ":").contains("\(home)/.local/bin"[...]) {
            env.path += ":\(home)/.local/bin"
        }
        let fallbacks: [AgentKind: [String]] = [
            .claude: ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                      "/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
            .codex: ["\(home)/.nvm/current/bin/codex", "\(home)/.local/bin/codex", "/opt/homebrew/bin/codex",
                     "/usr/local/bin/codex", "\(home)/.bun/bin/codex"],
        ]
        let found: [(AgentKind, String)] = AgentKind.allCases.compactMap { kind in
            let candidates = [fromShell[kind]].compactMap { $0 } + (fallbacks[kind] ?? [])
            guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            else { return nil }
            return (kind, path)
        }
        // Both checks at once; each takes a fraction of a second.
        var signedIn = [Bool](repeating: false, count: found.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: found.count) { i in
            let ok = isSignedIn(found[i].0, path: found[i].1, envPath: env.path)
            lock.lock(); signedIn[i] = ok; lock.unlock()
        }
        env.agents = found.enumerated().map { i, pair in
            InstalledAgent(kind: pair.0, path: pair.1, signedIn: signedIn[i])
        }
        return env
    }

    static func isSignedIn(_ kind: AgentKind, path: String, envPath: String) -> Bool {
        switch kind {
        case .claude:
            let r = run(path, ["auth", "status"], envPath: envPath)
            return r.out.contains("\"loggedIn\": true") || r.out.contains("\"loggedIn\":true")
        case .codex:
            return run(path, ["login", "status"], envPath: envPath).status == 0
        }
    }

    static func run(_ exe: String, _ args: [String], envPath: String? = nil,
                    timeout: TimeInterval = 5) -> (out: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        if let envPath {
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = envPath
            process.environment = environment
        }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return ("", -1) }
        // A slow shell profile shouldn't hold the panel up.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return ("", -1) }
        return (String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                process.terminationStatus)
    }
}

// MARK: - One-click setup

/// Installs an agent into ~/.local/bin and signs it in through the browser,
/// all in the background; the panel shows where it is.
@Observable
@MainActor
final class AgentSetup {
    enum Step: Equatable { case installing, signingIn, failed(String) }

    let kind: AgentKind
    private(set) var step: Step
    private var process: Process?
    private var cancelled = false

    init(kind: AgentKind, installed: InstalledAgent?, envPath: String,
         done: @escaping (AgentEnvironment) -> Void) {
        self.kind = kind
        step = installed == nil ? .installing : .signingIn
        Task {
            var path = installed?.path
            if path == nil {
                let target = NSHomeDirectory() + "/.local/bin/" + kind.rawValue
                if let error = await shell(Self.installScript(kind)) {
                    if !cancelled { step = .failed("Couldn't install \(kind.name): \(error)") }
                    return
                }
                path = target
            }
            guard let path, !cancelled else { return }
            if !AgentLocator.isSignedIn(kind, path: path, envPath: envPath) {
                step = .signingIn
                // Opens the browser; the CLI finishes once the sign-in comes back.
                _ = await exec(path, kind == .claude ? ["auth", "login"] : ["login"], envPath: envPath)
                guard !cancelled else { return }
                if !AgentLocator.isSignedIn(kind, path: path, envPath: envPath) {
                    step = .failed("Sign-in didn't finish. Try again.")
                    return
                }
            }
            done(await AgentLocator.find())
        }
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    private static func installScript(_ kind: AgentKind) -> String {
        switch kind {
        case .claude:
            // Anthropic's own installer: everything under ~/.local, no sudo.
            return "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex:
            // OpenAI's standalone build: no Node needed.
            return """
            set -e; t=$(mktemp -d); mkdir -p "$HOME/.local/bin"
            curl -fsSL https://github.com/openai/codex/releases/latest/download/codex-aarch64-apple-darwin.tar.gz | tar -xz -C "$t"
            mv "$t/codex-aarch64-apple-darwin" "$HOME/.local/bin/codex"; rm -rf "$t"
            """
        }
    }

    /// Runs a script; returns the last error line on failure.
    private func shell(_ script: String) async -> String? {
        await exec("/bin/bash", ["-c", script], envPath: "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    private func exec(_ exe: String, _ args: [String], envPath: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = envPath
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        process.standardError = err
        let tail = ErrTail()
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { tail.feed(data) }
        }
        do { try process.run() } catch { return error.localizedDescription }
        self.process = process
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { process.waitUntilExit(); c.resume() }
        }
        self.process = nil
        return process.terminationStatus == 0 ? nil : (tail.last.isEmpty ? "exit \(process.terminationStatus)" : tail.last)
    }
}

// MARK: - The plan

nonisolated struct PlanItemSpec: Decodable, Sendable {
    let title: String
    let detail: String
    let group: String
    let bytes: Int64
    let paths: [String]
    let action: String
    let command: String
}

/// The JSON shape both agents must answer in (Claude: --json-schema, Codex:
/// --output-schema; strict, so every field is required).
nonisolated let planSchema = """
{"type":"object","additionalProperties":false,"required":["summary","items"],"properties":{\
"summary":{"type":"string"},"items":{"type":"array","items":{"type":"object","additionalProperties":false,\
"required":["title","detail","group","bytes","paths","action","command"],"properties":{\
"title":{"type":"string"},"detail":{"type":"string"},"group":{"type":"string","enum":["safe","ask"]},\
"bytes":{"type":"integer"},"paths":{"type":"array","items":{"type":"string"}},\
"action":{"type":"string","enum":["trash","command"]},"command":{"type":"string"}}}}}}
"""

/// Pulls finished item objects out of the plan JSON while it is still being
/// written, so cards appear one by one instead of all at the end.
nonisolated struct PartialPlanParser {
    private(set) var text = ""
    private var emitted = 0

    mutating func append(_ chunk: String) -> [PlanItemSpec] {
        text += chunk
        guard let itemsKey = text.range(of: "\"items\"") else { return [] }
        let chars = Array(text[itemsKey.upperBound...].utf8)
        var i = 0
        while i < chars.count, chars[i] != UInt8(ascii: "[") { i += 1 }
        var depth = 0, inString = false, escaped = false, start = -1
        var objects: [[UInt8]] = []
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false } else if c == UInt8(ascii: "\\") { escaped = true } else if c == UInt8(ascii: "\"") { inString = false }
            } else if c == UInt8(ascii: "\"") {
                inString = true
            } else if c == UInt8(ascii: "{") {
                if depth == 0 { start = i }
                depth += 1
            } else if c == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0, start >= 0 { objects.append(Array(chars[start...i])) }
            } else if c == UInt8(ascii: "]"), depth == 0 {
                break
            }
            i += 1
        }
        guard objects.count > emitted else { return [] }
        let fresh = objects[emitted...].compactMap { try? JSONDecoder().decode(PlanItemSpec.self, from: Data($0)) }
        emitted = objects.count
        return fresh
    }
}

// MARK: - Guards (enforced here, never left to the model)

nonisolated enum CleanupGuard {
    static let home = NSHomeDirectory()

    /// Folders BlitzTree never cleans, whatever the agent says.
    static let protected = [
        "Documents", "Desktop", "Pictures", "Movies", "Music", ".ssh", ".gnupg", ".Trash",
        "Library/Mobile Documents", "Library/Mail", "Library/Messages", "Library/Keychains",
        "Library/Photos", "Library/CloudStorage",
    ].map { home + "/" + $0 }

    /// Build output and installs that a tool recreates, allowed even inside a
    /// protected folder (a project in ~/Documents still has a node_modules).
    static let rebuildable: Set<String> = [
        "node_modules", ".venv", "venv", "target", ".next", ".turbo", ".nuxt", ".svelte-kit",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", "DerivedData", ".gradle",
        ".parcel-cache", ".expo", "Pods",
    ]

    /// Folders that hold other apps' live data: only named subfolders go.
    static let tooBroad: Set<String> = [
        "Library", "Library/Caches", "Library/Application Support", "Library/Containers",
        "Library/Group Containers", "Library/Developer", "Library/Preferences", ".config", ".cache",
        "Library/Developer/CoreSimulator", "Library/Developer/CoreSimulator/Devices",
        ".local", ".local/share", "Downloads",
    ].reduce(into: []) { $0.insert(home + "/" + $1) }

    /// The only commands BlitzTree runs: each tool's own cleanup.
    static let commands = [
        "uv cache clean", "uv cache prune", "bun pm cache rm", "npm cache clean", "pnpm store prune",
        "yarn cache clean", "brew cleanup", "brew autoremove", "docker system prune",
        "docker image prune", "docker builder prune", "docker container prune",
        "xcrun simctl delete unavailable", "xcrun simctl runtime delete", "pip cache purge",
        "pip3 cache purge", "ollama rm ", "go clean -cache", "go clean -modcache", "gem cleanup",
        "pod cache clean", "conda clean", "mamba clean",
    ]

    /// Why a path may not be touched, or nil when it may.
    static func blockReason(path: String) -> String? {
        let p = (path as NSString).standardizingPath
        guard p.hasPrefix(home + "/") else { return "Outside your home folder" }
        let rel = p.dropFirst(home.count + 1)
        guard rel.split(separator: "/").count >= 2 || rel.hasPrefix("."), !tooBroad.contains(p) else {
            return "Too broad: other apps keep live data here"
        }
        for dir in protected where p == dir || p.hasPrefix(dir + "/") {
            // Projects live in Documents too; their build output is still fair game.
            if !rebuildable.contains((p as NSString).lastPathComponent) || dir.hasSuffix(".Trash") {
                return "In ~/\(dir.dropFirst(home.count + 1)), which BlitzTree never cleans"
            }
        }
        if FileManager.default.fileExists(atPath: p + "/.git") { return "A git repository" }
        return nil
    }

    static func blockReason(command: String) -> String? {
        let c = command.trimmingCharacters(in: .whitespaces)
        guard commands.contains(where: { c == $0.trimmingCharacters(in: .whitespaces) || c.hasPrefix($0.hasSuffix(" ") ? $0 : $0 + " ") }) else {
            return "BlitzTree only runs tools' own cleanup commands"
        }
        let banned = [";", "|", "&", ">", "<", "`", "$", "\n", "*", "\\"]
        if banned.contains(where: { c.contains($0) }) { return "Command not allowed" }
        return nil
    }

    /// An app that must be quit before its files go, when one is running.
    @MainActor
    static func runningOwner(of paths: [String]) -> String? {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let id = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            for path in paths {
                let parts = path.split(separator: "/").map(String.init)
                if !id.isEmpty, parts.contains(where: { $0 == id || $0.hasPrefix(id + ".") }) { return name }
                if name.count > 2, parts.contains(name) { return name }
            }
        }
        return nil
    }
}

// MARK: - Run model

@Observable
@MainActor
final class PlanItem: Identifiable {
    /// `inTrash`: step one done, put back or deleted in step two.
    enum Status: Equatable { case waiting, running, inTrash, done, failed(String), skipped }

    let id = UUID()
    let spec: PlanItemSpec
    let paths: [String]
    /// Why BlitzTree won't do this one (protected folder, bad command…).
    let blocked: String?
    var selected: Bool
    var status: Status = .waiting
    /// Space this item gave back to the disk (commands, emptied Trash).
    var freed: UInt64 = 0
    /// Where its folders went in the Trash, for "Empty Trash".
    var trashed: [URL] = []
    var trashedBytes: UInt64 = 0

    /// Size from the scan where it can be measured, else the agent's figure.
    let bytes: UInt64
    /// Its folders in the scan the plan was made from, for the treemap.
    let nodes: [Int]

    init(spec: PlanItemSpec, tree: Tree) {
        self.spec = spec
        let asked = spec.paths.map { ($0 as NSString).expandingTildeInPath }
        var reason: String?
        var kept: [String] = []
        if spec.action == "command" {
            reason = CleanupGuard.blockReason(command: spec.command)
            kept = asked
        } else {
            // Paths BlitzTree won't touch are dropped; the card is blocked only
            // when nothing is left.
            for path in asked {
                if let why = CleanupGuard.blockReason(path: path) {
                    reason = reason ?? why
                } else if let app = CleanupGuard.runningOwner(of: [path]) {
                    reason = reason ?? "Quit \(app) to clean this"
                } else if FileManager.default.fileExists(atPath: path) {
                    kept.append(path)
                } else {
                    reason = reason ?? "Already gone"
                }
            }
            if !kept.isEmpty { reason = nil }
        }
        paths = kept.isEmpty ? asked : kept
        blocked = reason
        selected = reason == nil && spec.group == "safe"

        // Measured sizes, not counting a path inside another listed one twice.
        let nodes = Set(paths.compactMap { tree.node(at: $0) })
        let outer = nodes.filter { node in !tree.ancestry(node).dropLast().contains(where: nodes.contains) }
        let measured = outer.reduce(UInt64(0)) { $0 + tree.alloc[$1] }
        self.nodes = Array(outer)
        bytes = spec.action == "trash" && measured > 0 ? measured : UInt64(max(0, spec.bytes))
    }

    var isCommand: Bool { spec.action == "command" }
}

@Observable
@MainActor
final class AgentRun {
    /// Two decisions from the user: `planned` → Move to Trash (can be undone)
    /// → `staged` → Delete for good → `done`.
    enum Phase: Equatable { case thinking, planned, trashing, staged, deleting, done, failed(String) }

    let agent: InstalledAgent
    private(set) var phase: Phase = .thinking
    /// What the agent has done so far, in plain words; the last one is live.
    private(set) var steps: [String] = ["Reading your scan"]
    private(set) var summary = ""
    private(set) var items: [PlanItem] = []
    private(set) var startedAt = Date()
    private(set) var planSeconds: Double?
    private(set) var current: UUID?

    private var process: Process?
    private let scanRoot: String
    private let tree: Tree
    private let onFinish: () -> Void

    init(agent: InstalledAgent, env: AgentEnvironment, tree: Tree, scanRoot: String,
         known: [CleanupItem], onFinish: @escaping () -> Void) {
        self.agent = agent
        self.scanRoot = scanRoot
        self.tree = tree
        self.onFinish = onFinish
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.localizedName.map { "\($0) (\(app.bundleIdentifier ?? "?"))" } }
        Task {
            let input = await Task.detached(priority: .userInitiated) {
                AgentPrompt.build(tree: tree, scanRoot: scanRoot, known: known, running: running)
            }.value
            step("Asking \(agent.kind.name) what can go")
            start(input: input, env: env)
        }
    }

    /// Folders to light up on the treemap: what the plan would remove.
    func highlights(in shown: Tree?) -> [Int] {
        guard shown === tree, phase != .done else { return [] }
        return items.filter { $0.selected && $0.blocked == nil && $0.status != .done }
            .flatMap(\.nodes)
    }

    /// What step one moves to the Trash (tool caches wait for step two).
    var trashBytes: UInt64 { targets.filter { !$0.isCommand }.reduce(0) { $0 + $1.bytes } }
    /// What step two deletes for good.
    var pendingBytes: UInt64 {
        targets.filter { $0.status == .inTrash || ($0.isCommand && $0.status == .waiting) }.reduce(0) { $0 + $1.bytes }
    }
    /// The items the user chose and BlitzTree may touch.
    var targets: [PlanItem] { items.filter { $0.selected && $0.blocked == nil } }

    var selectedBytes: UInt64 { items.filter(\.selected).reduce(0) { $0 + $1.bytes } }
    var freed: UInt64 { items.reduce(0) { $0 + $1.freed } }
    var inTrash: UInt64 { items.reduce(0) { $0 + $1.trashedBytes } }

    private func step(_ text: String) {
        guard steps.last != text else { return }
        withAnimation(.snappy) { steps.append(text) }
    }

    /// `defaults write dev.ahmed.blitztree bz.claudeModel haiku` to try another.
    private static var claudeModel: String {
        ProcessInfo.processInfo.environment["BZ_CLAUDE_MODEL"]
            ?? UserDefaults.standard.string(forKey: "bz.claudeModel") ?? "sonnet"
    }

    func cancel() {
        process?.terminate()
        process = nil
    }

    // MARK: Agent process

    private func start(input: String, env: AgentEnvironment) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BlitzTree", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: agent.path)
        // An empty working folder: no project settings, hooks or memory load.
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = env.path
        process.environment = environment

        switch agent.kind {
        case .claude:
            process.arguments = [
                "-p", "--setting-sources", "project", "--output-format", "stream-json", "--verbose",
                "--include-partial-messages", "--model", Self.claudeModel, "--effort", "low",
                "--tools", "Bash,Read", "--permission-mode", "dontAsk", "--no-session-persistence",
                "--allowedTools", "Bash(du:*)", "Bash(ls:*)", "Bash(stat:*)", "Bash(docker system df:*)",
                "Bash(xcrun simctl list:*)", "Bash(ollama list:*)", "Read",
                "--json-schema", planSchema,
            ]
        case .codex:
            // The app server, not `codex exec`: only it streams the answer as
            // it is written, so cards can appear one by one.
            process.arguments = ["app-server"]
        }

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Main queue, not Tasks: events must land in the order they were read.
        let writer = stdin.fileHandleForWriting
        let reader = AgentStreamReader(kind: agent.kind, prompt: input, folder: folder.path,
                                       write: { data in try? writer.write(contentsOf: data) },
                                       done: { [weak process] in process?.terminate() }) { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }
        // The run ends once the process has exited and all its output is read.
        let ended = DispatchGroup()
        ended.enter(); ended.enter()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                ended.leave()
            } else {
                reader.feed(data)
            }
        }
        let errTail = ErrTail()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { errTail.feed(data) }
        }
        process.terminationHandler = { _ in ended.leave() }
        ended.notify(queue: .main) { [weak self] in
            let status = process.terminationStatus
            let tail = errTail.last
            MainActor.assumeIsolated { self?.processEnded(status: status, stderr: tail) }
        }
        do {
            try process.run()
        } catch {
            phase = .failed("Couldn't start \(agent.kind.name): \(error.localizedDescription)")
            return
        }
        self.process = process
        if agent.kind == .claude {
            let data = Data(input.utf8)
            DispatchQueue.global(qos: .userInitiated).async {
                try? writer.write(contentsOf: data)
                try? writer.close()
            }
        } else {
            reader.begin()
        }
    }

    private func handle(_ event: AgentStreamReader.Event) {
        guard phase == .thinking else { return }
        switch event {
        case .activity(let text):
            step(text)
        case .item(let spec):
            withAnimation(.snappy) { items.append(PlanItem(spec: spec, tree: tree)) }
        case .restart:
            withAnimation(.snappy) { items = [] }
        case .plan(let summary, let specs):
            self.summary = summary
            // The final JSON is authoritative; keep the cards already shown
            // (and their checkboxes) when they match.
            if specs.map(\.title) != items.map(\.spec.title) {
                withAnimation(.snappy) { items = specs.map { PlanItem(spec: $0, tree: tree) } }
            }
            finishPlanning()
        case .failed(let message):
            phase = .failed(message)
        }
    }

    private func processEnded(status: Int32, stderr: String) {
        process = nil
        guard phase == .thinking else { return }
        if !items.isEmpty {
            finishPlanning()
        } else if status != 0 {
            phase = .failed(stderr.isEmpty ? "\(agent.kind.name) stopped (exit \(status))." : stderr)
        } else {
            phase = .failed("\(agent.kind.name) didn't return a plan.")
        }
    }

    private func finishPlanning() {
        planSeconds = -startedAt.timeIntervalSinceNow
        items.sort { $0.bytes > $1.bytes }
        if summary.isEmpty {
            summary = "About \(Fmt.size(items.filter { $0.blocked == nil }.reduce(0) { $0 + $1.bytes })) can go."
        }
        withAnimation(.snappy) { phase = .planned }
    }

    // MARK: Cleaning (BlitzTree does this, not the agent)

    /// Demo recordings only: walk through both steps without touching disk.
    private let dryRun = ProcessInfo.processInfo.environment["BZ_DEMO_DRYRUN"] != nil

    /// Step one: move the chosen folders to the Trash. Nothing is deleted.
    func moveToTrash() {
        guard phase == .planned else { return }
        phase = .trashing
        for item in items where !(item.selected && item.blocked == nil) { item.status = .skipped }
        Task {
            for item in targets where !item.isCommand {
                current = item.id
                item.status = .running
                if dryRun {
                    try? await Task.sleep(for: .milliseconds(300))
                    item.trashedBytes = item.bytes
                    item.status = .inTrash
                    continue
                }
                var failures: [String] = []
                for path in item.paths where FileManager.default.fileExists(atPath: path) {
                    do {
                        var out: NSURL?
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &out)
                        if let out { item.trashed.append(out as URL) }
                    } catch {
                        failures.append(error.localizedDescription)
                    }
                }
                item.trashedBytes = item.trashed.isEmpty ? 0 : item.bytes
                item.status = failures.isEmpty ? .inTrash : .failed(failures[0])
            }
            current = nil
            withAnimation(.snappy) { phase = .staged }
        }
    }

    /// Step two: delete for good what step one trashed, and run the tools'
    /// own cache cleanups. Only this run's items; the rest of the Trash stays.
    func deleteForGood(env: AgentEnvironment) {
        guard phase == .staged else { return }
        phase = .deleting
        Task {
            for item in targets where item.status == .inTrash || (item.isCommand && item.status == .waiting) {
                current = item.id
                item.status = .running
                if dryRun {
                    try? await Task.sleep(for: .milliseconds(item.isCommand ? 600 : 250))
                    item.freed = item.bytes
                    item.trashedBytes = 0
                    item.status = .done
                    continue
                }
                let before = Self.freeBytes()
                var error: String?
                if item.isCommand {
                    error = await Self.runCommand(item.spec.command, path: env.path)
                } else {
                    let urls = item.trashed
                    await Task.detached(priority: .userInitiated) {
                        for url in urls { try? FileManager.default.removeItem(at: url) }
                    }.value
                    item.trashed = []
                    item.trashedBytes = 0
                }
                let after = Self.freeBytes()
                item.freed = after > before ? after - before : 0
                item.status = error.map { .failed($0) } ?? .done
            }
            current = nil
            withAnimation(.snappy) { phase = .done }
            if !dryRun { onFinish() }
        }
    }

    /// Plain available space (statfs), exact to the block.
    nonisolated static func freeBytes() -> UInt64 {
        var fs = statfs()
        guard statfs(NSHomeDirectory(), &fs) == 0 else { return 0 }
        return UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
    }

    /// Runs a vetted cleanup command; returns an error message on failure.
    nonisolated static func runCommand(_ command: String, path: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = path
            process.environment = environment
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
            process.standardInput = FileHandle.nullDevice
            let err = Pipe()
            process.standardError = err
            process.standardOutput = FileHandle.nullDevice
            do { try process.run() } catch { return error.localizedDescription }
            let deadline = Date().addingTimeInterval(600)
            while process.isRunning, Date() < deadline { usleep(100_000) }
            if process.isRunning { process.terminate(); return "Took too long" }
            guard process.terminationStatus != 0 else { return nil }
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return text.split(separator: "\n").last.map(String.init) ?? "Exited with \(process.terminationStatus)"
        }.value
    }
}

/// Keeps the last line of an agent's stderr for error messages.
nonisolated final class ErrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func feed(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        text = String((text + String(decoding: data, as: UTF8.self)).suffix(2000))
    }
    var last: String {
        lock.lock(); defer { lock.unlock() }
        return text.split(separator: "\n").map(String.init)
            .last(where: { !$0.contains("rmcp::") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
    }
}

// MARK: - Reading the agent's event stream

/// Turns Claude Code's stream-json or Codex's --json lines into a few events.
nonisolated final class AgentStreamReader: @unchecked Sendable {
    enum Event: Sendable {
        case activity(String)
        case item(PlanItemSpec)
        /// The agent started the plan over (its first try failed validation).
        case restart
        case plan(summary: String, items: [PlanItemSpec])
        case failed(String)
    }

    private let kind: AgentKind
    private let prompt: String
    private let folder: String
    private let write: @Sendable (Data) -> Void
    private let done: @Sendable () -> Void
    private let emit: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var pending = Data()
    private var parser = PartialPlanParser()
    private var inPlan = false

    init(kind: AgentKind, prompt: String, folder: String, write: @escaping @Sendable (Data) -> Void,
         done: @escaping @Sendable () -> Void, emit: @escaping @Sendable (Event) -> Void) {
        self.kind = kind
        self.prompt = prompt
        self.folder = folder
        self.write = write
        self.done = done
        self.emit = emit
    }

    /// Codex app server: say hello; the rest follows its replies.
    func begin() {
        send(["id": 1, "method": "initialize",
              "params": ["clientInfo": ["name": "blitztree", "title": "BlitzTree", "version": "1"]]])
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(UInt8(ascii: "\n"))
        write(data)
    }

    func feed(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<nl]
            pending.removeSubrange(pending.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            kind == .claude ? claude(obj) : codex(obj)
        }
    }

    private func claude(_ e: [String: Any]) {
        switch e["type"] as? String {
        case "stream_event":
            guard let ev = e["event"] as? [String: Any] else { return }
            if ev["type"] as? String == "content_block_start",
               let block = ev["content_block"] as? [String: Any] {
                if block["type"] as? String == "tool_use" {
                    inPlan = block["name"] as? String == "StructuredOutput"
                    if inPlan {
                        if !parser.text.isEmpty { emit(.restart) }
                        parser = PartialPlanParser()
                        emit(.activity("Writing the plan"))
                    }
                } else if block["type"] as? String == "thinking" {
                    emit(.activity("Thinking"))
                }
            } else if ev["type"] as? String == "content_block_delta", inPlan,
                      let delta = ev["delta"] as? [String: Any],
                      let chunk = delta["partial_json"] as? String {
                for item in parser.append(chunk) { emit(.item(item)) }
            }
        case "assistant":
            guard let content = (e["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
            for c in content where c["type"] as? String == "tool_use" && c["name"] as? String != "StructuredOutput" {
                let input = c["input"] as? [String: Any] ?? [:]
                emit(.activity(Self.describe(tool: c["name"] as? String ?? "", input: input)))
            }
        case "result":
            if let plan = e["structured_output"] as? [String: Any], let decoded = Self.decodePlan(plan) {
                emit(.plan(summary: decoded.0, items: decoded.1))
            } else if e["is_error"] as? Bool == true || e["subtype"] as? String != "success" {
                emit(.failed((e["result"] as? String) ?? "Claude Code stopped without a plan."))
            }
        default:
            break
        }
    }

    /// Codex app-server JSON-RPC: replies to our requests, then notifications.
    private func codex(_ e: [String: Any]) {
        if let id = e["id"] as? Int, e["method"] == nil {
            if let error = e["error"] as? [String: Any] {
                emit(.failed((error["message"] as? String) ?? "Codex refused the request."))
                done()
                return
            }
            let result = e["result"] as? [String: Any] ?? [:]
            switch id {
            case 1:
                send(["method": "initialized"])
                send(["id": 2, "method": "thread/start", "params": [
                    "cwd": folder, "sandbox": "read-only", "approvalPolicy": "never", "ephemeral": true,
                ]])
            case 2:
                guard let thread = (result["thread"] as? [String: Any])?["id"] as? String else { return }
                let schema = (try? JSONSerialization.jsonObject(with: Data(planSchema.utf8))) ?? [:]
                send(["id": 3, "method": "turn/start", "params": [
                    "threadId": thread, "effort": "low", "outputSchema": schema,
                    "input": [["type": "text", "text": prompt, "text_elements": []]],
                ]])
            default:
                break
            }
            return
        }
        let params = e["params"] as? [String: Any] ?? [:]
        let item = params["item"] as? [String: Any] ?? [:]
        switch (e["method"] as? String, item["type"] as? String) {
        case ("item/started", "commandExecution"):
            emit(.activity(Self.describe(tool: "Bash", input: ["command": item["command"] ?? ""])))
        case ("item/started", "reasoning"):
            emit(.activity("Thinking"))
        case ("item/started", "agentMessage"):
            parser = PartialPlanParser()
        case ("item/agentMessage/delta", _):
            if let delta = params["delta"] as? String {
                if !inPlan, delta.contains("{") || !parser.text.isEmpty {
                    inPlan = true
                    emit(.activity("Writing the plan"))
                }
                for item in parser.append(delta) { emit(.item(item)) }
            }
        case ("item/completed", "agentMessage"):
            if let text = item["text"] as? String,
               let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
               let decoded = Self.decodePlan(obj) {
                emit(.plan(summary: decoded.0, items: decoded.1))
            }
        case ("turn/completed", _):
            let turn = params["turn"] as? [String: Any] ?? [:]
            if let error = turn["error"] as? [String: Any], let message = error["message"] as? String {
                emit(.failed(message))
            }
            done()
        case ("error", _):
            if let error = params["error"] as? [String: Any], let message = error["message"] as? String,
               params["willRetry"] as? Bool != true {
                emit(.failed(message))
                done()
            }
        default:
            break
        }
    }

    private static func decodePlan(_ obj: [String: Any]) -> (String, [PlanItemSpec])? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj["items"] ?? []),
              let items = try? JSONDecoder().decode([PlanItemSpec].self, from: data) else { return nil }
        return ((obj["summary"] as? String) ?? "", items)
    }

    /// "du -sk ~/a ~/b" → "Measuring a, b"; the rest in a few plain words.
    static func describe(tool: String, input: [String: Any]) -> String {
        if tool == "Read", let path = input["file_path"] as? String {
            return "Reading \((path as NSString).lastPathComponent)"
        }
        let command = (input["command"] as? String) ?? ""
        let words = command.split(separator: " ").map(String.init)
        let targets = words.dropFirst().filter { !$0.hasPrefix("-") && $0.contains("/") }
            .map { ($0 as NSString).lastPathComponent }
        let names = targets.prefix(3).joined(separator: ", ") + (targets.count > 3 ? "…" : "")
        switch words.first ?? "" {
        case "du": return names.isEmpty ? "Measuring folders" : "Measuring \(names)"
        case "ls", "stat": return names.isEmpty ? "Looking around" : "Looking in \(names)"
        case "docker": return "Checking Docker"
        case "xcrun": return "Checking Xcode simulators"
        case "ollama": return "Checking Ollama models"
        default: return "Checking \(words.first ?? "")"
        }
    }
}

// MARK: - What the agent is told

nonisolated enum AgentPrompt {
    static func build(tree: Tree, scanRoot: String, known: [CleanupItem], running: [String]) -> String {
        let home = NSHomeDirectory()
        func shown(_ i: Int) -> String { tree.displayPath(i) }

        var folders: [Int] = []
        var files: [Int] = []
        for i in 1..<tree.count {
            let size = tree.alloc[i]
            if tree.isDir(i) {
                guard size >= 100_000_000 else { continue }
                // Skip pass-through folders the next line would repeat.
                if let first = tree.children(i).first, tree.isDir(Int(first)),
                   Double(tree.alloc[Int(first)]) >= 0.95 * Double(size) { continue }
                folders.append(i)
            } else if size >= 250_000_000 {
                files.append(i)
            }
        }
        folders.sort { tree.alloc[$0] > tree.alloc[$1] }
        files.sort { tree.alloc[$0] > tree.alloc[$1] }

        var md = """
        You are the cleanup agent inside BlitzTree, a macOS disk-space app. The user clicked \
        "Clean up" and is watching a live view of your steps, so be fast. Their home folder is \(home).

        Below is BlitzTree's scan (\(scanRoot == "/System/Volumes/Data" ? "whole disk" : scanRoot), \
        allocated sizes, measured seconds ago). Use it; do not re-scan the disk. Most plans need no \
        commands at all. Only check what you really cannot judge from the tables, batched (one \
        `du -sk a b c` beats several), at most 3 commands.

        Return a cleanup plan as JSON (the schema is enforced):
        - summary: one short sentence, e.g. "About 44 GB of caches and build output can go."
        - items, largest first, at most 12. Each item:
          - title: 2-5 plain words ("uv package cache", "Old Playwright browsers").
          - detail: why it is safe, under 90 characters, plain English.
          - group: "safe" = rebuilt or re-downloaded automatically, nothing lost; "ask" = probably \
        fine but the user should decide (old downloads, models, whole old projects).
          - bytes: size in bytes.
          - paths: the absolute paths it covers.
          - action: "command" when the owning tool has its own cleanup and the item is that tool's \
        cache, otherwise "trash" (BlitzTree moves the paths to the Trash itself). BlitzTree only runs \
        commands starting with one of: `uv cache clean`, `bun pm cache rm`, `npm cache clean --force`, \
        `pnpm store prune`, `yarn cache clean`, `brew cleanup --prune=all`, `docker system prune -f`, \
        `docker builder prune -f`, `xcrun simctl delete unavailable`, `pip cache purge`, \
        `ollama rm <model>`, `go clean -modcache`, `gem cleanup`, `pod cache clean --all`, \
        `conda clean -a -y`. Nothing else, no pipes, `;`, `$` or globs; it must not prompt.
          - command: the exact command for "command", "" for "trash".
        Name specific folders. Never a whole ~/Library, ~/Library/Caches, ~/Library/Application \
        Support, ~/Library/Containers, ~/Downloads or ~/.config: list the large subfolders instead.
        Never include: ~/Documents, ~/Desktop, ~/Pictures, the Photos library, ~/Movies, ~/Music, Mail, \
        Messages, iCloud Drive (~/Library/Mobile Documents), keychains, ~/.ssh, dotfile configs, source \
        code, git repositories themselves, or files of the running apps below. Build output inside \
        projects (node_modules, target, .next, dist, DerivedData) is fine.

        ## Apps running now
        \(running.joined(separator: ", "))

        """
        if !known.isEmpty {
            md += "\n## Recognised by BlitzTree as rebuildable\n\n| Size | Path | What |\n|---:|---|---|\n"
            for item in known.prefix(120) {
                md += "| \(Fmt.size(item.bytes)) | \(item.path) | \(item.kind) |\n"
            }
        }
        md += "\n## Largest folders\n\n| Size | Files | Path |\n|---:|---:|---|\n"
        for i in folders.prefix(250) {
            md += "| \(Fmt.size(tree.alloc[i])) | \(Fmt.num(UInt64(tree.nFiles[i]))) | \(shown(i))/ |\n"
        }
        if !files.isEmpty {
            md += "\n## Largest files\n\n| Size | Path |\n|---:|---|\n"
            for i in files.prefix(80) { md += "| \(Fmt.size(tree.alloc[i])) | \(shown(i)) |\n" }
        }
        return md
    }
}

extension Tree {
    /// The node at an absolute path, if the scan covered it.
    func node(at path: String) -> Int? {
        let root = self.path(0)
        var p = (path as NSString).standardizingPath
        // A whole-disk scan is rooted at the Data volume; /Users/… lives there.
        if root == "/System/Volumes/Data", !p.hasPrefix(root + "/") { p = root + p }
        guard p == root || p.hasPrefix(root == "/" ? "/" : root + "/") else { return nil }
        var cur = 0
        for part in p.dropFirst(root.count).split(separator: "/") {
            guard let next = children(cur).first(where: { name(Int($0)) == part }) else { return nil }
            cur = Int(next)
        }
        return cur
    }
}
