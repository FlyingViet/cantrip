import Foundation

// Live Activities don't exist on macOS. These inert stand-ins let the shared live-status
// code compile; with no activities and authorization off, it only keeps its widget cache.

protocol ActivityAttributes {
    associatedtype ContentState: Codable & Hashable
}

enum ActivityState: Equatable {
    case active, ended, dismissed, stale, pending
}

enum ActivityUIDismissalPolicy {
    case `default`, immediate
    static func after(_ date: Date) -> ActivityUIDismissalPolicy { .default }
}

enum PushType { case token }

struct ActivityAuthorizationInfo {
    var areActivitiesEnabled: Bool { false }
}

struct ActivityContent<State> {
    var state: State
    var staleDate: Date?
}

struct ActivityUnavailableError: Error {}

final class Activity<Attributes: ActivityAttributes>: @unchecked Sendable {
    let id = UUID().uuidString
    var activityState: ActivityState { .ended }
    var pushToken: Data? { nil }
    var content: ActivityContent<Attributes.ContentState> { fatalError("Live Activities are unavailable on macOS") }

    static var activities: [Activity<Attributes>] { [] }
    static var pushToStartTokenUpdates: AsyncStream<Data> { AsyncStream { $0.finish() } }
    static var activityUpdates: AsyncStream<Activity<Attributes>> { AsyncStream { $0.finish() } }
    var pushTokenUpdates: AsyncStream<Data> { AsyncStream { $0.finish() } }
    var activityStateUpdates: AsyncStream<ActivityState> { AsyncStream { $0.finish() } }

    static func request(
        attributes: Attributes, content: ActivityContent<Attributes.ContentState>, pushType: PushType?
    ) throws -> Activity<Attributes> {
        throw ActivityUnavailableError()
    }

    func update(_ content: ActivityContent<Attributes.ContentState>) async {}
    func end(_ content: ActivityContent<Attributes.ContentState>?, dismissalPolicy: ActivityUIDismissalPolicy) async {}
}
