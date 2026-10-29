import Foundation

/// A tab's terminal on the Mac (`GET/POST /api/v1/sessions/{id}/terminal`): the same persistent
/// shell as the Cantrip panel's terminal mode. Offsets count Unicode scalars of the Mac's output.
struct CantripTerminalSnapshot: Decodable, Equatable {
    let epoch: String
    let start: Int
    let end: Int
    let text: String
    let reset: Bool
    let isRunning: Bool
    let agentCommandRunning: Bool
    let history: [String]
    let workdir: String
}

/// The client's copy of the terminal output. Replies may arrive out of order (a poll and a
/// command's reply), so each is applied by offset and overlaps are never shown twice.
struct CantripTerminalBuffer: Equatable {
    static let maximumLength = 120_000

    private(set) var output = ""
    private(set) var epoch: String?
    /// The Mac's offset just after `output`; the next poll reads from here.
    private(set) var end = 0

    mutating func apply(_ snapshot: CantripTerminalSnapshot) {
        if snapshot.reset || snapshot.epoch != epoch {
            output = snapshot.text
            epoch = snapshot.epoch
            end = snapshot.end
        } else if snapshot.end > end {
            guard snapshot.start <= end else {
                // A gap: read everything the Mac kept on the next poll.
                epoch = nil
                return
            }
            output += String(snapshot.text.unicodeScalars.dropFirst(end - snapshot.start))
            end = snapshot.end
        }
        if output.count > Self.maximumLength {
            output = String(output.suffix(Self.maximumLength * 3 / 4))
        }
    }
}

/// Up/Down through the commands the shell has run, keeping the draft typed before browsing.
struct CantripTerminalHistory: Equatable {
    private(set) var index: Int?
    private var draft = ""

    /// The command line after pressing Up (`backward`) or Down, or nil when it doesn't change.
    mutating func step(backward: Bool, history: [String], current: String) -> String? {
        guard !history.isEmpty else { return nil }
        if backward {
            if let index {
                self.index = max(0, min(index, history.count) - 1)
            } else {
                draft = current
                index = history.count - 1
            }
            return history[index ?? 0]
        }
        guard let index else { return nil }
        if index < history.count - 1 {
            self.index = index + 1
            return history[index + 1]
        }
        let typed = draft
        reset()
        return typed
    }

    mutating func reset() {
        index = nil
        draft = ""
    }
}

/// Polls one tab's terminal while it is open and sends its commands.
@MainActor
final class CantripTerminalModel: ObservableObject {
    @Published private(set) var buffer = CantripTerminalBuffer()
    @Published private(set) var isRunning = false
    @Published private(set) var agentCommandRunning = false
    @Published private(set) var history: [String] = []
    @Published private(set) var workdir = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoaded = false
    @Published private(set) var isSending = false
    private(set) var sessionID: String?
    private weak var remote: CantripRemoteModel?
    private var pollTask: Task<Void, Never>?

    static let unsupported = "Update Cantrip on the Mac to use the terminal from here."

    var isBusy: Bool { isRunning || agentCommandRunning }

    /// Shows `sessionID`'s terminal and keeps it current until `stop()`.
    func start(remote: CantripRemoteModel, sessionID: String) {
        if self.sessionID != sessionID || self.remote !== remote {
            stop()
            buffer = CantripTerminalBuffer()
            history = []
            workdir = ""
            isRunning = false
            agentCommandRunning = false
            errorMessage = nil
            isLoaded = false
        }
        self.remote = remote
        self.sessionID = sessionID
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                let delay: Duration = self.isBusy ? .milliseconds(400) : .milliseconds(1500)
                try? await Task.sleep(for: self.errorMessage == nil ? delay : .seconds(4))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func poll() async {
        guard let remote, let sessionID else { return }
        do {
            apply(try await remote.terminal(sessionID: sessionID, from: buffer.end, epoch: buffer.epoch), for: sessionID)
        } catch is CancellationError {
        } catch {
            fail(error, for: sessionID)
        }
    }

    /// Runs one line in the tab's shell; true when the Mac took it.
    @discardableResult
    func run(_ command: String) async -> Bool {
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.contains(where: \.isNewline) else { return false }
        return await send(nil, command: line)
    }

    /// Control-C: stops the running command (or the agent, when only its command runs).
    func interrupt() async { await send("interrupt") }
    func clear() async { await send("clear") }
    func restart() async { await send("restart") }

    @discardableResult
    private func send(_ action: String?, command: String? = nil) async -> Bool {
        guard let remote, let sessionID, !isSending else { return false }
        isSending = true
        defer { isSending = false }
        do {
            let snapshot = try await remote.terminal(action, command: command, sessionID: sessionID,
                                                     from: buffer.end, epoch: buffer.epoch)
            apply(snapshot, for: sessionID)
            return true
        } catch is CancellationError {
            return false
        } catch {
            fail(error, for: sessionID)
            return false
        }
    }

    private func apply(_ snapshot: CantripTerminalSnapshot, for id: String) {
        guard id == sessionID else { return }
        buffer.apply(snapshot)
        isRunning = snapshot.isRunning
        agentCommandRunning = snapshot.agentCommandRunning
        if history != snapshot.history { history = snapshot.history }
        if workdir != snapshot.workdir { workdir = snapshot.workdir }
        errorMessage = nil
        isLoaded = true
    }

    private func fail(_ error: Error, for id: String) {
        guard id == sessionID else { return }
        errorMessage = Self.message(for: error)
    }

    static func message(for error: Error) -> String {
        switch error {
        case CantripRemoteError.http(let status, _) where status == 404 || status == 405:
            return unsupported
        case CantripRemoteError.http(_, let message):
            return message
        default:
            return error.localizedDescription
        }
    }
}
