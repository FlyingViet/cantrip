import Foundation

// The background engine's notification outbox (`MacNoticeOutbox`): Cantrip.app asks for what's
// after its cursor; a first ask gets only the last few seconds; old entries fall off the end.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(message)")
    }
}

let start = Date(timeIntervalSince1970: 1_000)
let done = MacNotice(id: "run-1", title: "Cantrip — Fix the build", body: "Done", sessionID: "tab-1", runFinished: true)
let input = MacNotice(id: "input-1", title: "Cantrip needs your input", body: "Open Cantrip", sessionID: "tab-2", sound: true)

var outbox = MacNoticeOutbox(capacity: 3)
expect(outbox.seq == 0 && outbox.entries(after: nil, now: start).isEmpty, "starts empty")
outbox.append(.post(done), at: start)
outbox.append(.post(input), at: start.addingTimeInterval(40))
outbox.append(.remove(["input-1"]), at: start.addingTimeInterval(50))
expect(outbox.seq == 3, "numbers each entry")
expect(outbox.entries(after: 1, now: start.addingTimeInterval(60)).map(\.seq) == [2, 3], "after the cursor")
expect(outbox.entries(after: 3, now: start.addingTimeInterval(60)).isEmpty, "nothing new")
expect(outbox.entries(after: nil, now: start.addingTimeInterval(60)).map(\.seq) == [2, 3],
       "a first ask gets the last 30 seconds, not stale news")

outbox.append(.post(done), at: start.addingTimeInterval(61))
expect(outbox.entries(after: 0, now: start.addingTimeInterval(61)).map(\.seq) == [2, 3, 4], "keeps the newest \(outbox.capacity)")

// Over the socket as JSON, and back.
let json = outbox.json(after: 1, now: start.addingTimeInterval(61))
expect(JSONSerialization.isValidJSONObject(["notices": json]), "valid JSON")
let parsed = MacNoticeOutbox.parse(json)
expect(parsed.map(\.seq) == [2, 3, 4], "parses every entry")
expect(parsed.first?.entry == .post(input) && parsed[1].entry == .remove(["input-1"]) && parsed[2].entry == .post(done),
       "round-trips notices and removals: \(parsed)")
expect(MacNoticeOutbox.parse([["seq": 9, "post": ["id": "x"]], ["post": ["id": "y"]]]).isEmpty, "skips malformed entries")

// The engine queues its notifications instead of posting them.
HostMode.isHeadless = true
HostMode.isEngine = true
let before = MacNotices.outboxJSON(after: nil).seq
MacNotices.post(done)
MacNotices.remove(["run-1"])
let queued = MacNotices.outboxJSON(after: before)
expect(queued.seq == before + 2 && MacNoticeOutbox.parse(queued.entries).map(\.entry) == [.post(done), .remove(["run-1"])],
       "the engine's notifications wait in the outbox")

if failures > 0 {
    print("\(failures) background engine test(s) failed")
    exit(1)
}
print("Background engine outbox tests passed")
