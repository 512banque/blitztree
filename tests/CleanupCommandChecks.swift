import Foundation

@main
struct CleanupCommandChecks {
    static func main() {
        let allowed = [
            "uv cache clean",
            "bun pm cache rm",
            "npm cache clean --force",
            "pnpm store prune",
            "yarn cache clean",
            "brew cleanup --prune=all",
            "docker system prune -f",
            "docker builder prune -f",
            "xcrun simctl delete unavailable",
            "pip cache purge",
            "ollama rm llama3.2:latest",
            "go clean -modcache",
            "gem cleanup",
            "pod cache clean --all",
            "conda clean -a -y",
            "uv cache prune",
            "npm cache clean",
            "pip3 cache purge",
            "go clean -cache",
        ]
        for raw in allowed {
            precondition(CleanupCommand.parse(raw) != nil, "should allow: \(raw)")
        }

        let padded = CleanupCommand.parse(" \tuv\tcache clean \t")
        precondition(padded?.argv == ["uv", "cache", "clean"], "space/tab tokenization changed")

        let rejected = [
            "docker system prune -f --volumes",
            "docker system prune -af",
            "brew cleanup --prune=all --dry-run",
            "npm cache clean --force /tmp/other-cache",
            "xcrun simctl delete unavailable ABCD",
            "go clean -modcache /tmp/other-cache",
            "ollama rm --all",
            "ollama rm model-one model-two",
            "ollama rm modèle:latest",
            "uv cache clean; touch /tmp/pwned",
            "npm cache clean --force $(touch /tmp/pwned)",
            "npm cache clean --force\n touch /tmp/pwned",
            "npm cache clean --force\"",
        ]
        for raw in rejected {
            precondition(CleanupCommand.parse(raw) == nil, "should reject: \(raw)")
        }

        precondition(CleanupCommand.parse("uv cache clean")?.cacheRelativePath == ".cache/uv")
        precondition(CleanupCommand.parse("uv cache prune")?.cacheRelativePath == nil)
        precondition(CleanupCommand.parse("npm cache clean --force")?.cacheRelativePath == ".npm/_cacache")
        precondition(CleanupCommand.parse("bun pm cache rm")?.cacheRelativePath == ".bun/install/cache")
        precondition(CleanupCommand.parse("pip3 cache purge")?.cacheRelativePath == "Library/Caches/pip")
        precondition(CleanupCommand.parse("docker system prune -f")?.cacheRelativePath == nil)
        precondition(CleanupCommand.promptExamples.contains("`ollama rm <model>`"))
        print("PASS: CleanupCommand exact argv allowlist")
    }
}
