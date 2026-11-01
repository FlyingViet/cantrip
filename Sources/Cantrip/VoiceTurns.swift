import Foundation
import Speech

/// A spoken request to Cantrip Home and its answer (`/api/v1/voice/turns`): the Mac transcribes
/// the clip, sends the words to Home's chat like a typed message, and follows that message's reply.
struct VoiceTurn: Equatable {
    enum Status: String { case queued, thinking, done, failed }

    let id: UUID
    var status: Status
    var transcript: String
    var reply = ""
    var error: String?
    let createdAt: Date
    var updatedAt: Date
    /// Where Home's messages stood when this one was sent.
    let baseline: Int

    var json: [String: Any] {
        var object: [String: Any] = [
            "id": id.uuidString, "status": status.rawValue, "transcript": transcript, "reply": reply,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
        ]
        if status == .done { object["spoken"] = VoiceSpeech.spokenText(reply) }
        if let error { object["error"] = error }
        return object
    }
}

/// Plain sentences to speak from a Markdown reply: code, tables and links read as words, and a
/// long answer stops at a sentence with a pointer to the rest.
enum VoiceSpeech {
    static func spokenText(_ markdown: String, limit: Int = 1_200) -> String {
        var lines: [String] = []
        var inCode = false, saidCode = false, saidTable = false
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inCode.toggle()
                if inCode, !saidCode { lines.append("The code is on screen."); saidCode = true }
                continue
            }
            if inCode { continue }
            if line.hasPrefix("|") {
                if !saidTable { lines.append("There's a table on screen."); saidTable = true }
                continue
            }
            var text = line
            // Headings, quotes and list markers.
            text = text.replacingOccurrences(of: #"^(#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            // Images, then links: keep the words.
            text = text.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: #"https?://\S+"#, with: "the link on screen", options: .regularExpression)
            text = text.replacingOccurrences(of: #"[*_~`]+"#, with: "", options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.range(of: #"^[-=_*]{3,}$"#, options: .regularExpression) == nil else { continue }
            // A heading or list item without its own end reads as its own sentence.
            if let last = text.last, !".!?:;".contains(last) { text += "." }
            lines.append(text)
        }
        let spoken = lines.joined(separator: " ")
        guard spoken.count > limit else { return spoken }
        let cut = spoken.prefix(limit)
        let end = cut.lastIndex { ".!?".contains($0) }.map { cut.index(after: $0) } ?? cut.endIndex
        return String(cut[..<end]).trimmingCharacters(in: .whitespaces) + " The rest is on screen."
    }
}

/// How far Home has got with a voice turn's message, from its chat. Pure, so tests drive it.
enum VoiceTurnTracker {
    struct Progress: Equatable {
        var status: VoiceTurn.Status
        var reply: String
        var error: String?
    }

    /// `baseline` is the message count when the turn was sent; `stillQueued` says the message is
    /// waiting in Home's queue.
    static func progress(messages: [ChatMessage], baseline: Int, prompt: String,
                         isStreaming: Bool, stillQueued: Bool) -> Progress {
        let wanted = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = min(max(baseline, 0), messages.count)
        guard let asked = messages[start...].firstIndex(where: { $0.role == .user && $0.text.contains(wanted) }) else {
            return Progress(status: .queued, reply: "")
        }
        let after = messages[(asked + 1)...]
        let next = after.firstIndex { $0.role == .user || $0.role == .freshStart }
        let answer = next.map { messages[(asked + 1)..<$0] } ?? after
        let reply = answer.filter { $0.role == .assistant || $0.role == .handoff }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let failure = answer.last { $0.role == .error }?.text
        // Ours is over when the next message started or Home stopped working.
        let finished = next != nil || (!isStreaming && !stillQueued)
        guard finished else { return Progress(status: .thinking, reply: reply) }
        if reply.isEmpty, let failure { return Progress(status: .failed, reply: "", error: failure) }
        return Progress(status: .done, reply: reply)
    }
}

/// Turns the Mac has in flight or recently finished, kept an hour. Main actor: it reads Home's chat.
@MainActor
final class VoiceTurns {
    static let shared = VoiceTurns()
    static let maximumAge: TimeInterval = 3_600
    /// A message Home never shows (or never answers) fails after this long.
    static let startGrace: TimeInterval = 20
    static let replyLimit: TimeInterval = 15 * 60

    /// The chat that answers: Cantrip Home, when it's on.
    var home: () -> ChatSession? = { nil }
    /// Sends the words to Home, queued so the turn waits for its own reply; tests replace it.
    var submit: (ChatSession, String) -> Void = { session, text in
        session.submitRemote(text, mode: .queue, autoForkEligible: false)
    }
    var now: () -> Date = Date.init
    private(set) var turns: [UUID: VoiceTurn] = [:]

    enum StartError: LocalizedError {
        case homeOff, empty
        var errorDescription: String? {
            switch self {
            case .homeOff: return "Cantrip Home is off on the Mac."
            case .empty: return "Cantrip didn't catch that."
            }
        }
    }

    func start(_ text: String) throws -> VoiceTurn {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw StartError.empty }
        guard let session = home() else { throw StartError.homeOff }
        prune()
        let date = now()
        let turn = VoiceTurn(id: UUID(), status: .queued, transcript: prompt, createdAt: date, updatedAt: date,
                             baseline: session.messages.count)
        turns[turn.id] = turn
        // Queued, never routed into the running task: the watch waits for this message's own reply.
        submit(session, prompt)
        return refresh(turn.id) ?? turn
    }

    /// The turn as it stands now.
    @discardableResult
    func refresh(_ id: UUID) -> VoiceTurn? {
        guard var turn = turns[id] else { return nil }
        guard turn.status == .queued || turn.status == .thinking else { return turn }
        let date = now()
        guard let session = home() else {
            turn.status = .failed
            turn.error = StartError.homeOff.localizedDescription
            turn.updatedAt = date
            turns[id] = turn
            return turn
        }
        let stillQueued = session.queued.contains { $0.text.contains(turn.transcript) }
        var progress = VoiceTurnTracker.progress(messages: session.messages, baseline: turn.baseline,
                                                 prompt: turn.transcript, isStreaming: session.isStreaming,
                                                 stillQueued: stillQueued)
        let age = date.timeIntervalSince(turn.createdAt)
        // A run that's still starting can look finished with nothing said yet.
        if progress.status == .done, progress.reply.isEmpty, age < Self.startGrace { progress.status = .thinking }
        if progress.status == .done, progress.reply.isEmpty {
            progress = .init(status: .failed, reply: "", error: "Cantrip Home didn't answer.")
        }
        if progress.status == .queued, !stillQueued, !session.isStreaming, age >= Self.startGrace {
            progress = .init(status: .failed, reply: "", error: "Cantrip Home didn't take the message.")
        }
        if [.queued, .thinking].contains(progress.status), age >= Self.replyLimit {
            progress = .init(status: .failed, reply: progress.reply,
                             error: "Still working after 15 minutes. The answer will be in Cantrip Home.")
        }
        if progress.status != turn.status || progress.reply != turn.reply || progress.error != turn.error {
            turn.status = progress.status
            turn.reply = progress.reply
            turn.error = progress.error
            turn.updatedAt = date
            turns[id] = turn
        }
        return turn
    }

    /// Waits up to `seconds` for the turn to change (status or reply), checking every quarter second.
    func wait(_ id: UUID, seconds: Double) async -> VoiceTurn? {
        guard let first = refresh(id) else { return nil }
        let deadline = Date().addingTimeInterval(min(max(seconds, 0), 25))
        while Date() < deadline, first.status == .queued || first.status == .thinking {
            try? await Task.sleep(for: .milliseconds(250))
            guard let current = refresh(id) else { return nil }
            if current.status != first.status || current.reply != first.reply { return current }
        }
        return refresh(id)
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-Self.maximumAge)
        turns = turns.filter { $0.value.updatedAt >= cutoff }
    }
}

/// Speech-to-text for an uploaded clip, on the Mac (Apple's on-device recognizer when it has
/// one), with the user's names and projects as hints.
enum VoiceTranscription {
    typealias Transcriber = @MainActor (_ audio: URL, _ hints: [String]) async throws -> String

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let onDevice: Transcriber = { audio, hints in
        try await authorize()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            throw Failure(message: "Speech recognition isn't available on the Mac right now.")
        }
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.contextualStrings = Array(hints.prefix(100))
        final class Once: @unchecked Sendable {
            let lock = NSLock()
            var done = false
            func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
        }
        let once = Once()
        var task: SFSpeechRecognitionTask?
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        if once.claim() { continuation.resume(returning: result.bestTranscription.formattedString) }
                    } else if let error {
                        // "No speech detected" is an empty clip, not a failure.
                        let nsError = error as NSError
                        if once.claim() {
                            if nsError.domain == "kAFAssistantErrorDomain", [1110, 203].contains(nsError.code) {
                                continuation.resume(returning: "")
                            } else {
                                continuation.resume(throwing: Failure(message: "The Mac couldn't transcribe the clip: \(error.localizedDescription)"))
                            }
                        }
                    }
                }
            }
        } onCancel: {
            task?.cancel()
        }
    }

    private static func authorize() async throws {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard status == .authorized else {
            throw Failure(message: "Allow Speech Recognition for Cantrip on the Mac (System Settings › Privacy & Security › Speech Recognition).")
        }
    }

    /// Names and phrases from the voice vocabulary (`GET /api/v1/voice/vocabulary`), heaviest first.
    static func hints(from vocabulary: Data?) -> [String] {
        guard let vocabulary, let response = try? JSONDecoder().decode(VoiceVocabulary.Response.self, from: vocabulary) else { return [] }
        let terms = response.terms.sorted { $0.weight > $1.weight }.map(\.text)
        let people = response.people.compactMap(\.name)
        var seen = Set<String>()
        return (terms + people).filter { seen.insert($0.lowercased()).inserted }
    }
}
