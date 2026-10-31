import Foundation

extension SessionTabTests {
    /// agy keeps a conversation in the folder it started in: a tab moved to another folder starts a
    /// fresh conversation there instead of resuming one whose commands run in the old (perhaps
    /// deleted) folder.
    @MainActor
    static func testAntigravityWorkdirAndToolStates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agy-workdir-\(UUID())")
        let first = directory.appendingPathComponent("first"), second = directory.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("launches.txt")
        let script = directory.appendingPathComponent("agy-workdir-fixture")
        try Data(#"""
        #!/usr/bin/env python3
        import json, os, sys
        resumed = sys.argv[sys.argv.index('--conversation') + 1] if '--conversation' in sys.argv else 'new'
        with open(os.environ['AGY_WORKDIR_LOG'], 'a') as f:
            f.write(os.getcwd() + ' ' + resumed + '\n')
        for line in sys.stdin:
            if not line.strip():
                continue
            cid = 'conv-' + os.path.basename(os.getcwd())
            print(json.dumps({'event': 'step_update', 'conversation_id': cid, 'step_update': {'step_index': 1, 'state': 'DONE', 'step_type': 'agent_response', 'text_delta': 'ok'}}), flush=True)
            print(json.dumps({'event': 'result', 'conversation_id': cid, 'result': {'status': 'SUCCESS', 'response': 'ok', 'usage': {'input_tokens': 1, 'output_tokens': 1}}}), flush=True)
        """#.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        setenv("AGY_WORKDIR_LOG", log.path, 1)
        defer { unsetenv("AGY_WORKDIR_LOG") }

        let settings = AppSettings.shared
        let saved = (settings.agyPath, settings.agyModel, settings.allowActions, settings.agyPermissionMode)
        defer { (settings.agyPath, settings.agyModel, settings.allowActions, settings.agyPermissionMode) = saved }
        settings.agyPath = script.path
        settings.agyModel = "model-a"
        settings.allowActions = true
        settings.agyPermissionMode = "default"

        let backend = AntigravityBackend(persistKey: "test-agy-workdir")
        backend.reset()
        defer { backend.cancel(); backend.reset() }
        _ = try await antigravityTurn(backend, prompt: "one", workdir: first.path)
        backend.cancel()
        _ = try await antigravityTurn(backend, prompt: "two", workdir: first.path)
        _ = try await antigravityTurn(backend, prompt: "three", workdir: second.path)
        let launches = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
            ($0.split(separator: " ").last.map(String.init) ?? "",
             URL(fileURLWithPath: String($0.split(separator: " ").first ?? "")).lastPathComponent)
        }
        precondition(launches.count == 3
                     && launches[0] == ("new", "first")
                     && launches[1] == ("conv-first", "first")
                     && launches[2] == ("new", "second"),
                     "Same folder resumes; a moved tab starts fresh in its new folder: \(launches)")
        precondition(backend.conversationID == "conv-second")

        print("Antigravity: a moved tab starts a fresh conversation")
    }
}
