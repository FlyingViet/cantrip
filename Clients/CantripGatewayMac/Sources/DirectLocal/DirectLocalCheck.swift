import Foundation

/// `Cantrip Gateway Mac --direct-local-check [--url URL] [--model NAME] [--prompt TEXT]`
/// From Terminal: checks direct local mode with this app's own transport and settings (the saved
/// ones unless overridden), lists the server's local models, confirms the model, and with
/// `--prompt` streams one reply. Saves nothing and doesn't open a window. Exit status 0 = OK.
enum DirectLocalCheck {
    static let flag = "--direct-local-check"

    static func runIfRequested(_ arguments: [String]) -> Int32? {
        guard arguments.contains(flag) else { return nil }
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        var configuration = DirectLocalStore().loadConfiguration()
        if let url = value("--url") { configuration.baseURL = url }
        if let model = value("--model") { configuration.model = model }
        let prompt = value("--prompt")
        let semaphore = DispatchSemaphore(value: 0)
        let status = Status()
        Task.detached {
            status.value = await run(configuration, prompt: prompt)
            semaphore.signal()
        }
        semaphore.wait()
        return status.value
    }

    private final class Status: @unchecked Sendable { var value: Int32 = 1 }

    static func run(_ configuration: DirectLocalConfiguration, prompt: String?) async -> Int32 {
        var configuration = configuration
        let client = DirectLocalClient()
        defer { client.close() }
        func out(_ text: String, terminator: String = "\n") {
            FileHandle.standardOutput.write(Data((text + terminator).utf8))
        }
        do {
            out("Server: \(try configuration.endpoint("").absoluteString)")
            let models = try await client.models(configuration)
            out("Models: \(models.isEmpty ? "(none)" : models.joined(separator: ", "))")
            if configuration.model.isEmpty, let first = models.first { configuration.model = first }
            try await client.verify(configuration)
            out("Model: \(configuration.model) (installed on this server)")
            if let prompt {
                let messages = DirectLocalHistory.chatMessages(
                    [DirectLocalMessage(role: .user, content: prompt)], configuration: configuration)
                out("Reply: ", terminator: "")
                let started = Date()
                do {
                    try await client.chat(configuration, messages: messages) { event in
                        if case .content(let text) = event { out(text, terminator: "") }
                    }
                } catch {
                    out("")
                    throw error
                }
                out(String(format: "\n(%.1f s)", Date().timeIntervalSince(started)))
            }
            out("OK")
            return 0
        } catch {
            FileHandle.standardError.write(Data("Direct local check failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
