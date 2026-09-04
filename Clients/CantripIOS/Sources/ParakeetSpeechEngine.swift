import AVFoundation
import CoreML
import FluidAudio
import Foundation

@MainActor
final class ParakeetSpeechEngine: ObservableObject {
    static let shared = ParakeetSpeechEngine()

    enum ModelState: Equatable {
        case idle
        case preparing(progress: Double, phase: String)
        case cached
        case ready
        case failed(String)
    }

    @Published private(set) var state: ModelState

    private var manager: StreamingEouAsrManager?
    private var preparationTask: Task<Void, Error>?

    private init() {
        state = UserDefaults.standard.bool(forKey: "hermes.parakeetPrepared")
            ? .cached
            : .idle
    }

    static func initialPreparationPhase(isKnownCached: Bool) -> String {
        isKnownCached ? "Loading Parakeet" : "Checking speech model"
    }

    var isPrepared: Bool {
        switch state {
        case .cached, .ready:
            true
        default:
            false
        }
    }

    func prepareIfNeeded() async throws {
        if manager != nil {
            state = .ready
            return
        }
        if let preparationTask {
            try await preparationTask.value
            return
        }

        let isKnownCached = isPrepared
        state = .preparing(
            progress: 0,
            phase: Self.initialPreparationPhase(isKnownCached: isKnownCached)
        )
        let task = Task { @MainActor in
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let newManager = StreamingEouAsrManager(
                configuration: configuration,
                chunkSize: .ms320,
                eouDebounceMs: 1280
            )
            try await newManager.loadModels(
                to: nil,
                configuration: configuration
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.state = .preparing(
                        progress: progress.fractionCompleted,
                        phase: Self.title(for: progress.phase)
                    )
                }
            }
            manager = newManager
        }
        preparationTask = task
        do {
            try await task.value
            UserDefaults.standard.set(true, forKey: "hermes.parakeetPrepared")
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            preparationTask = nil
            throw error
        }
        preparationTask = nil
    }

    func startSession(
        silenceSeconds: TimeInterval,
        onPartial: @escaping @Sendable (String) -> Void,
        onEndOfUtterance: @escaping @Sendable (String) -> Void
    ) async throws {
        try await prepareIfNeeded()
        guard let manager else {
            throw CocoaError(.featureUnsupported)
        }
        await manager.reset()
        await manager.setAgentGatewayEouDebounce(
            milliseconds: Int(silenceSeconds * 1000)
        )
        await manager.setPartialCallback(onPartial)
        await manager.setEouCallback(onEndOfUtterance)
    }

    func process(_ buffer: AVAudioPCMBuffer) async throws {
        guard let manager else {
            throw CocoaError(.featureUnsupported)
        }
        _ = try await manager.process(audioBuffer: buffer)
    }

    func finish() async throws -> String {
        guard let manager else {
            throw CocoaError(.featureUnsupported)
        }
        let transcript = try await manager.finish()
        await manager.reset()
        return transcript
    }

    func cancelSession() async {
        await manager?.reset()
    }

    func releaseMemory() async {
        guard let manager else { return }
        await manager.cleanup()
        self.manager = nil
        state = .cached
    }

    private static func title(for phase: DownloadPhase) -> String {
        switch phase {
        case .listing:
            "Finding speech model"
        case .downloading(let completedFiles, let totalFiles):
            "Downloading \(completedFiles) of \(totalFiles)"
        case .compiling(let modelName):
            "Compiling \(modelName)"
        }
    }

}

private extension StreamingEouAsrManager {
    func setAgentGatewayEouDebounce(milliseconds: Int) {
        eouDebounceMs = max(500, milliseconds)
    }
}
