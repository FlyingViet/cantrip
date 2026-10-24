import AVFoundation
import FluidAudio
import SwiftUI

/// Download/load state of the final-pass dictation models.
@MainActor
final class DictationModelStatus: ObservableObject {
    static let shared = DictationModelStatus()

    enum State: Equatable {
        case notDownloaded
        case downloaded
        case preparing(Double, String)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State

    private init() {
        state = DictationRecognizer.modelsDownloaded ? .downloaded : .notDownloaded
    }

    func prepare() {
        if case .preparing = state { return }
        state = .preparing(0, "Starting")
        Task {
            do {
                await QwenVoiceEngine.shared.releaseMemory()
                try await DictationRecognizer.shared.prepare { progress, phase in
                    Task { @MainActor in
                        if case .preparing = DictationModelStatus.shared.state {
                            DictationModelStatus.shared.state = .preparing(progress, phase)
                        }
                    }
                }
                state = .ready
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

struct DictationSettingsSection: View {
    @ObservedObject var remote: CantripRemoteModel
    @ObservedObject private var status = DictationModelStatus.shared
    @ObservedObject private var vocabulary = DictationVocabularyStore.shared
    @AppStorage(DictationPolisher.enabledKey) private var cleanup = true
    @AppStorage(DictationVocabularyStore.contactsKey) private var useContacts = true

    var body: some View {
        Section {
            modelRow
            Toggle(isOn: $cleanup) {
                Label("Clean up with Apple Intelligence", systemImage: "wand.and.sparkles")
            }
            if cleanup, let reason = DictationPolisher.unavailableReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            #if os(iOS)
            Toggle(isOn: $useContacts) {
                Label("Spell contact names", systemImage: "person.crop.circle")
            }
            .onChange(of: useContacts) { _, enabled in
                guard enabled else { return vocabulary.refresh(remote: remote) }
                Task {
                    _ = await DictationVocabularyStore.requestContactsAccess()
                    vocabulary.refresh(remote: remote)
                }
            }
            #endif
            NavigationLink {
                DictationDetailsView(remote: remote)
            } label: {
                LabeledContent {
                    Text("\(vocabulary.terms.count) words").foregroundStyle(.secondary)
                } label: {
                    Label("Names, timings and speed test", systemImage: "text.badge.checkmark")
                }
            }
        } header: {
            Text("Dictation")
        } footer: {
            Text("Hold the mic and release to finish, or tap to start and tap again. Parakeet TDT turns finished phrases into punctuated text while you talk, boosts your project, company and contact names, and Apple Intelligence then removes fillers and applies self-corrections. Everything stays on your devices.")
        }
    }

    @ViewBuilder private var modelRow: some View {
        switch status.state {
        case .notDownloaded:
            Button {
                status.prepare()
            } label: {
                Label("Download dictation model (about 560 MB)", systemImage: "arrow.down.circle")
            }
        case .downloaded:
            Label("Dictation model downloaded", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .ready:
            Label("Dictation model ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .preparing(let progress, let phase):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(phase)
                    Spacer()
                    Text("\(Int(progress * 100))%").foregroundStyle(.secondary).monospacedDigit()
                }
                ProgressView(value: progress)
            }
        case .failed(let message):
            Button {
                status.prepare()
            } label: {
                Label("Retry download: \(message)", systemImage: "exclamationmark.triangle")
            }
            .foregroundStyle(.red)
        }
    }
}

struct DictationDetailsView: View {
    @ObservedObject var remote: CantripRemoteModel
    @ObservedObject private var vocabulary = DictationVocabularyStore.shared
    @ObservedObject private var diagnostics = DictationDiagnostics.shared
    @StateObject private var benchmark = DictationBenchmark()
    @State private var confirmForget = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Words", value: "\(vocabulary.terms.count)")
                LabeledContent("From contacts", value: "\(vocabulary.contactNames)")
                Text(vocabulary.macStatus).font(.caption).foregroundStyle(.secondary)
                #if os(iOS)
                LabeledContent("Contacts access", value: DictationVocabularyStore.contactsStatusText)
                #endif
                Button {
                    vocabulary.refresh(remote: remote)
                } label: {
                    HStack {
                        Label("Refresh names", systemImage: "arrow.clockwise")
                        if vocabulary.refreshing { Spacer(); ProgressView() }
                    }
                }
                .disabled(vocabulary.refreshing)
                if !vocabulary.terms.isEmpty {
                    NavigationLink("Show words") { DictationWordListView() }
                }
            } header: {
                Text("Names")
            } footer: {
                Text("Project, tab, memory note and Home task names plus the people you message, call and meet most come from your Mac over the paired connection; contact names come from this iPhone.")
            }

            Section {
                LabeledContent("Learned fixes", value: "\(vocabulary.corrections.count)")
                if !vocabulary.corrections.isEmpty {
                    Button("Forget learned fixes", role: .destructive) { confirmForget = true }
                }
            } header: {
                Text("Learning")
            } footer: {
                Text("When you correct a name before sending, it is boosted next time. After the same fix twice, an unusual misspelling is corrected automatically.")
            }

            if let report = diagnostics.last {
                Section("Last dictation") {
                    reportRows(report)
                }
            }

            Section {
                Button {
                    benchmark.run(terms: vocabulary.terms)
                } label: {
                    HStack {
                        Label("Test dictation speed", systemImage: "stopwatch")
                        if benchmark.running { Spacer(); ProgressView() }
                    }
                }
                .disabled(benchmark.running)
                if let status = benchmark.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(benchmark.results, id: \.self) { line in
                    Text(line).font(.caption.monospaced()).textSelection(.enabled)
                }
            } header: {
                Text("Speed test")
            } footer: {
                Text("Speaks sample sentences with a system voice, runs them through the dictation pipeline on this device and reports each stage's time. Nothing is sent anywhere.")
            }
        }
        .navigationTitle("Dictation")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Forget learned fixes?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { vocabulary.forgetLearnedWords() }
        }
    }

    @ViewBuilder private func reportRows(_ report: DictationReport) -> some View {
        LabeledContent("Engine", value: report.engine)
        LabeledContent("Release to text", value: Self.ms(report.releaseToTextMilliseconds))
        LabeledContent("Audio", value: String(format: "%.1f s in %d segment(s)", report.audioSeconds, report.segments))
        LabeledContent("Last segment", value: Self.ms(report.tailASRMilliseconds) + " + names " + Self.ms(report.tailBoostMilliseconds))
        LabeledContent("Cleanup rules", value: Self.ms(report.cleanupMilliseconds))
        if let polish = report.polishOutcome {
            LabeledContent("Apple Intelligence", value: (report.polishMilliseconds.map(Self.ms).map { $0 + " · " } ?? "") + polish)
        }
        transcriptRow("Live transcript", report.streamingText)
        if !report.modelText.isEmpty { transcriptRow("Model transcript", report.modelText) }
        transcriptRow("Final text", report.finalText)
    }

    private func transcriptRow(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.callout).textSelection(.enabled)
        }
    }

    static func ms(_ value: Double) -> String { "\(Int(value.rounded())) ms" }
}

private struct DictationWordListView: View {
    @ObservedObject private var vocabulary = DictationVocabularyStore.shared

    var body: some View {
        List(vocabulary.terms, id: \.self) { term in
            VStack(alignment: .leading, spacing: 2) {
                Text(term.text)
                Text("\(term.kind.rawValue) · \(term.sources.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Words")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// On-device speed test: synthesizes sentences with made-up names, runs them
/// through the same session, final pass and cleanup as real dictation.
@MainActor
final class DictationBenchmark: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status: String?
    @Published private(set) var results: [String] = []

    /// What is spoken, and the written text dictation should produce.
    static let sentences: [(text: String, reference: String, names: [String])] = [
        ("Ask Cantrip to open a tab for Zephyrly and check the QuillPad build.",
         "Ask Cantrip to open a tab for Zephyrly and check the QuillPad build.", ["Cantrip", "Zephyrly", "QuillPad"]),
        ("Let's meet at two, actually three, with Odalys Brennecke about the launch.",
         "Let's meet at 3, with Odalys Brennecke about the launch.", ["Odalys Brennecke"]),
        ("Um, so the backup on the server failed again around four fifteen this morning.",
         "So the backup on the server failed again around 4:15 this morning.", []),
        ("Tell Hermes to remind me to text Ferdinand Kowalczyk about dinner on Friday.",
         "Tell Hermes to remind me to text Ferdinand Kowalczyk about dinner on Friday.", ["Hermes", "Ferdinand Kowalczyk"]),
        ("First, restart the node. Second, rerun the tests. Third, ship the release.",
         "1. Restart the node. 2. Rerun the tests. 3. Ship the release.", []),
        ("I spent twelve hundred dollars on the Orbit Lane subscription last quarter.",
         "I spent $1,200 on the Orbit Lane subscription last quarter.", ["Orbit Lane"]),
    ]
    static let terms = ["Zephyrly", "QuillPad", "Odalys Brennecke", "Ferdinand Kowalczyk", "Orbit Lane", "Cantrip", "Hermes"]

    func run(terms existing: [DictationTerm]) {
        guard !running else { return }
        running = true
        results = []
        status = "Loading the dictation model…"
        Task {
            defer { running = false }
            let clock = ContinuousClock()
            let loadStart = clock.now
            do {
                await QwenVoiceEngine.shared.releaseMemory()
                try await DictationRecognizer.shared.prepare()
            } catch {
                status = "The dictation model is unavailable: \(error.localizedDescription)"
                return
            }
            let load = (clock.now - loadStart) / .milliseconds(1)
            let extra = Self.terms.map { DictationTerm(text: $0, kind: .project, weight: 1) }
            let vocabulary = DictationVocabulary.assemble(extra + existing, lexicon: SystemDictationLexicon.shared)
            let boostStart = clock.now
            await DictationRecognizer.shared.setVocabulary(vocabulary)
            let boostSetup = (clock.now - boostStart) / .milliseconds(1)
            results.append("Model load \(Self.whole(load)) ms · name list \(Self.whole(boostSetup)) ms")
            let rules = DictationVocabulary.rules(vocabulary, corrections: [])
            var release: [Double] = [], tail: [Double] = [], boost: [Double] = [], cleanup: [Double] = []
            var polish: [Double] = []
            var errors = 0, words = 0, namesHit = 0, names = 0
            for (index, sentence) in Self.sentences.enumerated() {
                status = "Sentence \(index + 1) of \(Self.sentences.count)…"
                guard let audio = await Self.speak(sentence.text) else {
                    status = "Could not synthesize speech on this device."
                    break
                }
                let session = DictationSession()
                var offset = 0
                while offset < audio.count {
                    let end = min(audio.count, offset + 683)
                    await session.append(samples: Array(audio[offset..<end]))
                    offset = end
                }
                await session.settle()
                let released = clock.now
                guard let transcript = await session.finish() else { continue }
                let cleanupStart = clock.now
                let text = DictationText.finalize(transcript.text, rules: rules) {
                    TextNormalizer.shared.normalizeSentence($0)
                }
                let done = clock.now
                release.append((done - released) / .milliseconds(1))
                tail.append(transcript.tailASRMilliseconds)
                boost.append(transcript.tailBoostMilliseconds)
                cleanup.append((done - cleanupStart) / .milliseconds(1))
                var final = text
                if let polished = await DictationPolisher.polish(
                    text, context: DictationPolishContext(terms: DictationVocabulary.relevant(vocabulary, to: text))
                ) {
                    polish.append(polished.milliseconds)
                    final = polished.text
                }
                let reference = DictationText.words(sentence.reference).map(\.key)
                let hypothesis = DictationText.words(final).map(\.key)
                errors += Self.distance(reference, hypothesis)
                words += reference.count
                names += sentence.names.count
                namesHit += sentence.names.filter { final.contains($0) }.count
                results.append("\(index + 1). \(final.replacingOccurrences(of: "\n", with: " "))")
                if transcript.raw != final { results.append("   model heard: \(transcript.raw)") }
                if transcript.text != transcript.raw { results.append("   with names: \(transcript.text)") }
            }
            await DictationRecognizer.shared.setVocabulary(existing)
            guard !release.isEmpty else { return }
            results.insert(contentsOf: [
                "Release → text p50 \(Self.whole(Self.percentile(release, 0.5))) ms · max \(Self.whole(release.max() ?? 0)) ms",
                "Last segment \(Self.whole(Self.percentile(tail, 0.5))) ms · names \(Self.whole(Self.percentile(boost, 0.5))) ms · rules \(Self.whole(Self.percentile(cleanup, 0.5))) ms",
                polish.isEmpty ? "Apple Intelligence cleanup unavailable"
                    : "Apple Intelligence p50 \(Self.whole(Self.percentile(polish, 0.5))) ms (after the text appears)",
                String(format: "Word errors %.1f%% · names %d/%d", Double(errors) * 100 / Double(max(words, 1)), namesHit, names),
            ], at: 1)
            status = "Done"
        }
    }

    private static func speak(_ text: String) async -> [Float]? {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        let converter = AudioConverter()
        var samples: [Float] = []
        let finished: Bool = await withCheckedContinuation { continuation in
            var resumed = false
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    if !resumed { resumed = true; continuation.resume(returning: true) }
                    return
                }
                if let converted = try? converter.resampleBuffer(pcm) { samples += converted }
            }
        }
        _ = synthesizer
        guard finished, !samples.isEmpty else { return nil }
        // Release shortly after the last word, as with push-to-talk.
        return [Float](repeating: 0, count: 4_000) + samples + [Float](repeating: 0, count: 3_200)
    }

    private static func distance(_ a: [String], _ b: [String]) -> Int {
        let hunks = DictationText.diff(a, b)
        return hunks.filter { !$0.isEqual }.map { max($0.old.count, $0.new.count) }.reduce(0, +)
    }

    private static func percentile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
    }

    private static func whole(_ value: Double) -> Int { Int(value.rounded()) }
}
