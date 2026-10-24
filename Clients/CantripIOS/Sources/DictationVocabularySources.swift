import Foundation
#if os(iOS)
import Contacts
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// `GET /api/v1/voice/vocabulary`: names and terms the Mac knows (tabs,
/// memory notes, Home tasks and trackers, busiest Messages/Calendar/call
/// contacts). Stays on your devices over the paired connection.
struct CantripVoiceVocabulary: Decodable, Sendable {
    struct Term: Decodable, Sendable {
        let text: String
        let kind: DictationTerm.Kind
        let weight: Double
        let sources: [String]?
        let aliases: [String]?
    }

    struct Person: Decodable, Sendable {
        let name: String?
        let handles: [String]
        let count: Int
        let sources: [String]?
    }

    let version: Int
    let terms: [Term]
    let people: [Person]
    let unavailable: [String]?
}

/// The system spelling dictionary, cached; names it does not know are
/// treated as terms whose casing can be restored anywhere. Used from the main actor.
final class SystemDictationLexicon: DictationLexicon, @unchecked Sendable {
    static let shared = SystemDictationLexicon()
    private var cache: [String: Bool] = [:]
    #if os(iOS)
    private let checker = UITextChecker()
    #endif

    func isWord(_ word: String) -> Bool {
        let word = word.lowercased()
        if let cached = cache[word] { return cached }
        let known: Bool
        #if os(iOS)
        let range = checker.rangeOfMisspelledWord(
            in: word, range: NSRange(location: 0, length: (word as NSString).length),
            startingAt: 0, wrap: false, language: "en_US"
        )
        known = range.location == NSNotFound
        #elseif os(macOS)
        let range = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "en_US", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        known = range.location == NSNotFound
        #else
        known = true
        #endif
        cache[word] = known
        return known
    }
}

/// Your dictation vocabulary: Mac-provided terms and people, your iPhone
/// contacts and words learned from your corrections. Kept on this device.
@MainActor
final class DictationVocabularyStore: ObservableObject {
    static let shared = DictationVocabularyStore()
    static let contactsKey = "hermes.dictationContacts"
    private static let refreshInterval: TimeInterval = 10 * 60

    @Published private(set) var terms: [DictationTerm] = []
    @Published private(set) var corrections: [DictationCorrection] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var macStatus = "Not loaded"
    @Published private(set) var contactNames = 0
    @Published private(set) var refreshing = false
    private(set) var rules: [DictationText.Rule] = []

    private let directory: URL
    private var refreshTask: Task<Void, Never>?

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictation", isDirectory: true)
        corrections = Self.load([DictationCorrection].self, from: self.directory.appendingPathComponent("corrections.json")) ?? []
        terms = Self.load([DictationTerm].self, from: self.directory.appendingPathComponent("vocabulary.json")) ?? []
        rules = DictationVocabulary.rules(terms, corrections: corrections)
        let cached = terms
        if !cached.isEmpty { Task { await DictationRecognizer.shared.setVocabulary(cached) } }
    }

    static var contactsEnabled: Bool {
        UserDefaults.standard.object(forKey: contactsKey) as? Bool ?? true
    }

    /// Refreshes in the background when stale; dictation always uses the
    /// latest list it already has.
    func refreshIfNeeded(remote: CantripRemoteModel?) {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < Self.refreshInterval { return }
        refresh(remote: remote)
    }

    func refresh(remote: CantripRemoteModel?) {
        guard refreshTask == nil else { return }
        refreshing = true
        refreshTask = Task { [weak self] in
            await self?.rebuild(remote: remote)
            self?.refreshTask = nil
            self?.refreshing = false
        }
    }

    private func rebuild(remote: CantripRemoteModel?) async {
        var inputs: [DictationTerm] = []
        var people: [CantripVoiceVocabulary.Person] = []
        let lexicon = SystemDictationLexicon.shared
        if let remote, remote.isConfigured {
            do {
                if let vocabulary = try await remote.voiceVocabulary() {
                    inputs += vocabulary.terms.map {
                        DictationTerm(text: $0.text, kind: $0.kind, weight: $0.weight,
                                      aliases: $0.aliases ?? [], sources: $0.sources ?? ["mac"])
                    }
                    people = vocabulary.people
                    let missing = vocabulary.unavailable ?? []
                    macStatus = "\(vocabulary.terms.count) terms, \(people.count) people from your Mac"
                        + (missing.isEmpty ? "" : " (no \(missing.joined(separator: ", ")))")
                } else {
                    macStatus = "Update Cantrip on your Mac for its names; using tab and task titles."
                }
            } catch {
                macStatus = "Could not reach your Mac; using tab and task titles."
            }
            inputs += fallbackTerms(remote: remote, lexicon: lexicon)
        } else {
            macStatus = "Pair Cantrip Remote to add your Mac's project names."
        }
        let contacts = await Self.contactTerms(people: people, lexicon: lexicon)
        contactNames = contacts.filter { $0.kind == .person }.count
        inputs += contacts
        inputs += people.compactMap { person in
            guard let name = person.name else { return nil }
            return DictationTerm(text: name, kind: .person, weight: Self.personWeight(person.count),
                                 sources: person.sources ?? ["mac"])
        }
        inputs += DictationVocabulary.terms(from: corrections)
        apply(DictationVocabulary.assemble(inputs, lexicon: lexicon))
        lastRefresh = Date()
    }

    private func apply(_ terms: [DictationTerm]) {
        self.terms = terms
        rules = DictationVocabulary.rules(terms, corrections: corrections)
        Self.save(terms, to: directory.appendingPathComponent("vocabulary.json"))
        Task { await DictationRecognizer.shared.setVocabulary(terms) }
    }

    /// Tab titles, Home task titles and tracker fields such as company or contact.
    private func fallbackTerms(remote: CantripRemoteModel, lexicon: DictationLexicon) -> [DictationTerm] {
        var terms: [DictationTerm] = []
        for session in remote.sessions {
            for text in DictationVocabulary.titleCandidates(session.title, lexicon: lexicon) {
                terms.append(DictationTerm(text: text, kind: .project, weight: 0.5, sources: ["tab"]))
            }
        }
        let fieldKinds: [(String, DictationTerm.Kind)] = [
            ("company", .company), ("organization", .company), ("vendor", .company), ("provider", .company),
            ("contact", .person), ("interviewer", .person), ("recruiter", .person), ("person", .person),
            ("name", .other), ("festival", .place), ("venue", .place), ("artist", .other),
        ]
        for task in remote.homeTasks {
            for text in DictationVocabulary.titleCandidates(task.title, lexicon: lexicon) {
                terms.append(DictationTerm(text: text, kind: .task, weight: 0.4, sources: ["task"]))
            }
            for record in task.workspace?.records ?? [] {
                for (field, value) in record.values {
                    let lower = field.lowercased()
                    guard let kind = fieldKinds.first(where: { lower.contains($0.0) })?.1 else { continue }
                    terms.append(DictationTerm(text: value, kind: kind, weight: 0.55, sources: ["tracker"]))
                }
            }
        }
        return terms
    }

    private static func personWeight(_ count: Int) -> Double {
        0.55 + 0.4 * min(1, log(Double(count) + 1) / log(200))
    }

    #if os(iOS)
    static func requestContactsAccess() async -> Bool {
        let store = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            return (try? await store.requestAccess(for: .contacts)) ?? false
        default:
            return false
        }
    }

    /// Asks once, after a dictation has landed (never while you are holding the mic).
    func askForContactsOnce(remote: CantripRemoteModel?) {
        let key = "hermes.dictationContactsAsked"
        guard Self.contactsEnabled, !UserDefaults.standard.bool(forKey: key),
              CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else { return }
        UserDefaults.standard.set(true, forKey: key)
        Task {
            if await Self.requestContactsAccess() {
                lastRefresh = nil
                refresh(remote: remote)
            }
        }
    }

    static var contactsStatusText: String {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return "All contacts"
        case .limited: return "Selected contacts"
        case .notDetermined: return "Not asked yet"
        default: return "Off in iOS Settings"
        }
    }
    #endif

    /// Contact names, ranked by how often the Mac saw you talk to them.
    private static func contactTerms(
        people: [CantripVoiceVocabulary.Person], lexicon: DictationLexicon
    ) async -> [DictationTerm] {
        #if os(iOS)
        guard contactsEnabled else { return [] }
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized || status == .limited else { return [] }
        var counts: [String: Int] = [:]
        for person in people {
            for handle in person.handles {
                if let key = handleKey(handle) { counts[key] = max(counts[key] ?? 0, person.count) }
            }
        }
        let contacts: [(given: String, family: String, nickname: String, organization: String, handles: [String])] =
            await Task.detached(priority: .utility) {
                let keys: [CNKeyDescriptor] = [
                    CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
                    CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
                ] as [CNKeyDescriptor]
                var found: [(String, String, String, String, [String])] = []
                try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
                    let handles = contact.phoneNumbers.map(\.value.stringValue)
                        + contact.emailAddresses.map { String($0.value) }
                    found.append((contact.givenName, contact.familyName, contact.nickname,
                                  contact.organizationName, handles))
                }
                return found
            }.value
        var terms: [DictationTerm] = []
        for contact in contacts {
            let talked = contact.handles.compactMap(handleKey).compactMap { counts[$0] }.max()
            let weight = talked.map(personWeight) ?? 0.2
            let full = [contact.given, contact.family].filter { !$0.isEmpty }.joined(separator: " ")
            if full.split(separator: " ").count >= 2 || (!full.isEmpty && !lexicon.isWord(full)) {
                terms.append(DictationTerm(text: full, kind: .person, weight: weight, sources: ["contacts"]))
            }
            if talked != nil, contact.given.count >= 4, !lexicon.isWord(contact.given) {
                terms.append(DictationTerm(text: contact.given, kind: .person, weight: weight - 0.05, sources: ["contacts"]))
            }
            if !contact.nickname.isEmpty, talked != nil {
                terms.append(DictationTerm(text: contact.nickname, kind: .person, weight: weight - 0.1, sources: ["contacts"]))
            }
            if !contact.organization.isEmpty {
                terms.append(DictationTerm(text: contact.organization, kind: .company, weight: min(weight, 0.3), sources: ["contacts"]))
            }
        }
        return terms
        #else
        return []
        #endif
    }

    /// Phone numbers by their last ten digits, emails lowercased (matching the Mac).
    nonisolated static func handleKey(_ handle: String) -> String? {
        let value = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("@") { return value.lowercased() }
        let digits = value.filter { $0.isASCII && $0.isNumber }
        guard digits.count >= 7 else { return nil }
        return String(digits.suffix(10))
    }

    // MARK: Learning

    /// Remembers names you fixed before sending, so they are boosted next time
    /// (and replaced automatically once you have fixed them twice).
    func learn(dictated: String, sent: String) {
        let substitutions = DictationText.substitutions(dictated: dictated, final: sent)
        guard !substitutions.isEmpty else { return }
        let lexicon = SystemDictationLexicon.shared
        corrections = DictationVocabulary.record(substitutions, into: corrections, isWord: lexicon.isWord)
        Self.save(corrections, to: directory.appendingPathComponent("corrections.json"))
        let learned = DictationVocabulary.terms(from: corrections)
        apply(DictationVocabulary.assemble(learned + terms.filter { $0.kind != .learned }, lexicon: lexicon))
    }

    func forgetLearnedWords() {
        corrections = []
        Self.save(corrections, to: directory.appendingPathComponent("corrections.json"))
        apply(terms.filter { $0.kind != .learned })
    }

    // MARK: Files

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Per-stage timings and texts of the last dictation, shown in Settings so
/// the original transcript is always recoverable.
struct DictationReport: Equatable, Sendable {
    var engine: String
    var audioSeconds: Double
    var segments: Int
    var releaseToTextMilliseconds: Double
    var drainMilliseconds: Double
    var tailASRMilliseconds: Double
    var tailBoostMilliseconds: Double
    var cleanupMilliseconds: Double
    var polishMilliseconds: Double?
    var polishOutcome: String?
    var streamingText: String
    var modelText: String
    var finalText: String
}

@MainActor
final class DictationDiagnostics: ObservableObject {
    static let shared = DictationDiagnostics()
    @Published var last: DictationReport?
    @Published var history: [DictationReport] = []

    func record(_ report: DictationReport) {
        last = report
        history = Array(([report] + history).prefix(20))
    }

    func update(_ transform: (inout DictationReport) -> Void) {
        guard var report = last else { return }
        transform(&report)
        last = report
        if !history.isEmpty { history[0] = report }
    }
}
