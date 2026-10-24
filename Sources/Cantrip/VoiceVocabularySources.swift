import Contacts
import Darwin
import EventKit
import Foundation
import NaturalLanguage
import SQLite3

/// Best-effort, read-only readers for `GET /api/v1/voice/vocabulary`. Nothing here asks for a
/// permission: a source Cantrip can't already read is skipped and named in `unavailable`.
/// Free of app types so tests compile it with VoiceVocabulary.swift alone.
enum VoiceVocabularySources {
    /// Why a source was skipped; reported as "<source>: <reason>".
    struct Unavailable: Error, Equatable {
        let reason: String
        init(_ reason: String) { self.reason = reason }

        /// Reported as "took longer than <timeout>" by the service.
        static let timedOut = Unavailable("took too long, so it was skipped")
    }

    // MARK: - Memory notes

    /// Proper nouns from the first `# ` heading (first 4 KB) of each top-level note, or the
    /// prettified file name when the heading has none. MEMORY.md, USER.md, hidden files,
    /// symlinks and the sessions folder are skipped.
    static func memoryNoteTerms(directory: URL, fileLimit: Int = 500,
                                deadline: DispatchTime = .distantFuture) throws -> [VoiceVocabulary.TermCandidate] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw Unavailable("the memory folder doesn't exist")
        }
        guard isDirectory.boolValue else { throw Unavailable("the memory folder isn't a folder") }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw Unavailable("Cantrip can't read the memory folder")
        }
        var terms: [VoiceVocabulary.TermCandidate] = []
        let notes = names.filter {
            !$0.hasPrefix(".") && $0.lowercased().hasSuffix(".md")
                && !VoiceVocabulary.excludedNoteNames.contains($0.lowercased())
        }.sorted()
        for name in notes.prefix(fileLimit) {
            guard DispatchTime.now() < deadline else { break }
            guard let prefix = readPrefix(directory.appendingPathComponent(name).path, bytes: 4_096) else { continue }
            let heading = VoiceVocabulary.firstHeading(in: String(decoding: prefix, as: UTF8.self))
            terms += VoiceVocabulary.noteTerms(fileName: name, heading: heading)
        }
        return terms
    }

    /// Up to `bytes` from a regular file, never following symlinks or blocking on FIFOs.
    static func readPrefix(_ path: String, bytes: Int) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        var buffer = [UInt8](repeating: 0, count: bytes)
        let count = read(descriptor, &buffer, bytes)
        return count > 0 ? Data(buffer.prefix(count)) : nil
    }

    // MARK: - Messages and call history

    /// Messages per handle over the last `days` days from a read-only chat.db. `message.date`
    /// is nanoseconds since 2001 on current macOS; values below 1e12 are seconds.
    static func messagePeople(databasePath: String, now: Date = Date(), days: Int = 60, limit: Int = 60,
                              deadline: DispatchTime = .distantFuture) throws -> [VoiceVocabulary.PersonCandidate] {
        let since = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSinceReferenceDate
        let sql = """
        SELECT h.id, COUNT(*) AS n
          FROM message m JOIN handle h ON h.ROWID = m.handle_id
         WHERE m.date >= ?1 OR (m.date < 1000000000000 AND m.date >= ?2)
         GROUP BY h.id ORDER BY n DESC LIMIT 2000
        """
        var rows: [(handle: String, name: String?, count: Int)] = []
        do {
            try SQLiteReader.query(path: databasePath, sql: sql,
                                   bindings: [Int64(since * 1_000_000_000), Int64(since)],
                                   deadline: deadline) { statement in
                guard let handle = SQLiteReader.text(statement, 0) else { return }
                rows.append((handle, nil, Int(sqlite3_column_int64(statement, 1))))
            }
        } catch let failure as SQLiteReader.Failure {
            throw failure.unavailable(missing: "there's no Messages history on this Mac",
                                      denied: "Cantrip can't read Messages (Full Disk Access is off)",
                                      schema: "the Messages database format isn't recognized")
        }
        return VoiceVocabulary.topHandles(rows, limit: limit, source: "messages")
    }

    /// Calls per address over the last `days` days from a read-only CallHistory.storedata
    /// (`ZCALLRECORD`: `ZADDRESS`, `ZNAME`, `ZDATE` in seconds since 2001).
    static func callPeople(databasePath: String, now: Date = Date(), days: Int = 60, limit: Int = 60,
                           deadline: DispatchTime = .distantFuture) throws -> [VoiceVocabulary.PersonCandidate] {
        let since = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSinceReferenceDate
        let sql = """
        SELECT CAST(ZADDRESS AS TEXT) AS address, MAX(NULLIF(TRIM(ZNAME), '')), COUNT(*) AS n
          FROM ZCALLRECORD
         WHERE ZDATE >= ?1 AND ZADDRESS IS NOT NULL
         GROUP BY address ORDER BY n DESC LIMIT 2000
        """
        var rows: [(handle: String, name: String?, count: Int)] = []
        do {
            try SQLiteReader.query(path: databasePath, sql: sql, bindings: [Int64(since)],
                                   deadline: deadline) { statement in
                guard let handle = SQLiteReader.text(statement, 0) else { return }
                rows.append((handle, SQLiteReader.text(statement, 1), Int(sqlite3_column_int64(statement, 2))))
            }
        } catch let failure as SQLiteReader.Failure {
            throw failure.unavailable(missing: "there's no call history on this Mac",
                                      denied: "Cantrip can't read call history (Full Disk Access is off)",
                                      schema: "the call history format isn't recognized")
        }
        return VoiceVocabulary.topHandles(rows, limit: limit, source: "calls")
    }

    // MARK: - Calendar

    /// Attendee and organizer names from 30 days ago to 14 days ahead, only when Cantrip
    /// already has full Calendar access. Returns the busiest `limit` names.
    static func calendarPeople(now: Date = Date(), limit: Int = 60,
                               deadline: DispatchTime = .distantFuture) throws -> [VoiceVocabulary.PersonCandidate] {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: break
        case .notDetermined: throw Unavailable("Cantrip hasn't been given Calendar access (it never asks for it here)")
        case .writeOnly: throw Unavailable("Cantrip only has add-only Calendar access")
        default: throw Unavailable("Calendar access is off for Cantrip")
        }
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-30 * 86_400),
                                                 end: now.addingTimeInterval(14 * 86_400), calendars: nil)
        var counts: [(name: String, count: Int)] = []
        var index: [String: Int] = [:]
        for event in store.events(matching: predicate) {
            guard DispatchTime.now() < deadline else { break }
            var seen = Set<String>()
            for participant in (event.attendees ?? []) + [event.organizer].compactMap({ $0 }) {
                guard !participant.isCurrentUser,
                      [.person, .unknown].contains(participant.participantType),
                      let name = participant.name.flatMap(VoiceVocabulary.plausiblePersonName),
                      seen.insert(name.lowercased()).inserted else { continue }
                if let position = index[name.lowercased()] {
                    counts[position].count += 1
                } else {
                    index[name.lowercased()] = counts.count
                    counts.append((name, 1))
                }
            }
        }
        return counts.enumerated()
            .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .prefix(limit)
            .map { .init(name: $0.element.name, handles: [], count: $0.element.count, source: "calendar") }
    }

    // MARK: - Contacts

    /// Normalized phone/email -> contact display name, only when Contacts access was already granted.
    static func contactDirectory(deadline: DispatchTime = .distantFuture) throws -> [String: String] {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: break
        case .notDetermined:
            throw Unavailable("Cantrip hasn't been given Contacts access (it never asks for it here), so phone numbers and email addresses have no names")
        default:
            throw Unavailable("Contacts access is off for Cantrip, so phone numbers and email addresses have no names")
        }
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        var directory: [String: String] = [:]
        var timedOut = false
        try CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, stop in
            guard DispatchTime.now() < deadline else {
                timedOut = true
                stop.pointee = true
                return
            }
            let fullName = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            let name = VoiceVocabulary.collapsed(fullName.isEmpty ? contact.organizationName : fullName)
            guard !name.isEmpty else { return }
            let handles = contact.phoneNumbers.map { $0.value.stringValue } + contact.emailAddresses.map { $0.value as String }
            for raw in handles {
                if let handle = VoiceVocabulary.normalizedHandle(raw), directory[handle] == nil {
                    directory[handle] = name
                }
            }
        }
        if timedOut { throw Unavailable.timedOut }
        return directory
    }

    // MARK: - Names in free text

    /// NLTagger personal, organization and place names (multi-word names joined). Each call
    /// returns a tagger closure for one thread; NLTagger instances are not thread-safe.
    static func makeNameTagger() -> VoiceVocabulary.NameTagger {
        let tagger = NLTagger(tagSchemes: [.nameType])
        return { text in
            guard !text.isEmpty else { return [] }
            tagger.string = text
            if text.count < 200 { tagger.setLanguage(.english, range: text.startIndex..<text.endIndex) }
            var entities: [VoiceVocabulary.NameEntity] = []
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                                 options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
                let kind: VoiceVocabulary.Kind?
                switch tag {
                case .personalName?: kind = .person
                case .organizationName?: kind = .company
                case .placeName?: kind = .place
                default: kind = nil
                }
                if let kind { entities.append(.init(text: String(text[range]), kind: kind)) }
                return true
            }
            return entities
        }
    }
}

/// Minimal read-only SQLite access (`file:...?mode=ro`) whose queries stop at a deadline.
enum SQLiteReader {
    struct Failure: Error {
        let code: Int32
        let systemErrno: Int32
        let message: String

        func unavailable(missing: String, denied: String, schema: String) -> VoiceVocabularySources.Unavailable {
            switch code & 0xff {
            case SQLITE_INTERRUPT: return .timedOut
            case SQLITE_NOTADB: return .init(schema)
            case SQLITE_CANTOPEN where systemErrno == ENOENT: return .init(missing)
            case SQLITE_CANTOPEN, SQLITE_PERM, SQLITE_AUTH: return .init(denied)
            case SQLITE_BUSY, SQLITE_LOCKED: return .init("the database was busy")
            case SQLITE_ERROR where message.contains("no such"): return .init(schema)
            default: return [EPERM, EACCES].contains(systemErrno) ? .init(denied) : .init("couldn't be read (SQLite error \(code))")
            }
        }
    }

    private final class Deadline {
        let time: DispatchTime
        init(_ time: DispatchTime) { self.time = time }
    }

    static func query(path: String, sql: String, bindings: [Int64], deadline: DispatchTime,
                      row: (OpaquePointer) throws -> Void) throws {
        // Classify a missing or permission-blocked file before SQLite turns either into CANTOPEN.
        let probe = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard probe >= 0 else {
            let error = errno
            throw Failure(code: SQLITE_CANTOPEN, systemErrno: error, message: String(cString: strerror(error)))
        }
        close(probe)
        var database: OpaquePointer?
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        let opened = sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        defer { sqlite3_close_v2(database) }
        guard opened == SQLITE_OK, let database else {
            throw Failure(code: opened, systemErrno: database.map(sqlite3_system_errno) ?? 0,
                          message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
        }
        sqlite3_busy_timeout(database, 250)
        let context = Unmanaged.passRetained(Deadline(deadline))
        defer { context.release() }
        sqlite3_progress_handler(database, 1_000, { context in
            guard let context else { return 0 }
            return DispatchTime.now() >= Unmanaged<Deadline>.fromOpaque(context).takeUnretainedValue().time ? 1 : 0
        }, context.toOpaque())
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure(database)
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), value)
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                try row(statement)
            } else if step == SQLITE_DONE {
                return
            } else {
                throw failure(database)
            }
        }
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private static func failure(_ database: OpaquePointer) -> Failure {
        Failure(code: sqlite3_extended_errcode(database), systemErrno: sqlite3_system_errno(database),
                message: String(cString: sqlite3_errmsg(database)))
    }
}

/// Gathers every source in parallel (each bounded in time), assembles the response, and
/// keeps the encoded JSON for 10 minutes. Call from a background queue, never the main actor.
/// The cache is lock-protected and everything else is immutable, hence `@unchecked Sendable`.
final class VoiceVocabularyService: @unchecked Sendable {
    /// Plain values copied from the main actor; `homeTasks` converts its copy lazily.
    struct Inputs {
        var tabTitles: [String] = []
        var homeTasks: () -> [VoiceVocabulary.HomeTask] = { [] }
        var memoryDirectory: URL?
    }

    struct Configuration {
        var messagesDatabase: URL
        var callHistoryDatabase: URL
        var readsCalendar = true
        var readsContacts = true
        var sourceTimeout: TimeInterval = 2
        var cacheLifetime: TimeInterval = 600

        static var standard: Configuration {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Configuration(
                messagesDatabase: home.appendingPathComponent("Library/Messages/chat.db"),
                callHistoryDatabase: home.appendingPathComponent(
                    "Library/Application Support/CallHistoryDB/CallHistory.storedata")
            )
        }
    }

    /// Counts and timing for one source; never names or handles.
    struct SourceReport {
        let name: String
        let milliseconds: Double
        let terms: Int
        let people: Int
        let unavailable: String?
    }

    struct SourceOutput {
        var terms: [VoiceVocabulary.TermCandidate] = []
        var people: [VoiceVocabulary.PersonCandidate] = []
        var directory: [String: String]?
    }

    let configuration: Configuration
    private let now: () -> Date
    private let log: (String) -> Void
    private let lock = NSLock()
    private var cached: (data: Data, expires: Date)?

    init(configuration: Configuration = .standard, now: @escaping () -> Date = Date.init,
         log: @escaping (String) -> Void = { _ in }) {
        self.configuration = configuration
        self.now = now
        self.log = log
    }

    /// The cached response, if it is still fresh.
    func cachedData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached, cached.expires > now() else { return nil }
        return cached.data
    }

    /// The cached response, or a freshly computed and cached one.
    func responseData(for inputs: Inputs) throws -> Data {
        if let data = cachedData() { return data }
        let started = DispatchTime.now()
        let (response, reports) = compute(inputs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(response)
        lock.lock()
        cached = (data, now().addingTimeInterval(configuration.cacheLifetime))
        lock.unlock()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        log("voice-vocabulary: terms=\(response.terms.count) people=\(response.people.count) "
            + "unavailable=\(response.unavailable.count) total_ms=\(String(format: "%.0f", elapsed)) "
            + reports.map { "\($0.name)_ms=\(String(format: "%.0f", $0.milliseconds))" }.joined(separator: " "))
        return data
    }

    func compute(_ inputs: Inputs) -> (response: VoiceVocabulary.Response, reports: [SourceReport]) {
        let date = now()
        let configuration = self.configuration
        let timeout = configuration.sourceTimeout
        var jobs: [(name: String, work: (DispatchTime) throws -> SourceOutput)] = [
            ("memory", { deadline in
                guard let directory = inputs.memoryDirectory else {
                    throw VoiceVocabularySources.Unavailable("no memory folder is configured")
                }
                return SourceOutput(terms: try VoiceVocabularySources.memoryNoteTerms(directory: directory, deadline: deadline))
            }),
            ("home", { _ in
                let tagger = VoiceVocabularySources.makeNameTagger()
                return SourceOutput(terms: VoiceVocabulary.homeTaskTerms(inputs.homeTasks()) {
                    VoiceVocabulary.isPersonalName($0, tagger: tagger)
                })
            }),
            ("home-records", { _ in
                SourceOutput(terms: VoiceVocabulary.workspaceEntityTerms(
                    inputs.homeTasks(), tagger: VoiceVocabularySources.makeNameTagger()))
            }),
            ("messages", { deadline in
                SourceOutput(people: try VoiceVocabularySources.messagePeople(
                    databasePath: configuration.messagesDatabase.path, now: date, deadline: deadline))
            }),
            ("calls", { deadline in
                SourceOutput(people: try VoiceVocabularySources.callPeople(
                    databasePath: configuration.callHistoryDatabase.path, now: date, deadline: deadline))
            }),
        ]
        if configuration.readsCalendar {
            jobs.append(("calendar", { deadline in
                let people = try VoiceVocabularySources.calendarPeople(now: date, deadline: deadline)
                return SourceOutput(terms: people.compactMap { person in
                    person.name.map { VoiceVocabulary.TermCandidate($0, .person, 0.6, sources: ["calendar"]) }
                }, people: people)
            }))
        }
        if configuration.readsContacts {
            jobs.append(("contacts", { deadline in
                SourceOutput(directory: try VoiceVocabularySources.contactDirectory(deadline: deadline))
            }))
        }

        let tabTerms = VoiceVocabulary.tabTerms(inputs.tabTitles)
        var reports = [SourceReport(name: "tabs", milliseconds: 0, terms: tabTerms.count, people: 0, unavailable: nil)]
        var terms = tabTerms
        var people: [VoiceVocabulary.PersonCandidate] = []
        var directory: [String: String]?
        var unavailable: [String] = []
        for outcome in Self.runBounded(jobs, timeout: timeout) {
            switch outcome.result {
            case .success(let output)?:
                terms += output.terms
                people += output.people
                if let found = output.directory { directory = found }
                reports.append(.init(name: outcome.name, milliseconds: outcome.milliseconds,
                                     terms: output.terms.count, people: output.people.count + (output.directory?.count ?? 0),
                                     unavailable: nil))
            case .failure(let error)?:
                var reason = (error as? VoiceVocabularySources.Unavailable)?.reason ?? "couldn't be read"
                if reason == VoiceVocabularySources.Unavailable.timedOut.reason {
                    reason = "took longer than \(Self.seconds(timeout)), so it was skipped"
                }
                unavailable.append("\(outcome.name): \(reason)")
                reports.append(.init(name: outcome.name, milliseconds: outcome.milliseconds, terms: 0, people: 0,
                                     unavailable: reason))
            case nil:
                let reason = "took longer than \(Self.seconds(timeout)), so it was skipped"
                unavailable.append("\(outcome.name): \(reason)")
                reports.append(.init(name: outcome.name, milliseconds: outcome.milliseconds, terms: 0, people: 0,
                                     unavailable: reason))
            }
        }
        if let directory { people = VoiceVocabulary.resolvingNames(people, directory: directory) }
        return (VoiceVocabulary.response(terms: terms, people: people, unavailable: unavailable, generatedAt: date),
                reports)
    }

    /// Runs every job at once and waits at most `timeout`; a job still running then has a nil
    /// result and its eventual output is discarded. Results keep the jobs' order.
    static func runBounded(_ jobs: [(name: String, work: (DispatchTime) throws -> SourceOutput)],
                           timeout: TimeInterval)
        -> [(name: String, result: Result<SourceOutput, Error>?, milliseconds: Double)] {
        final class Box {
            let lock = NSLock()
            var results: [Int: (Result<SourceOutput, Error>, Double)] = [:]
            var closed = false
        }
        let box = Box()
        let group = DispatchGroup()
        let started = DispatchTime.now()
        let deadline = started + timeout
        for (index, job) in jobs.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let begin = DispatchTime.now()
                let result = Result { try job.work(deadline) }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - begin.uptimeNanoseconds) / 1_000_000
                box.lock.lock()
                if !box.closed { box.results[index] = (result, elapsed) }
                box.lock.unlock()
                group.leave()
            }
        }
        _ = group.wait(timeout: deadline)
        box.lock.lock()
        box.closed = true
        let results = box.results
        box.lock.unlock()
        let waited = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        return jobs.enumerated().map { index, job in
            (job.name, results[index]?.0, results[index]?.1 ?? waited)
        }
    }

    private static func seconds(_ interval: TimeInterval) -> String {
        interval == interval.rounded() ? "\(Int(interval)) s" : String(format: "%.1f s", interval)
    }
}
