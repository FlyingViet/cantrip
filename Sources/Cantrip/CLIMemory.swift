import Foundation

/// Cantrip Memory is the only durable memory: each CLI's own memory stays off in everything Cantrip
/// starts, so a fact never lands in a store that skips Cantrip's privacy rules or follows only one
/// backend. Antigravity has no switch for its memory; see docs/backends.md.
enum CLIMemory {
    /// Claude Code: no auto-memory reads or writes. Exported at launch, so tabs, helper calls, the
    /// consolidator and agents' own shells all inherit it.
    static let claudeEnvironment = ["CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"]

    /// Codex: the memories feature, and generating or using memories, off (after `app-server`).
    static let codexArguments = [
        "-c", "features.memories=false",
        "-c", "memories.generate_memories=false",
        "-c", "memories.use_memories=false",
    ]

    /// Copilot: a session option (`memory: { enabled: false }`) set in `CopilotSessionBridge`.
    /// Prompt-mode helper calls (`copilot -p`) have memory off unless `--enable-memory` is passed.

    static func exportEnvironment() {
        for (key, value) in claudeEnvironment { setenv(key, value, 1) }
    }
}
