import Darwin
import Foundation

@main
@MainActor
enum AgentSetupChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("blitztree-agent-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var childPIDs: [Int32] = []
        defer {
            for pid in childPIDs { _ = kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: root)
        }

        let launchMessage = await failure(for: setup(path: root.appendingPathComponent("missing").path))
        precondition(launchMessage.contains("Couldn't start"), "launch errors should be visible")

        let nonzero = try script(in: root, body: #"printf 'https://auth.openai.com/oauth/authorize?code=secret-code\n'; printf 'provider failed\n' >&2; exit 7"#)
        let nonzeroSetup = setup(path: nonzero)
        let nonzeroMessage = await failure(for: nonzeroSetup)
        precondition(nonzeroSetup.loginURL?.host == "auth.openai.com", "provider URL should be captured")
        precondition(nonzeroMessage.contains("status 7") && nonzeroMessage.contains("provider failed"),
                     "exit status and stderr should be preserved")
        precondition(!nonzeroMessage.contains("secret-code") && !nonzeroMessage.contains("https://"),
                     "login tokens and URLs must stay out of diagnostics")

        let noisy = try script(in: root, body: #"head -c 100000 /dev/zero | tr '\0' x; head -c 100000 /dev/zero | tr '\0' x >&2; exit 9"#)
        let noisyMessage = await failure(for: setup(path: noisy))
        precondition(noisyMessage.contains("status 9"), "both output pipes should drain without blocking")

        let descendantPIDFile = root.appendingPathComponent("descendant.pid")
        let descendant = try script(in: root, body: #"sleep 30 & child=$!; echo $child > "# + descendantPIDFile.path + #"; printf 'descendant failed\n' >&2; exit 7"#)
        let descendantStarted = Date()
        let descendantMessage = await failure(for: setup(path: descendant))
        let descendantPID = Int32(try String(contentsOf: descendantPIDFile).trimmingCharacters(in: .whitespacesAndNewlines))!
        childPIDs.append(descendantPID)
        _ = kill(descendantPID, SIGTERM)
        childPIDs.removeAll { $0 == descendantPID }
        precondition(descendantMessage.contains("status 7") && Date().timeIntervalSince(descendantStarted) < 3,
                     "inherited pipes should have a bounded EOF wait")

        let fragmented = try script(in: root, body: #"printf 'https://auth.openai.com/oauth/authorize?client_id=abc'; sleep 0.4; printf '&state=fragmented'; sleep 1; exit 7"#)
        let fragmentedSetup = setup(path: fragmented)
        try? await Task.sleep(for: .milliseconds(100))
        precondition(fragmentedSetup.loginURL == nil, "an unterminated URL must wait for its delimiter or EOF")
        await until(timeout: 2) { fragmentedSetup.loginURL != nil }
        precondition(fragmentedSetup.loginURL?.absoluteString.contains("client_id=abc&state=fragmented") == true,
                     "URL fragments split across pipe reads should be joined")
        fragmentedSetup.cancel()
        await until(timeout: 2) { if case .failed = fragmentedSetup.step { return true }; return fragmentedSetup.step == .signingIn }

        let empty = try script(in: root, body: "exit 0")
        let emptyMessage = await failure(for: setup(path: empty))
        precondition(emptyMessage.contains("still reports no signed-in account"),
                     "success without signed-in status should fail clearly")

        let pidFile = root.appendingPathComponent("login.pid")
        var done = false
        let cancellable = try script(in: root, body: #"printf 'https://auth.openai.com/oauth/authorize?code=cancel-me\n'; echo $$ > "# + pidFile.path + #"; exec /bin/sleep 30"#)
        let cancellableSetup = setup(path: cancellable) { _ in done = true }
        await until(timeout: 2) { cancellableSetup.loginURL != nil }
        let pid = Int32(try String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines))!
        childPIDs.append(pid)
        cancellableSetup.cancel()
        let stopped = await until(timeout: 2) { kill(pid, 0) == -1 && errno == ESRCH }
        if !stopped { _ = kill(pid, SIGKILL) }
        childPIDs.removeAll { $0 == pid }
        precondition(stopped, "cancellation should terminate the login process")
        precondition(!done, "cancellation must not call the completion callback")

        print("PASS: agent setup captures login output, redacts diagnostics, and cancels cleanly")
    }

    private static func setup(path: String, done: @escaping (AgentEnvironment) -> Void = { _ in }) -> AgentSetup {
        AgentSetup(kind: .codex,
                   installed: InstalledAgent(kind: .codex, path: path, signedIn: false),
                   envPath: "/usr/bin:/bin:/usr/sbin:/sbin", done: done)
    }

    private static func failure(for setup: AgentSetup) async -> String {
        await until(timeout: 5) {
            if case .failed = setup.step { return true }
            return false
        }
        guard case .failed(let message) = setup.step else { fatalError("setup did not fail") }
        return message
    }

    @discardableResult
    private static func until(timeout: TimeInterval, _ predicate: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    private static func script(in root: URL, body: String) throws -> String {
        let url = root.appendingPathComponent(UUID().uuidString)
        try ("#!/bin/sh\nif [ \"$1\" = \"login\" ] && [ \"$2\" = \"status\" ]; then exit 1; fi\n\(body)\n")
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }
}
