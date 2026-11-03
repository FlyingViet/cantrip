import Foundation
import UserNotifications

/// A Mac notification from Cantrip: a run finished, a tab needs input, a handoff, a backend, MCP
/// or storage problem.
struct MacNotice: Codable, Equatable {
    var id: String
    var title: String
    var body: String
    /// The tab it's about; clicking it opens that tab.
    var sessionID: String?
    var sound = false
    /// A finished run: not shown while Cantrip's own window is in front.
    var runFinished = false
}

/// The background engine's notifications, waiting for Cantrip.app to post them: a login agent
/// can't post its own. Numbered, so the app asks for the ones after the last it saw
/// (`HostControl` "app-connection"), and capped, so nothing piles up while the app isn't open.
struct MacNoticeOutbox {
    enum Entry: Equatable {
        case post(MacNotice)
        case remove([String])
    }

    private(set) var seq = 0
    private var entries: [(seq: Int, at: Date, entry: Entry)] = []
    let capacity: Int

    init(capacity: Int = 100) {
        self.capacity = capacity
    }

    mutating func append(_ entry: Entry, at date: Date = Date()) {
        seq += 1
        entries.append((seq, date, entry))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    /// Entries after `cursor`. An app that hasn't asked this engine before (nil) gets only the
    /// last `recent` seconds' worth: what happened while it relaunched, not stale news.
    func entries(after cursor: Int?, now: Date = Date(), recent: TimeInterval = 30) -> [(seq: Int, entry: Entry)] {
        entries.filter { item in
            if let cursor { return item.seq > cursor }
            return now.timeIntervalSince(item.at) <= recent
        }.map { ($0.seq, $0.entry) }
    }

    func json(after cursor: Int?, now: Date = Date()) -> [[String: Any]] {
        entries(after: cursor, now: now).compactMap { seq, entry in
            switch entry {
            case .post(let notice):
                guard let data = try? JSONEncoder().encode(notice),
                      let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
                return ["seq": seq, "post": object]
            case .remove(let ids):
                return ["seq": seq, "remove": ids]
            }
        }
    }

    /// The app's side of `json(after:)`.
    static func parse(_ items: [[String: Any]]) -> [(seq: Int, entry: Entry)] {
        items.compactMap { item in
            guard let seq = item["seq"] as? Int else { return nil }
            if let ids = item["remove"] as? [String] { return (seq, .remove(ids)) }
            guard let object = item["post"],
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let notice = try? JSONDecoder().decode(MacNotice.self, from: data) else { return nil }
            return (seq, .post(notice))
        }
    }
}

/// Posts Cantrip's Mac notifications: in Notification Center from the app, or into the outbox
/// Cantrip.app drains when this process is the background engine.
enum MacNotices {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var outbox = MacNoticeOutbox()
    /// This engine's outbox; an app that knew another (the engine restarted) starts over.
    static let outboxID = UUID().uuidString

    static func post(_ notice: MacNotice) {
        if HostMode.isEngine {
            lock.withLock { outbox.append(.post(notice)) }
        } else {
            show(notice)
        }
    }

    static func remove(_ ids: [String]) {
        if HostMode.isEngine {
            lock.withLock { outbox.append(.remove(ids)) }
        } else {
            withdraw(ids)
        }
    }

    static func outboxJSON(after cursor: Int?) -> (seq: Int, entries: [[String: Any]]) {
        lock.withLock { (outbox.seq, outbox.json(after: cursor)) }
    }

    /// Shows it in Notification Center, asking for permission the first time.
    static func show(_ notice: MacNotice) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            if notice.sound { content.sound = .default }
            if let sessionID = notice.sessionID { content.userInfo = ["sessionID": sessionID] }
            center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)) { error in
                if error != nil { Log.write("notifications: couldn't post \(notice.id)") }
            }
        }
    }

    static func withdraw(_ ids: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
