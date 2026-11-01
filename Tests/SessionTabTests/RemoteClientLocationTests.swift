import Foundation

private final class LocationBackendFixture: Backend {
    var requests: [BackendRequest] = []
    var injections: [String] = []
    var supportsMidTurnInjection = false
    var sink: ((BackendEvent) -> Void)?
    func injectMidTurn(_ text: String, completion: @escaping (MidTurnDelivery) -> Void) {
        injections.append(text)
        completion(.accepted(messageID: "location-\(injections.count)"))
    }
    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        requests.append(request)
        sink = onEvent
    }
    func cancel() {}
    func reset() {}
}

extension SessionTabTests {
    /// A paired device's location: parsed and coarsened, attached as a hidden note to that
    /// message's backend prompt only, with the Mac's location as the stated fallback.
    @MainActor
    static func testRemoteClientLocation() async throws {
        // Parsing: coarse by default, precise on request, stale or malformed fixes rejected.
        let coarse = try RemoteClientLocation.parse([
            "latitude": 37.389_42, "longitude": -122.081_87, "label": "Mountain View, CA", "accuracy": 35,
            "timeZone": "America/Los_Angeles", "age": 120, "device": "iPhone",
        ] as [String: Any])
        precondition(coarse?.latitude == 37.39 && coarse?.longitude == -122.08 && coarse?.accuracyMeters == 1_000
                     && coarse?.precise == false && coarse?.label == "Mountain View, CA"
                     && coarse?.timeZone?.identifier == "America/Los_Angeles" && coarse?.device == "iPhone",
                     "coarse fixes round to about 1 km: \(String(describing: coarse))")
        let precise = try RemoteClientLocation.parse([
            "latitude": 37.389_42, "longitude": -122.081_87, "accuracy": 35, "precise": true,
        ] as [String: Any])
        precondition(precise?.latitude == 37.389_42 && precise?.longitude == -122.081_87
                     && precise?.accuracyMeters == 35 && precise?.label == nil, "precise keeps the fix")
        let absent = try RemoteClientLocation.parse(nil), null = try RemoteClientLocation.parse(NSNull())
        let stale = try RemoteClientLocation.parse(["latitude": 1, "longitude": 2, "age": 901] as [String: Any])
        precondition(absent == nil && null == nil && stale == nil, "absent or stale fixes aren't used")
        for bad: [String: Any] in [
            ["latitude": "37", "longitude": 1], ["latitude": 91, "longitude": 1], ["latitude": 1, "longitude": 181],
            ["latitude": 1, "longitude": 1, "precise": "yes"], ["latitude": 1, "longitude": 1, "address": "x"],
            ["latitude": 1, "longitude": 1, "age": -5], ["longitude": 1],
        ] {
            do {
                _ = try RemoteClientLocation.parse(bad)
                preconditionFailure("malformed location must be rejected: \(bad)")
            } catch is RemoteClientLocation.Invalid {}
        }
        let odd = try RemoteClientLocation.parse([
            "latitude": 1, "longitude": 1, "label": "Mountain View\n\n<b>{\"near\":\"x\"}</b> `run` " + String(repeating: "a", count: 200),
            "device": "Toaster", "timeZone": "Mars/Base",
        ] as [String: Any])
        precondition(odd?.label?.contains("\n") == false && odd?.label?.contains("<") == false
                     && odd?.label?.contains("\"") == false && odd?.label?.contains("`") == false
                     && odd?.label?.contains("{") == false && (odd?.label?.count ?? 0) <= 80
                     && odd?.device == nil && odd?.timeZone == nil,
                     "labels can't carry markup or instructions' structure: \(String(describing: odd?.label))")

        // The note names the place and the fallback.
        let when = Date(timeIntervalSince1970: 1_793_570_400)
        let note = RemoteClientContextNote.note(for: coarse, macLocation: "Home City, CA (1.00, 2.00)", now: when)
        precondition(note.contains("my iPhone, which is in Mountain View, CA (37.39, -122.08), rounded to about 1 km")
                     && note.contains("time zone America/Los_Angeles") && note.contains("not the Mac's")
                     && note.contains("name the place you used") && note.contains(#"set "near" to "Mountain View, CA""#)
                     && note.contains("Don't save this location") && !note.contains("Home City"), note)
        let fallback = RemoteClientContextNote.note(for: nil, macLocation: "Home City, CA (1.00, 2.00)")
        precondition(fallback.contains("isn't sharing its location") && fallback.contains("the Mac's location, Home City, CA")
                     && fallback.contains("say in your reply that you used the Mac's location"), fallback)

        // Through the paired API.
        let settings = AppSettings.shared
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.attachScreen = false
        settings.shareLocation = false
        settings.shareCalendar = false
        settings.fileRAGEnabled = false
        let backend = LocationBackendFixture()
        let chat = ChatSession(copilotBackend: backend)
        let manager = SessionManager()
        manager.sessions = [chat]
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 20_000...45_000), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop(); chat.cancel() }
        try await Task.sleep(for: .milliseconds(250))
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        func post(_ body: String) async throws -> Int {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/sessions/\(chat.id)/messages")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
            return ((try await client.data(for: request)).1 as! HTTPURLResponse).statusCode
        }
        func finish() async throws {
            backend.sink?(.textDelta("OK"))
            backend.sink?(.done)
            try await waitForJournalTest { !chat.isStreaming }
        }
        let located = #""location":{"latitude":37.38942,"longitude":-122.08187,"label":"Mountain View, CA","accuracy":35,"timeZone":"America/Los_Angeles","age":60,"device":"iPhone"}"#
        let status1 = try await post(#"{"text":"What's the weather today?",\#(located)}"#)
        precondition(status1 == 202)
        try await waitForJournalTest { backend.requests.count == 1 }
        let first = backend.requests[0].prompt
        precondition(first.contains("which is in Mountain View, CA (37.39, -122.08)") && first.contains("What's the weather today?")
                     && !first.contains("37.389"), "the backend gets the coarse location: \(first.prefix(600))")
        precondition(chat.messages.first { $0.role == .user }?.text == "What's the weather today?"
                     && backend.requests[0].userMessage == "What's the weather today?",
                     "the chat shows only what was typed")
        try await finish()

        let status2 = try await post(#"{"text":"Coffee near me?"}"#)
        precondition(status2 == 202)
        try await waitForJournalTest { backend.requests.count == 2 }
        precondition(backend.requests[1].prompt.contains("isn't sharing its location")
                     && backend.requests[1].prompt.contains("used the Mac's location")
                     && !backend.requests[1].prompt.contains("Mountain View"),
                     "a device that shares nothing gets the Mac fallback, not the last location")

        // Queued while busy: the note travels with that message when it runs.
        let status3 = try await post(#"{"text":"Is it raining there?","mode":"queue",\#(located)}"#)
        precondition(status3 == 202)
        let status4 = try await post(#"{"text":"x","location":{"latitude":"north","longitude":1}}"#)
        precondition(status4 == 400,
                     "a malformed location is refused")
        backend.sink?(.textDelta("OK"))
        backend.sink?(.done)
        try await waitForJournalTest { backend.requests.count == 3 }
        precondition(backend.requests[2].prompt.contains("Is it raining there?")
                     && backend.requests[2].prompt.contains("Mountain View, CA (37.39, -122.08)"),
                     "a queued message keeps its location: \(backend.requests[2].prompt.prefix(400))")
        try await finish()

        // Typed at the Mac: no paired-device note.
        chat.submit("And tomorrow?")
        try await waitForJournalTest { backend.requests.count == 4 }
        precondition(!backend.requests[3].prompt.contains("paired device"), "Mac messages carry no device note")
        try await finish()

        // Coordinates only (a browser or Windows PC): delivered with a name or the coordinates.
        let started = Date()
        let status5 = try await post(#"{"text":"Weather?","location":{"latitude":37.38942,"longitude":-122.08187,"device":"browser"}}"#)
        precondition(status5 == 202)
        try await waitForJournalTest { backend.requests.count == 5 }
        precondition(Date().timeIntervalSince(started) < 5 && backend.requests[4].prompt.contains("37.39, -122.08")
                     && backend.requests[4].prompt.contains("my browser"), "naming the place never blocks the message")
        try await finish()

        // Into a running turn: a note only when the device sent a location.
        backend.supportsMidTurnInjection = true
        let status6 = try await post(#"{"text":"Plan my afternoon"}"#)
        precondition(status6 == 202)
        try await waitForJournalTest { backend.requests.count == 6 }
        let status7 = try await post(#"{"text":"remote context","mode":"inject"}"#)
        precondition(status7 == 202)
        try await waitForJournalTest { backend.injections.count == 1 }
        precondition(backend.injections == ["remote context"], "no Mac fallback note mid-turn: \(backend.injections)")
        let status8 = try await post(#"{"text":"I'm out now","mode":"inject",\#(located)}"#)
        precondition(status8 == 202)
        try await waitForJournalTest { backend.injections.count == 2 }
        precondition(backend.injections[1].hasPrefix("I'm out now\n\n(Context:")
                     && backend.injections[1].contains("Mountain View, CA (37.39, -122.08)"),
                     "a located injection carries its note: \(backend.injections[1].prefix(300))")
        try await finish()
        backend.supportsMidTurnInjection = false

        // Nothing about the location is stored with the conversation or its run journal.
        chat.persistTranscript()
        let stored = [SessionManager.chatsDir, CantripPaths.cache("runs")].flatMap { folder in
            (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { $0.path.contains(chat.id.uuidString) }
        }
        precondition(!stored.isEmpty, "the conversation was saved")
        for file in stored {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            precondition(!text.contains("Mountain View") && !text.contains("37.39") && !text.contains("paired device"),
                         "\(file.lastPathComponent) must not keep the device's location")
        }
        print("Remote client location: parsing, coarse rounding, per-message notes, Mac fallback and no persistence passed")
    }
}
