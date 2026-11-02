import SwiftUI
import WatchKit

/// One spoken turn at a time: record, send to the Mac, wait for Cantrip Home, speak the reply.
@MainActor
final class WatchVoiceModel: ObservableObject {
    enum Phase: Equatable {
        case ready
        case listening
        case sending
        case thinking
        case speaking
        case failed(String)

        var title: String {
            switch self {
            case .ready: return "Ready"
            case .listening: return "Listening…"
            case .sending: return "Sending…"
            case .thinking: return "Thinking…"
            case .speaking: return "Speaking"
            case .failed(let message): return message
            }
        }

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var transcript: String?
    @Published private(set) var reply: String?
    @Published private(set) var level: Float = 0
    @Published private(set) var configuration: CantripWatchConfiguration?
    @Published private(set) var isSettingUp = false
    @Published private(set) var setupError: String?
    /// The Mac no longer knows this watch (401); offer setup again.
    @Published private(set) var needsSetupAgain = false
    @Published var speakReplies: Bool {
        didSet { WatchSettings.speakReplies = speakReplies }
    }

    /// How long a turn may take before the watch stops waiting.
    static let answerLimit: TimeInterval = 600

    private let recorder = WatchRecorder()
    private let speaker = WatchSpeaker()
    private var client: CantripWatchClient?
    private var turnTask: Task<Void, Never>?
    private var turnGeneration = 0
    /// The turn being answered, picked up again if the app was closed while waiting.
    private var pendingTurn: (turn: CantripVoiceTurn, startedAt: Date)?
    private var lastConfigRefresh: Date?
    #if DEBUG
    private var qaStarted = false
    #endif

    init() {
        configuration = WatchSettings.configuration
        speakReplies = WatchSettings.speakReplies
        recorder.onLevel = { [weak self] level in self?.level = level }
    }

    var isSetUp: Bool { configuration != nil }

    // MARK: Talking

    func micTapped() {
        switch phase {
        case .listening:
            recorder.finish()
        case .sending:
            return
        default:
            speaker.stop()
            pendingTurn = nil
            startTask { [weak self] generation in await self?.runTurn(generation) }
        }
    }

    func stopSpeaking() {
        speaker.stop()
    }

    /// Runs `body` as the only turn task; `body` gets its generation to tell if it was replaced.
    private func startTask(_ body: @escaping @MainActor (Int) async -> Void) {
        turnTask?.cancel()
        turnGeneration += 1
        let generation = turnGeneration
        turnTask = Task { [weak self] in
            await body(generation)
            guard let self, self.turnGeneration == generation else { return }
            self.turnTask = nil
        }
    }

    private func runTurn(_ generation: Int) async {
        transcript = nil
        reply = nil
        do {
            let client = try currentClient()
            phase = .listening
            play(.start)
            guard let (audio, contentType) = try await captureAudio() else {
                phase = .ready
                return
            }
            play(.stop)
            try Task.checkCancellation()
            phase = .sending
            let startedAt = Date()
            let turn = try await client.startTurn(audio: audio, contentType: contentType)
            try await follow(turn, startedAt: startedAt, client: client)
        } catch is CancellationError {
            if turnGeneration == generation, pendingTurn == nil { phase = .ready }
        } catch {
            if turnGeneration == generation { fail(error) }
        }
    }

    private func captureAudio() async throws -> (Data, String)? {
        #if DEBUG
        if let file = WatchQA.current?.audioFile {
            try await Task.sleep(for: .seconds(2))
            guard let data = try? Data(contentsOf: file) else {
                throw CantripWatchError.failed("QA audio file not found.")
            }
            return (data, file.pathExtension.lowercased() == "wav" ? "audio/wav" : "audio/mp4")
        }
        #endif
        switch try await recorder.record() {
        case .clip(let url):
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url) else { throw CantripWatchError.recordingFailed }
            return (data, "audio/mp4")
        case .noSpeech:
            throw CantripWatchError.noSpeech
        case .cancelled:
            return nil
        }
    }

    private func follow(_ turn: CantripVoiceTurn, startedAt: Date, client: CantripWatchClient) async throws {
        pendingTurn = (turn, startedAt)
        show(turn)
        if !turn.isFinished { phase = .thinking }
        let final = try await client.follow(turn, until: startedAt.addingTimeInterval(Self.answerLimit)) { update in
            await self.show(update)
        }
        pendingTurn = nil
        guard final.isFinished else { throw CantripWatchError.timedOut }
        show(final)
        if final.status == .failed {
            throw CantripWatchError.failed(final.error ?? "Cantrip Home couldn't answer that. Try again.")
        }
        deliver(final)
    }

    private func show(_ turn: CantripVoiceTurn) {
        if let heard = turn.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !heard.isEmpty {
            transcript = heard
        }
        let text = CantripWatchText.plain(turn.reply ?? "")
        if !text.isEmpty { reply = text }
        if !turn.isFinished, phase == .sending { phase = .thinking }
    }

    private func deliver(_ turn: CantripVoiceTurn) {
        play(.notification)
        let text = turn.speakableText
        guard speakReplies, !text.isEmpty else {
            phase = .ready
            return
        }
        phase = .speaking
        speaker.speak(text) { [weak self] in
            guard let self, self.phase == .speaking else { return }
            self.phase = .ready
        }
    }

    private func fail(_ error: Error) {
        let watchError = error as? CantripWatchError
        if watchError == .unauthorized { needsSetupAgain = true }
        phase = .failed(watchError?.errorDescription ?? error.localizedDescription)
        play(.failure)
    }

    private func currentClient() throws -> CantripWatchClient {
        if let client { return client }
        let made = try CantripWatchClient.current()
        client = made
        return made
    }

    // MARK: App lifecycle

    func scenePhaseChanged(_ scenePhase: ScenePhase) {
        switch scenePhase {
        case .background:
            // Closing the app stops recording, speech and waiting; a pending turn resumes on return.
            recorder.cancel()
            speaker.stop()
            turnTask?.cancel()
            turnTask = nil
            turnGeneration += 1
            if pendingTurn == nil, phase == .listening || phase == .sending { phase = .ready }
        case .active:
            configuration = WatchSettings.configuration
            resumePendingTurn()
            refreshConfigIfStale()
            #if DEBUG
            if WatchQA.current?.autoStart == true, !qaStarted {
                qaStarted = true
                micTapped()
            }
            #endif
        default:
            break
        }
    }

    private func resumePendingTurn() {
        guard turnTask == nil, let pending = pendingTurn else { return }
        guard Date().timeIntervalSince(pending.startedAt) < Self.answerLimit else {
            pendingTurn = nil
            fail(CantripWatchError.timedOut)
            return
        }
        phase = .thinking
        startTask { [weak self] generation in
            guard let self else { return }
            do {
                try await self.follow(pending.turn, startedAt: pending.startedAt, client: try self.currentClient())
            } catch is CancellationError {
            } catch where self.turnGeneration == generation {
                self.pendingTurn = nil
                self.fail(error)
            } catch {}
        }
    }

    /// Picks up a changed internet route while the Mac is reachable.
    private func refreshConfigIfStale() {
        guard isSetUp, lastConfigRefresh.map({ Date().timeIntervalSince($0) > 300 }) ?? true,
              let client = try? currentClient() else { return }
        lastConfigRefresh = Date()
        Task { [weak self] in
            _ = try? await client.refreshConfig()
            self?.configuration = WatchSettings.configuration
        }
    }

    // MARK: Setup

    func setUp() {
        guard !isSettingUp else { return }
        isSettingUp = true
        setupError = nil
        Task {
            defer { isSettingUp = false }
            do {
                let signer = try WatchDeviceKey.loadOrCreate()
                let configuration = try await WatchPhoneLink.shared.register(
                    publicKey: signer.publicKeyBase64, name: WKInterfaceDevice.current().name
                )
                WatchSettings.save(configuration)
                self.configuration = WatchSettings.configuration
                client = nil
                lastConfigRefresh = nil
                needsSetupAgain = false
                transcript = nil
                reply = nil
                phase = .ready
                play(.success)
            } catch {
                setupError = (error as? CantripWatchError)?.errorDescription ?? error.localizedDescription
                play(.failure)
            }
        }
    }

    /// Forgets the Mac on this watch. The Mac keeps the device until it's removed in Cantrip there.
    func forget() {
        recorder.cancel()
        speaker.stop()
        turnTask?.cancel()
        turnTask = nil
        pendingTurn = nil
        WatchSettings.clear()
        client = nil
        configuration = WatchSettings.configuration
        transcript = nil
        reply = nil
        needsSetupAgain = false
        phase = .ready
    }

    private func play(_ haptic: WKHapticType) {
        WKInterfaceDevice.current().play(haptic)
    }
}
