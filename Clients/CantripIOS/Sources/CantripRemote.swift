import CryptoKit
import Foundation
import MarkdownUI
import Network
import Security
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum CantripRemoteConnectionState: Equatable {
    case disconnected
    case reconnecting
    case connected
}

enum CantripDeliveryMode: String, CaseIterable, Identifiable {
    case auto
    case queue
    case interrupt
    case inject

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .queue: return "Queue"
        case .interrupt: return "Redirect"
        case .inject: return "Inject"
        }
    }
}

struct CantripRemoteActivity: Decodable, Equatable, Identifiable {
    let id: String
    let title: String
    let toolName: String
    let state: String
    var input: String? = nil
    var output: String? = nil
}

enum CantripRemoteSubagentStatus: Equatable {
    /// Launched but not started: Copilot starts a background agent only once
    /// the main agent waits for it or ends its turn.
    case queued
    case running
    case idle
    case completed
    case failed
    case cancelled
    case working

    init(rawValue: String) {
        switch rawValue {
        case "queued": self = .queued
        case "running": self = .running
        case "idle": self = .idle
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default: self = .working
        }
    }

    var isLive: Bool {
        switch self {
        case .queued, .running, .idle, .working: return true
        case .completed, .failed, .cancelled: return false
        }
    }

    var isCancellableState: Bool {
        switch self {
        case .queued, .running, .idle: return true
        case .completed, .failed, .cancelled, .working: return false
        }
    }

    var displayText: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Running"
        case .idle: return "Waiting"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        case .working: return "Working"
        }
    }
}

extension CantripRemoteSubagentStatus: Decodable {
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self.init(rawValue: raw)
    }
}

struct CantripRemoteSubagentStep: Decodable, Equatable, Identifiable {
    let id: String
    let title: String
    let toolName: String
    let state: String

    private enum CodingKeys: String, CodingKey {
        case title, toolName, state
    }

    init(title: String = "", toolName: String = "", state: String = "") {
        self.title = title
        self.toolName = toolName
        self.state = state
        self.id = [title, toolName, state].joined(separator: "\u{1f}")
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: container.decodeLenient(String.self, forKey: .title, default: ""),
            toolName: container.decodeLenient(String.self, forKey: .toolName, default: ""),
            state: container.decodeLenient(String.self, forKey: .state, default: "")
        )
    }
}

/// One titled step of a reply's (or subagent's) reasoning, split by the Mac host.
struct CantripRemoteReasoningStep: Decodable, Equatable {
    let title: String
    let text: String
    /// 1-based position in the whole reply or subagent run; subagents send only their latest steps.
    let number: Int?

    private enum CodingKeys: String, CodingKey {
        case title, text, number
    }

    init(title: String, text: String = "", number: Int? = nil) {
        self.title = title
        self.text = text
        self.number = number
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: container.decodeLenient(String.self, forKey: .title, default: ""),
            text: container.decodeLenient(String.self, forKey: .text, default: ""),
            number: container.decodeLenient(Int.self, forKey: .number)
        )
    }
}

struct CantripRemoteSubagent: Decodable, Equatable, Identifiable {
    let id: String
    let agentID: String
    let name: String
    let agentType: String
    let summary: String
    let model: String?
    let effort: String?
    let background: Bool
    let status: CantripRemoteSubagentStatus
    let startedAt: TimeInterval?
    let finishedAt: TimeInterval?
    let intent: String?
    let currentStep: String?
    let latestMessage: String?
    let steps: Int
    let tokens: Int
    let error: String?
    let canCancel: Bool
    let recentSteps: [CantripRemoteSubagentStep]
    let reasoning: [CantripRemoteReasoningStep]
    /// A finished card follows this many reply blocks; nil from hosts that don't place cards.
    let textBlock: Int?

    private enum CodingKeys: String, CodingKey {
        case id, agentID, name, agentType, summary, model, effort, background, status
        case startedAt, finishedAt, intent, currentStep, latestMessage, steps, tokens, error
        case canCancel, recentSteps, reasoning, textBlock
    }

    init(
        id: String,
        agentID: String,
        name: String = "",
        agentType: String = "",
        summary: String = "",
        model: String? = nil,
        effort: String? = nil,
        background: Bool = false,
        status: CantripRemoteSubagentStatus = .working,
        startedAt: TimeInterval? = nil,
        finishedAt: TimeInterval? = nil,
        intent: String? = nil,
        currentStep: String? = nil,
        latestMessage: String? = nil,
        steps: Int = 0,
        tokens: Int = 0,
        error: String? = nil,
        canCancel: Bool = false,
        recentSteps: [CantripRemoteSubagentStep] = [],
        reasoning: [CantripRemoteReasoningStep] = [],
        textBlock: Int? = nil
    ) {
        self.id = id
        self.agentID = agentID
        self.name = name
        self.agentType = agentType
        self.summary = summary
        self.model = model
        self.effort = effort
        self.background = background
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.intent = intent
        self.currentStep = currentStep
        self.latestMessage = latestMessage
        self.steps = steps
        self.tokens = tokens
        self.error = error
        self.canCancel = canCancel
        self.recentSteps = recentSteps
        self.reasoning = reasoning
        self.textBlock = textBlock
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            agentID: try container.decode(String.self, forKey: .agentID),
            name: container.decodeLenient(String.self, forKey: .name, default: ""),
            agentType: container.decodeLenient(String.self, forKey: .agentType, default: ""),
            summary: container.decodeLenient(String.self, forKey: .summary, default: ""),
            model: container.decodeLenient(String.self, forKey: .model),
            effort: container.decodeLenient(String.self, forKey: .effort),
            background: container.decodeLenient(Bool.self, forKey: .background, default: false),
            status: container.decodeLenient(CantripRemoteSubagentStatus.self, forKey: .status, default: .working),
            startedAt: container.decodeLenient(TimeInterval.self, forKey: .startedAt),
            finishedAt: container.decodeLenient(TimeInterval.self, forKey: .finishedAt),
            intent: container.decodeLenient(String.self, forKey: .intent),
            currentStep: container.decodeLenient(String.self, forKey: .currentStep),
            latestMessage: container.decodeLenient(String.self, forKey: .latestMessage),
            steps: container.decodeLenient(Int.self, forKey: .steps, default: 0),
            tokens: container.decodeLenient(Int.self, forKey: .tokens, default: 0),
            error: container.decodeLenient(String.self, forKey: .error),
            canCancel: container.decodeLenient(Bool.self, forKey: .canCancel, default: false),
            recentSteps: container.decodeLenient([CantripRemoteSubagentStep].self, forKey: .recentSteps, default: []),
            reasoning: container.decodeLenient([CantripRemoteReasoningStep].self, forKey: .reasoning, default: []),
            textBlock: container.decodeLenient(Int.self, forKey: .textBlock)
        )
    }
}

/// Work Cantrip Home handed to an open project tab, tracked as a nested task.
struct CantripRemoteDelegation: Decodable, Equatable, Identifiable {
    enum Status: String, Decodable, Equatable {
        case queued, running, completed, failed, cancelled

        var isActive: Bool { self == .queued || self == .running }
    }

    let id: String
    let tabID: String
    let tabTitle: String
    let summary: String
    let prompt: String
    let status: Status
    let startedAt: TimeInterval?
    let finishedAt: TimeInterval?
    let latestStatus: String?
    /// The tab is waiting for the user's answer to one of its questions.
    let needsInput: Bool
    let result: String?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case id, tabID, tabTitle, summary, prompt, status, startedAt, finishedAt
        case latestStatus, needsInput, result, error
    }

    init(
        id: String,
        tabID: String,
        tabTitle: String = "",
        summary: String = "",
        prompt: String = "",
        status: Status = .running,
        startedAt: TimeInterval? = nil,
        finishedAt: TimeInterval? = nil,
        latestStatus: String? = nil,
        needsInput: Bool = false,
        result: String? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.tabID = tabID
        self.tabTitle = tabTitle
        self.summary = summary
        self.prompt = prompt
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.latestStatus = latestStatus
        self.needsInput = needsInput
        self.result = result
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: container.decodeLenient(String.self, forKey: .id, default: UUID().uuidString),
            tabID: container.decodeLenient(String.self, forKey: .tabID, default: ""),
            tabTitle: container.decodeLenient(String.self, forKey: .tabTitle, default: ""),
            summary: container.decodeLenient(String.self, forKey: .summary, default: ""),
            prompt: container.decodeLenient(String.self, forKey: .prompt, default: ""),
            status: container.decodeLenient(Status.self, forKey: .status, default: .running),
            startedAt: container.decodeLenient(TimeInterval.self, forKey: .startedAt),
            finishedAt: container.decodeLenient(TimeInterval.self, forKey: .finishedAt),
            latestStatus: container.decodeLenient(String.self, forKey: .latestStatus),
            needsInput: container.decodeLenient(Bool.self, forKey: .needsInput, default: false),
            result: container.decodeLenient(String.self, forKey: .result),
            error: container.decodeLenient(String.self, forKey: .error)
        )
    }
}

/// Cantrip Home only: what a handed-off tab reported, posted once into Home's chat as a message
/// with role `handoff`. `detail` is the tab's own text, so it is shown as plain data in a card.
struct CantripRemoteHandoffResult: Decodable, Equatable {
    enum State: String, Decodable, Equatable {
        /// The user answered the tab's question and it is working again.
        case working
        case needsInput, completed, failed, cancelled
        /// A state from a newer Mac.
        case other
    }

    let delegationID: String
    let tabID: String
    let tabTitle: String
    let summary: String
    let state: State
    let detail: String
    let startedAt: TimeInterval?
    let finishedAt: TimeInterval?
    let updatedAt: TimeInterval?

    private enum CodingKeys: String, CodingKey {
        case delegationID, tabID, tabTitle, summary, state, detail, startedAt, finishedAt, updatedAt
    }

    init(
        delegationID: String = UUID().uuidString,
        tabID: String,
        tabTitle: String = "",
        summary: String = "",
        state: State,
        detail: String = "",
        startedAt: TimeInterval? = nil,
        finishedAt: TimeInterval? = nil,
        updatedAt: TimeInterval? = nil
    ) {
        self.delegationID = delegationID
        self.tabID = tabID
        self.tabTitle = tabTitle
        self.summary = summary
        self.state = state
        self.detail = detail
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = container.decodeLenient(String.self, forKey: .state, default: "")
        self.init(
            delegationID: container.decodeLenient(String.self, forKey: .delegationID, default: UUID().uuidString),
            tabID: container.decodeLenient(String.self, forKey: .tabID, default: ""),
            tabTitle: container.decodeLenient(String.self, forKey: .tabTitle, default: ""),
            summary: container.decodeLenient(String.self, forKey: .summary, default: ""),
            state: State(rawValue: raw) ?? .other,
            detail: container.decodeLenient(String.self, forKey: .detail, default: ""),
            startedAt: container.decodeLenient(TimeInterval.self, forKey: .startedAt),
            finishedAt: container.decodeLenient(TimeInterval.self, forKey: .finishedAt),
            updatedAt: container.decodeLenient(TimeInterval.self, forKey: .updatedAt)
        )
    }
}

private extension KeyedDecodingContainer {
    func decodeLenient<T: Decodable>(_ type: T.Type, forKey key: Key, default defaultValue: @autoclosure () -> T) -> T {
        (try? decodeIfPresent(type, forKey: key)) ?? defaultValue()
    }

    func decodeLenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }
}

struct CantripRemoteMessage: Decodable, Equatable, Identifiable {
    let id: String
    let role: String
    let text: String
    let thinking: String
    let author: String?
    let activities: [CantripRemoteActivity]
    let apps: [CantripRemoteMCPAppSummary]?
    let subagents: [CantripRemoteSubagent]?
    /// Reasoning split into titled steps; absent from Mac hosts before this field existed.
    var reasoning: [CantripRemoteReasoningStep]? = nil
    var displayText: String? = nil
    var images: [ChatMessageImage]? = nil
    var isPreview: Bool? = nil
    var isLocalPrivate: Bool? = nil
    /// Context size and token use for a prompt; absent from older Mac hosts.
    var promptUsage: CantripPromptUsage? = nil
    /// Cantrip Home work handed to project tabs; absent from older Mac hosts.
    var delegations: [CantripRemoteDelegation]? = nil
    /// Cantrip Home only: a handoff's result card (role `handoff`).
    var handoffResult: CantripRemoteHandoffResult? = nil

    var presentedText: String { displayText ?? text }
    /// Result cards Cantrip posts into Home's chat; never a model reply.
    var isHandoffResult: Bool { role == "handoff" }
    /// The divider Cantrip adds when a tab starts fresh; never a model reply.
    var isFreshStart: Bool { role == "freshStart" }
}

struct CantripRemoteQueuedPrompt: Decodable, Equatable, Identifiable {
    let id: String
    let text: String
    var displayText: String? = nil
    var images: [ChatMessageImage]? = nil

    var presentedText: String { displayText ?? text }
}

struct CantripRemoteSession: Decodable, Equatable, Identifiable {
    let id: String
    let title: String
    let workdir: String
    let isStreaming: Bool
    let canResume: Bool
    let councilMode: Bool
    let queuedCount: Int
    let status: String?
    var messages: [CantripRemoteMessage]?
    let supportsImageAttachments: Bool?
    let queued: [CantripRemoteQueuedPrompt]?
    var supportsAutoDelivery: Bool? = nil
    var deliveryStatus: String? = nil
    var supportsQueueRemoval: Bool? = nil
    /// The Mac can deliver a queued message now; absent from older hosts.
    var supportsQueueSendNow: Bool? = nil
    var customTitle: String? = nil
    var isLocked: Bool? = nil
    var supportsTabMetadata: Bool? = nil
    var supportsTabReordering: Bool? = nil
    /// The tab can be filed under a section (`sectionID`); nil from Macs without sections.
    var supportsTabSections: Bool? = nil
    /// The section this tab is filed under; nil shows it under Tabs.
    var sectionID: String? = nil
    var supportsPagedHistory: Bool? = nil
    var supportsVideoAttachments: Bool? = nil
    /// Any document as an attachment; absent from Macs before file uploads.
    var supportsFileAttachments: Bool? = nil
    /// Photos, a video and files together in one message; older Macs take images or one video.
    var supportsMixedAttachments: Bool? = nil
    var historyRevision: String? = nil
    var historyStartID: String? = nil
    var hasOlderMessages: Bool? = nil
    var supportsModelSettings: Bool? = nil
    var modelSettingsRevision: String? = nil
    var isLocalPrivate: Bool? = nil
    var isCantripHome: Bool? = nil
    var supportsPrivateLocalSettings: Bool? = nil
    var supportsInputRequests: Bool? = nil
    var pendingInputCount: Int? = nil
    var supportsChatInputReplies: Bool? = nil
    /// Cantrip Home only: the Mac lists scheduled-task and incident runs.
    var supportsBackgroundRuns: Bool? = nil
    /// Cantrip Home only: background runs running or waiting on the Mac.
    var backgroundActiveCount: Int? = nil
    /// Cantrip Home only: requests from background runs waiting on the user.
    var backgroundInputCount: Int? = nil
    var pendingInputs: [CantripInputRequest]? = nil
    /// Seconds since 1970 of the tab's latest run: when it started while working, else when it
    /// finished. Nil from older hosts and for tabs that have not run.
    var lastActivityAt: Double? = nil
    /// One line about the tab's latest reply, for tab lists. Nil from older hosts.
    var preview: String? = nil
    /// The tab can start its next prompt in a new model session, keeping its history. Nil from
    /// older Macs; false for Cantrip Home.
    var supportsStartFresh: Bool? = nil
    /// The Mac lists this tab's backend slash commands and skills
    /// (`GET /api/v1/sessions/{id}/commands`). Nil from older Macs, which never get that call.
    var supportsBackendCommands: Bool? = nil
    /// The latest message, when it is an error repeating the one before it with no reply between.
    var repeatedErrorMessageID: String? = nil

    var transcript: [CantripRemoteMessage] { messages ?? [] }
    var lastActivityDate: Date? { lastActivityAt.map(Date.init(timeIntervalSince1970:)) }
}

struct CantripHomeSchedule: Decodable, Equatable {
    enum Kind: String, Decodable {
        case once
        case interval
        case weekdays
    }

    let kind: Kind
    let summary: String
    let timeZone: String
    let startAt: Date?
    let intervalMinutes: Int?
    let weekdays: [Int]?
    let hour: Int?
    let minute: Int?
}

struct CantripHomeTaskRun: Decodable, Equatable, Identifiable {
    let id: UUID
    let startedAt: Date
    let finishedAt: Date
    let status: String
    let summary: String
    /// The model the run used; older Macs and runs omit it.
    var model: String? = nil
}

/// A scheduled-task or incident run on the Mac: in its own hidden session, or handed to the
/// project tab that owns it.
struct CantripHomeBackgroundRun: Decodable, Equatable, Identifiable {
    let id: UUID
    let kind: String
    let label: String
    var taskID: UUID? = nil
    let startedAt: Date
    var finishedAt: Date? = nil
    let status: String
    let summary: String
    /// The live hidden session, while it runs.
    var sessionID: String? = nil
    /// "hidden" or "tab"; older Macs omit it.
    var route: String? = nil
    var repeats: Int? = nil
    var handoffs: [CantripRemoteDelegation]? = nil
    /// This run's own live status; older Macs send one shared activity instead.
    var activity: String? = nil
    var canStop: Bool? = nil
    /// Approvals and questions the live run waits on, answered through its `sessionID`.
    var inputs: [CantripInputRequest]? = nil
    /// The model a hidden run used; older Macs omit it.
    var model: String? = nil

    var isIncident: Bool { kind == "incident" }
    var isRunning: Bool { status == "running" }
    var isHandedOff: Bool { route == "tab" }
    var tabHandoff: CantripRemoteDelegation? { isHandedOff ? handoffs?.last : nil }
    var needsInput: Bool { isRunning && (!(inputs ?? []).isEmpty || activity == "Needs your input") }
}

struct CantripHomeBackgroundQueuedRun: Decodable, Equatable, Identifiable {
    let id: UUID
    let kind: String
    let label: String
    var reason: String? = nil
    var repeats: Int? = nil
}

struct CantripHomeBackgroundSnapshot: Decodable, Equatable {
    let sessionID: String
    let runs: [CantripHomeBackgroundRun]
    let queued: [CantripHomeBackgroundQueuedRun]
    var activity: String? = nil
    let revision: String
    var maxParallel: Int? = nil
    var runningCount: Int? = nil
    var supportsStop: Bool? = nil
}

struct CantripHomeTaskField: Decodable, Equatable, Identifiable {
    enum Kind: String, Decodable {
        case text
        case longText
        case number
        case boolean
        case date
        case dateTime
        case choice
        case url
    }

    let key: String
    let label: String
    let kind: Kind
    let required: Bool
    let options: [String]?

    var id: String { key }
}

/// One collapsible section of a grouped workspace list.
struct CantripHomeTaskListGroup: Decodable, Equatable {
    let title: String
    let values: [String]
    /// Starts collapsed until the user expands it on this device.
    var collapsed: Bool? = nil
}

struct CantripHomeTaskListPresentation: Decodable, Equatable {
    let titleField: String
    let subtitleFields: [String]
    let badgeField: String?
    let dateField: String?
    /// A choice field that splits the list into sections; older Macs never send it.
    var groupField: String? = nil
    var groups: [CantripHomeTaskListGroup]? = nil
}

struct CantripHomeTaskDetailSection: Decodable, Equatable, Identifiable {
    let title: String?
    let fields: [String]

    var id: String { "\(title ?? ""):\(fields.joined(separator: ","))" }
}

struct CantripHomeTaskRecord: Decodable, Equatable, Identifiable {
    let id: UUID
    let values: [String: String]
    let createdAt: Date
    let updatedAt: Date
}

struct CantripHomeTaskWorkspace: Decodable, Equatable {
    let recordLabel: String
    let recordLabelPlural: String?
    let icon: String
    let fields: [CantripHomeTaskField]
    let list: CantripHomeTaskListPresentation
    let detailSections: [CantripHomeTaskDetailSection]
    let records: [CantripHomeTaskRecord]
}

struct CantripHomeTask: Decodable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var prompt: String
    let schedule: CantripHomeSchedule
    let hasSchedule: Bool?
    let workspace: CantripHomeTaskWorkspace?
    var enabled: Bool
    let createdAt: Date
    let updatedAt: Date
    let nextRunAt: Date?
    let lastRunAt: Date?
    let state: String
    let activeRunID: UUID?
    let runs: [CantripHomeTaskRun]
    /// The task's own Copilot model and effort; nil runs on Home's model.
    var model: String? = nil
    var effort: String? = nil

    var isScheduled: Bool { hasSchedule != false }
    /// "claude-sonnet-5.5 · high", or nil when the task follows Home's model.
    var modelSummary: String? {
        guard model != nil || effort != nil else { return nil }
        return [model ?? "Home's model", effort.map { "\($0) effort" }].compactMap { $0 }
            .joined(separator: " · ")
    }
}

struct CantripHomeArtifact: Decodable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let relativePath: String
    let kind: String
    let mimeType: String
    let size: Int
    let createdAt: Date
}

/// One build on the Mac's private over-the-air install page (Home's Builds tab).
struct CantripOTABuild: Decodable, Equatable, Identifiable, Sendable {
    /// `<bundle id>/<build folder>` on the Mac; also addresses the icon.
    let id: String
    let bundleID: String
    let title: String
    let version: String
    let build: String
    let note: String?
    let hasIcon: Bool
    let size: Int64?
    let sizeLabel: String?
    let profileName: String?
    let profileKind: String?
    let profileExpires: String?
    let publishedAt: Date
    let publishedLabel: String?
    let sourceCommit: String?
    /// The https manifest the install link points at (tailnet-only).
    let manifestURL: String
    /// `itms-services://?action=download-manifest&url=…`
    let installURL: String
}

/// One install-page entry: builds sharing a page key, newest first.
struct CantripOTAApp: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let bundleID: String
    let builds: [CantripOTABuild]
}

struct CantripOTABuildsSnapshot: Decodable, Equatable, Sendable {
    let apps: [CantripOTAApp]
    let pageURL: String?
    /// False when the Mac has no install page folder at all.
    let available: Bool
    let skipped: Int
    let revision: String
}

private struct CantripOTAIconResponse: Decodable {
    let data: Data
}

private struct CantripHomeTasksResponse: Decodable {
    /// Absent when the host answers `unchanged` for the revision the client already has.
    let tasks: [CantripHomeTask]?
    let revision: String
    let error: String?
    let supportsReordering: Bool?
    let unchanged: Bool?
}

typealias CantripHomeTasksSnapshot = (
    tasks: [CantripHomeTask], revision: String, error: String?, supportsReordering: Bool
)

private struct CantripHomeArtifactsResponse: Decodable {
    let artifacts: [CantripHomeArtifact]?
    let revision: String
    let unchanged: Bool?
}

private struct CantripHomeArtifactDataResponse: Decodable {
    struct Summary: Decodable {
        let id: UUID
        let title: String
        let mimeType: String
    }
    let artifact: Summary
    let data: Data
}

struct CantripSessionsResponse: Decodable {
    let sessions: [CantripRemoteSession]
    /// Cantrip Home's summary, listed alongside the tabs by hosts with Home enabled.
    var home: CantripRemoteSession?
    /// Named groups for the tab lists, in order; nil from Macs without sections.
    var sections: [CantripTabSection]?
    var supportsTabSections: Bool?
}

struct CantripTabSectionsResponse: Decodable {
    let sections: [CantripTabSection]
    var section: CantripTabSection?
}

private struct CantripSessionResponse: Decodable {
    let session: CantripRemoteSession
}

private struct CantripSessionUpdate: Decodable {
    let session: CantripRemoteSession?
    let unchanged: Bool?
}

private struct CantripErrorResponse: Decodable {
    let error: String
}

private struct CantripMCPAppServerResponse: Decodable {
    let result: [String: MCPAppJSONValue]
}

private struct CantripMCPAppMessageResponse: Decodable {
    let accepted: Bool
    let text: String
}

private struct CantripMCPAppAcceptedResponse: Decodable {
    let accepted: Bool
}

private struct CantripSubagentCancelResponse: Decodable {
    let cancelled: Bool
}

enum CantripRemoteError: LocalizedError {
    case invalidURL(String)
    case missingToken
    case keychain(String)
    case authentication
    case transport(String)
    case notSent(String)
    case http(Int, String)
    case decoding
    case invalidResponse
    case imagesUnsupported
    case videosUnsupported
    case autoDeliveryUnsupported
    case queueRemovalUnsupported
    case queueSendNowUnsupported
    case startFreshUnsupported
    case tabMetadataUnsupported
    case tabReorderingUnsupported
    case tabSectionsUnsupported
    case githubBuildsUnsupported
    case memoryUnsupported
    case maintenanceUnsupported
    case copilotUsageUnsupported
    case modelSettingsUnsupported
    case privateLocalUnsupported

    static func isRouteFailure(_ error: Error) -> Bool {
        switch error {
        case CantripRemoteError.transport, CantripRemoteError.invalidResponse:
            return true
        case CantripRemoteError.http(let status, _):
            return [502, 503, 504].contains(status)
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL(let message):
            return message
        case .missingToken:
            return "Enter the Cantrip pairing token."
        case .keychain(let message):
            return message
        case .authentication:
            return "Cantrip rejected the pairing token. Open Remote settings and enter the current token."
        case .transport(let message):
            return "Could not reach Cantrip. \(message)"
        case .notSent(let message):
            return "\(message) The request was not sent. Check the connection and try again."
        case .http(let status, let message):
            return "Cantrip returned HTTP \(status): \(message)"
        case .decoding:
            return "Cantrip returned data this app could not read. Update both apps and try again."
        case .invalidResponse:
            return "Cantrip returned an invalid HTTP response."
        case .imagesUnsupported:
            return "Image attachments require an updated Cantrip host using Claude, Copilot, or Codex. Your images have not been sent."
        case .videosUnsupported:
            return "Video analysis requires an updated Cantrip host using Claude, Copilot, or Codex. Your video has not been sent."
        case .autoDeliveryUnsupported:
            return "Update and reopen Cantrip on your Mac for Auto sending, or choose Queue, Redirect, or Inject. Your message has not been sent."
        case .queueRemovalUnsupported:
            return "Update and reopen Cantrip on your Mac to remove queued messages from Cantrip Agent."
        case .queueSendNowUnsupported:
            return "Update and reopen Cantrip on your Mac to send queued messages now from Cantrip Agent. The message is still queued."
        case .startFreshUnsupported:
            return "Update and reopen Cantrip on your Mac to start fresh. Nothing in the tab has changed."
        case .tabMetadataUnsupported:
            return "Update and reopen Cantrip on your Mac to rename or lock its tabs."
        case .tabReorderingUnsupported:
            return "Update and reopen Cantrip on your Mac to reorder its tabs."
        case .tabSectionsUnsupported:
            return "Update and reopen Cantrip on your Mac to group its tabs into sections."
        case .githubBuildsUnsupported:
            return "Update and reopen Cantrip on your Mac to view GitHub builds."
        case .memoryUnsupported:
            return "Update and reopen Cantrip on your Mac to view its saved memory."
        case .maintenanceUnsupported:
            return "Update and reopen Cantrip on the Mac once to enable remote updates and rebuilds."
        case .copilotUsageUnsupported:
            return "Update and reopen Cantrip on your Mac to view Copilot account usage."
        case .modelSettingsUnsupported:
            return "Update and reopen Cantrip on your Mac to change a tab's model, effort and context window."
        case .privateLocalUnsupported:
            return "Update and reopen Cantrip on the Mac to use the saved Private Local tab. No cloud tab will be used instead."
        }
    }
}

private enum CantripRemoteCredentials {
    private static let account = "cantrip.remote.pairing-token"
    private static let service = "AgentGateway"

    static func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CantripRemoteError.keychain(
                "The pairing token could not be updated in Keychain (error \(updateStatus))."
            )
        }

        var item = query
        item.merge(update) { _, new in new }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CantripRemoteError.keychain(
                "The pairing token could not be saved in Keychain (error \(addStatus))."
            )
        }
    }

    static func removeToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CantripRemoteError.keychain(
                "The pairing token could not be removed from Keychain (error \(status))."
            )
        }
    }
}

private actor CantripRequestGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: () async throws -> T) async throws -> T {
        await lock()
        defer { unlock() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum CantripTransport: Hashable {
    case lan(NWEndpoint)
    case remote(URL)
}

/// A Mac's encrypted (TLS-PSK) LAN listener saved as host:port, e.g. "192.168.0.152:8766" for
/// a Mac without Tailscale that the phone reaches through a Tailscale subnet router. It is
/// tried like a Bonjour-discovered endpoint, so it works away from home where Bonjour can't.
enum CantripDirectAddress {
    static let example = "192.168.0.152:8766"

    /// The address in canonical form, nil when empty.
    static func normalized(_ raw: String?) throws -> String? {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let (host, port) = split(value) else {
            throw ServerConfigurationError(
                message: "Enter the direct address as host:port, for example \(example). Set the port in Cantrip's Remote control settings on that Mac."
            )
        }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    static func endpoint(_ value: String?) -> NWEndpoint? {
        guard let value, let (host, port) = split(value),
              let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
    }

    private static func split(_ value: String) -> (String, UInt16)? {
        let host: Substring
        let portText: Substring
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]"),
                  value[value.index(after: close)...].hasPrefix(":") else { return nil }
            host = value[value.index(after: value.startIndex)..<close]
            portText = value[value.index(close, offsetBy: 2)...]
        } else {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            host = parts[0]
            portText = parts[1]
        }
        guard !host.isEmpty, host.count <= 253,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-:%".contains($0)) }),
              portText.allSatisfy(\.isNumber), let port = UInt16(portText), port > 0 else { return nil }
        return (host.lowercased(), port)
    }
}

enum CantripLANProtocol {
    static let serviceType = "_cantrip-remote._tcp"

    static func parameters(token: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let derivedKey = Data(SHA256.hash(data: Data(token.utf8)))
        let key = derivedKey.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("cantrip-remote-v1".utf8).withUnsafeBytes {
            DispatchData(bytes: $0)
        }
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions,
            key as dispatch_data_t,
            identity as dispatch_data_t
        )
        sec_protocol_options_set_min_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv12
        )
        sec_protocol_options_set_max_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv12
        )
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(
                rawValue: UInt16(TLS_DHE_PSK_WITH_AES_128_GCM_SHA256)
            )!
        )
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    static func tokenFingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private final class CantripLANBrowser {
    var onEndpointsChanged: (([NWEndpoint]) -> Void)?

    private let queue = DispatchQueue(label: "com.itzhoang.hermbot.cantrip-discovery")
    private var browser: NWBrowser?

    func start(token: String) {
        stop()
        let fingerprint = CantripLANProtocol.tokenFingerprint(token)
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(
                type: CantripLANProtocol.serviceType,
                domain: nil
            ),
            using: NWParameters()
        )
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, self.browser === browser else { return }
            let endpoints = results.compactMap { result -> NWEndpoint? in
                guard case .bonjour(let record) = result.metadata,
                      record["v"] == "1",
                      record["id"] == fingerprint
                else { return nil }
                return result.endpoint
            }
            .sorted { $0.debugDescription < $1.debugDescription }
            DispatchQueue.main.async { [weak self, weak browser] in
                guard let self, let browser, self.browser === browser else { return }
                self.onEndpointsChanged?(endpoints)
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.browser === browser else { return }
            if case .failed = state {
                DispatchQueue.main.async { [weak self, weak browser] in
                    guard let self, let browser, self.browser === browser else { return }
                    self.onEndpointsChanged?([])
                }
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
    }
}

private struct CantripLANResponse {
    let statusCode: Int
    let body: Data
}

private final class CantripLANRequest: @unchecked Sendable {
    private let endpoint: NWEndpoint
    private let token: String
    private let requestData: Data
    private let timeout: TimeInterval
    private let isDirect: Bool
    private let queue = DispatchQueue(label: "com.itzhoang.hermbot.cantrip-request")
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<CantripLANResponse, Error>?
    private var responseBuffer = Data()
    private var isCancelled = false
    private var isComplete = false
    private var isReady = false

    init(endpoint: NWEndpoint, token: String, method: String, path: String, body: Data?) {
        self.endpoint = endpoint
        self.token = token
        let payload = body ?? Data()
        // Bonjour peers are `.service` endpoints on this Wi-Fi. A saved direct address (`.hostPort`)
        // may cross a Tailscale subnet route, so it gets the Tailscale HTTPS route's 3s deadlines.
        if case .hostPort = endpoint { isDirect = true } else { isDirect = false }
        timeout = method == "GET"
            ? (CantripRemoteAPI.isContentRead(method: method, path: path) ? 20 : isDirect ? 3 : 2)
            : (payload.count > 256 * 1024 || CantripRemoteAPI.isUploadRoute(path) ? 60 : 12)
        let header = """
        \(method) \(path) HTTP/1.1\r
        Host: cantrip.local\r
        Authorization: Bearer \(token)\r
        Accept: application/json\r
        Accept-Encoding: gzip\r
        Content-Type: \(method == "PUT" && CantripRemoteAPI.isUploadRoute(path) ? "application/octet-stream" : "application/json")\r
        Content-Length: \(payload.count)\r
        Connection: close\r
        \r

        """
        var requestData = Data(header.utf8)
        requestData.append(payload)
        self.requestData = requestData
    }

    func run() async throws -> CantripLANResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.continuation = continuation
                    self.start()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        queue.async {
            self.isCancelled = true
            self.finish(.failure(CancellationError()))
        }
    }

    private func start() {
        let connection = NWConnection(
            to: endpoint,
            using: CantripLANProtocol.parameters(token: token)
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isReady = true
                self.sendRequest()
            case .failed(let error):
                self.finish(.failure(CantripRemoteError.transport(
                    error.localizedDescription
                )))
            case .cancelled where !self.isComplete:
                self.finish(.failure(
                    self.isCancelled
                        ? CancellationError()
                        : CantripRemoteError.transport("The local connection closed.")
                ))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + (isDirect ? 3 : 2)) { [weak self] in
            guard let self, !self.isReady, !self.isComplete else { return }
            self.finish(.failure(CantripRemoteError.transport(
                "The local connection timed out."
            )))
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.isComplete else { return }
            self.finish(.failure(CantripRemoteError.transport(
                "The local connection timed out."
            )))
        }
    }

    private func sendRequest() {
        guard let connection else { return }
        connection.send(content: requestData, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failure(CantripRemoteError.transport(
                    error.localizedDescription
                )))
            } else {
                self.receiveResponse()
            }
        })
    }

    private func receiveResponse() {
        connection?.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, complete, error in
            guard let self, !self.isComplete else { return }
            if let data {
                self.responseBuffer.append(data)
            }
            do {
                if let response = try self.parseResponse() {
                    self.finish(.success(response))
                } else if let error {
                    self.finish(.failure(CantripRemoteError.transport(
                        error.localizedDescription
                    )))
                } else if complete {
                    self.finish(.failure(CantripRemoteError.invalidResponse))
                } else {
                    self.receiveResponse()
                }
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    private func parseResponse() throws -> CantripLANResponse? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = responseBuffer.range(of: separator) else {
            guard responseBuffer.count <= 64 * 1024 else {
                throw CantripRemoteError.invalidResponse
            }
            return nil
        }
        guard let header = String(
            data: responseBuffer[..<headerRange.lowerBound],
            encoding: .utf8
        ) else {
            throw CantripRemoteError.invalidResponse
        }
        let lines = header.components(separatedBy: "\r\n")
        let statusParts = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw CantripRemoteError.invalidResponse
        }
        return try Self.response(statusCode: statusCode, headerLines: lines.dropFirst(),
                                 buffer: responseBuffer, bodyStart: headerRange.upperBound)
    }

    /// The body once all of it has arrived (nil before then), decoded when the host gzipped it.
    private static func response(statusCode: Int, headerLines: ArraySlice<String>, buffer: Data,
                         bodyStart: Int) throws -> CantripLANResponse? {
        var fields: [String: String] = [:]
        for line in headerLines {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
                = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let limit = 32 * 1024 * 1024
        guard let contentLength = fields["content-length"].flatMap(Int.init),
              contentLength >= 0, contentLength <= limit else {
            throw CantripRemoteError.invalidResponse
        }
        guard buffer.count - bodyStart >= contentLength else { return nil }
        guard let body = CantripGzip.body(buffer.subdata(in: bodyStart..<(bodyStart + contentLength)),
                                          contentEncoding: fields["content-encoding"], limit: limit) else {
            throw CantripRemoteError.invalidResponse
        }
        return CantripLANResponse(statusCode: statusCode, body: body)
    }

    private func finish(_ result: Result<CantripLANResponse, Error>) {
        guard !isComplete else { return }
        isComplete = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}

private enum CantripHistoryWindow {
    static let recentExchanges = 3
}

struct CantripRemoteAPI {
    let transport: CantripTransport
    let token: String
    var urlSession: URLSession?

    /// Chunked video and file uploads: raw bytes, a longer deadline, and the upload session.
    static func isUploadRoute(_ path: String) -> Bool {
        let parts = (URLComponents(string: path)?.percentEncodedPath ?? "").split(separator: "/")
        return parts.count >= 5 && parts.prefix(3) == ["api", "v1", "sessions"]
            && (parts[4] == "videos" || parts[4] == "files")
    }

    static func isContentRead(method: String, path: String) -> Bool {
        let parts = (URLComponents(string: path)?.percentEncodedPath ?? "").split(separator: "/")
        return method == "GET" && (
            parts == ["api", "v1", "maintenance"]
                || parts.starts(with: ["api", "v1", "home"])
                || parts == ["api", "v1", "memory"] || parts == ["api", "v1", "memory", "document"]
                || (parts.starts(with: ["api", "v1", "sessions"])
                    && (parts.count == 4 || (parts.count == 6 && (parts[4] == "messages" || parts[4] == "apps"))
                        // A folder's first command discovery can take a few seconds on the Mac.
                        || (parts.count == 5 && parts[4] == "commands")))
        )
    }

    static func pathComponent(_ raw: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard !raw.isEmpty,
              let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty else { throw CantripRemoteError.invalidResponse }
        return encoded
    }

    private static let readSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private static let imageSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func sessions() async throws -> [CantripRemoteSession] {
        try await sessionListing().sessions
    }

    func sessionListing() async throws -> CantripSessionsResponse {
        try await request(path: "/api/v1/sessions")
    }

    func completionNotifications(method: String = "GET", body: Data? = nil) async throws -> CantripPushStatus {
        do {
            return try await request(path: "/api/v1/notifications", method: method, body: body)
        } catch CantripRemoteError.http(404, _) {
            throw ServerConfigurationError(message: "Update and reopen Cantrip on the Mac to enable completion alerts.")
        }
    }

    func liveStatus() async throws -> CantripLiveStatusSnapshot {
        try await request(path: "/api/v1/live-status")
    }

    func liveStatusSubscription(body: Data) async throws -> CantripLiveStatusSubscriptionStatus {
        try await request(path: "/api/v1/live-status/subscription", method: "POST", body: body)
    }

    func githubBuilds() async throws -> CantripBuildSnapshot {
        do {
            return try await request(path: "/api/v1/github/builds")
        } catch CantripRemoteError.http(404, _) {
            throw CantripRemoteError.githubBuildsUnsupported
        }
    }

    func maintenance(_ action: CantripMaintenanceRequest? = nil) async throws -> CantripMaintenanceSnapshot {
        do {
            return try await request(path: "/api/v1/maintenance",
                method: action == nil ? "GET" : "POST",
                body: try action.map { try JSONEncoder().encode($0) })
        } catch CantripRemoteError.http(404, _) {
            throw CantripRemoteError.maintenanceUnsupported
        }
    }

    func copilotUsage() async throws -> CopilotUsageSnapshot {
        do {
            return try await request(path: "/api/v1/copilot/usage")
        } catch CantripRemoteError.http(404, _) {
            throw CantripRemoteError.copilotUsageUnsupported
        }
    }

    func memoryCatalog(query: String, after: String?) async throws -> CantripMemoryCatalog {
        var target = URLComponents()
        target.path = "/api/v1/memory"
        target.queryItems = [URLQueryItem(name: "q", value: query)]
        if let after { target.queryItems?.append(URLQueryItem(name: "after", value: after)) }
        guard let path = target.string else { throw CantripRemoteError.invalidResponse }
        do {
            return try await request(path: path)
        } catch CantripRemoteError.http(404, _) {
            throw CantripRemoteError.memoryUnsupported
        }
    }

    func memoryDocument(id: String, offset: Int, revision: String?) async throws -> CantripMemoryPage {
        var target = URLComponents()
        target.path = "/api/v1/memory/document"
        target.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "offset", value: String(offset))]
        if let revision { target.queryItems?.append(URLQueryItem(name: "revision", value: revision)) }
        guard let path = target.string else { throw CantripRemoteError.invalidResponse }
        let page: CantripMemoryPage = try await request(path: path)
        guard page.document.id == id, page.offset == offset,
              page.nextOffset.map({ $0 > offset && $0 <= page.document.bytes }) ?? true,
              revision == nil || revision == page.revision else { throw CantripRemoteError.invalidResponse }
        return page
    }

    /// Names and terms the Mac knows for dictation; nil on hosts without the route.
    func voiceVocabulary() async throws -> CantripVoiceVocabulary? {
        do {
            return try await request(path: "/api/v1/voice/vocabulary")
        } catch CantripRemoteError.http(404, _) {
            return nil
        }
    }

    func imageData(sessionID: String, imageID: String, thumbnail: Bool) async throws -> Data {
        guard UUID(uuidString: sessionID) != nil, ChatMessageImage.validRemoteID(imageID) else {
            throw CantripRemoteError.invalidResponse
        }
        struct ImageResponse: Decodable { let data: Data }
        let isPreview = ChatMessageImage.validPreviewID(imageID)
        let response: ImageResponse = try await request(
            path: "/api/v1/sessions/\(sessionID)/" + (isPreview ? imageID : "attachments/\(imageID)")
                + (thumbnail ? "/thumbnail" : "")
        )
        guard !response.data.isEmpty,
              response.data.count <= (isPreview ? GeneratedImagePreview.maximumImageBytes
                                               : ImageAttachmentProcessor.maximumImageBytes) else {
            throw ImageAttachmentError.invalidImage
        }
        return response.data
    }

    func session(id: String) async throws -> CantripRemoteSession {
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions/\(id)", includeRecentExchanges: true
        )
        return response.session
    }

    func homeSession() async throws -> CantripRemoteSession {
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/home", includeRecentExchanges: true
        )
        guard response.session.isCantripHome == true else {
            throw CantripRemoteError.invalidResponse
        }
        return response.session
    }

    func homeTasks() async throws -> CantripHomeTasksSnapshot {
        guard let snapshot = try await homeTasks(ifChangedFrom: nil) else { throw CantripRemoteError.invalidResponse }
        return snapshot
    }

    /// nil when the Mac's tasks still match `revision`; older hosts always send the full list.
    func homeTasks(ifChangedFrom revision: String?) async throws -> CantripHomeTasksSnapshot? {
        let response: CantripHomeTasksResponse = try await request(
            path: Self.path("/api/v1/home/tasks", revision: revision)
        )
        if response.unchanged == true {
            guard let revision, response.revision == revision else { throw CantripRemoteError.invalidResponse }
            return nil
        }
        guard let tasks = response.tasks else { throw CantripRemoteError.invalidResponse }
        return (tasks, response.revision, response.error, response.supportsReordering == true)
    }

    static func path(_ path: String, revision: String?) -> String {
        guard let revision else { return path }
        var components = URLComponents()
        components.path = path
        components.queryItems = [URLQueryItem(name: "revision", value: revision)]
        return components.string ?? path
    }

    func moveHomeTask(id: UUID, targetID: UUID, after: Bool) async throws -> CantripHomeTasksSnapshot {
        let response: CantripHomeTasksResponse = try await request(
            path: "/api/v1/home/tasks/\(id.uuidString)/move", method: "POST",
            body: JSONSerialization.data(withJSONObject: [
                "targetID": targetID.uuidString, "placement": after ? "after" : "before",
            ])
        )
        guard let tasks = response.tasks else { throw CantripRemoteError.invalidResponse }
        return (tasks, response.revision, response.error, response.supportsReordering == true)
    }

    func homeBackground() async throws -> CantripHomeBackgroundSnapshot {
        try await request(path: "/api/v1/home/background")
    }

    func stopHomeBackgroundRun(id: UUID) async throws -> CantripHomeBackgroundSnapshot {
        try await request(path: "/api/v1/home/background/\(id.uuidString)/stop", method: "POST")
    }

    func homeArtifacts() async throws -> (artifacts: [CantripHomeArtifact], revision: String) {
        guard let snapshot = try await homeArtifacts(ifChangedFrom: nil) else { throw CantripRemoteError.invalidResponse }
        return snapshot
    }

    /// nil when the Mac's artifacts still match `revision`.
    func homeArtifacts(ifChangedFrom revision: String?) async throws
        -> (artifacts: [CantripHomeArtifact], revision: String)? {
        let response: CantripHomeArtifactsResponse = try await request(
            path: Self.path("/api/v1/home/artifacts", revision: revision)
        )
        if response.unchanged == true {
            guard let revision, response.revision == revision else { throw CantripRemoteError.invalidResponse }
            return nil
        }
        guard let artifacts = response.artifacts else { throw CantripRemoteError.invalidResponse }
        return (artifacts, response.revision)
    }

    func homeBuilds() async throws -> CantripOTABuildsSnapshot {
        try await request(path: "/api/v1/home/builds")
    }

    /// nil when the build has no icon on the Mac.
    func homeBuildIcon(id: String) async throws -> Data? {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CantripRemoteError.invalidResponse
        }
        do {
            let response: CantripOTAIconResponse = try await request(
                path: "/api/v1/home/builds/\(try Self.pathComponent(parts[0]))/\(try Self.pathComponent(parts[1]))/icon"
            )
            guard !response.data.isEmpty, response.data.count <= 2 * 1024 * 1024 else {
                throw CantripRemoteError.invalidResponse
            }
            return response.data
        } catch CantripRemoteError.http(404, _) {
            return nil
        }
    }

    func updateHomeTask(id: UUID, title: String? = nil, prompt: String? = nil,
                        enabled: Bool? = nil) async throws -> CantripHomeTask {
        var object: [String: Any] = [:]
        if let title { object["title"] = title }
        if let prompt { object["prompt"] = prompt }
        if let enabled { object["enabled"] = enabled }
        guard !object.isEmpty else { throw CantripRemoteError.invalidResponse }
        return try await request(
            path: "/api/v1/home/tasks/\(id.uuidString)", method: "PATCH",
            body: JSONSerialization.data(withJSONObject: object)
        )
    }

    func deleteHomeTask(id: UUID) async throws {
        struct Response: Decodable { let deleted: Bool }
        let response: Response = try await request(
            path: "/api/v1/home/tasks/\(id.uuidString)", method: "DELETE"
        )
        guard response.deleted else { throw CantripRemoteError.invalidResponse }
    }

    func createHomeTaskRecord(
        taskID: UUID, values: [String: String]
    ) async throws -> CantripHomeTask {
        try await request(
            path: "/api/v1/home/tasks/\(taskID.uuidString)/records",
            method: "POST",
            body: JSONSerialization.data(withJSONObject: ["values": values])
        )
    }

    func updateHomeTaskRecord(
        taskID: UUID, recordID: UUID, values: [String: String]
    ) async throws -> CantripHomeTask {
        try await request(
            path: "/api/v1/home/tasks/\(taskID.uuidString)/records/\(recordID.uuidString)",
            method: "PATCH",
            body: JSONSerialization.data(withJSONObject: ["values": values])
        )
    }

    func deleteHomeTaskRecord(
        taskID: UUID, recordID: UUID
    ) async throws -> CantripHomeTask {
        try await request(
            path: "/api/v1/home/tasks/\(taskID.uuidString)/records/\(recordID.uuidString)",
            method: "DELETE"
        )
    }

    func homeArtifactData(id: UUID) async throws -> Data {
        let response: CantripHomeArtifactDataResponse = try await request(
            path: "/api/v1/home/artifacts/\(id.uuidString)"
        )
        guard response.artifact.id == id, !response.data.isEmpty,
              response.data.count <= 20 * 1024 * 1024 else {
            throw CantripRemoteError.invalidResponse
        }
        return response.data
    }

    /// nil when the Mac has no thumbnail for it: documents, audio, unreadable media, or a
    /// Mac that predates thumbnails.
    func homeArtifactThumbnail(id: UUID) async throws -> CantripHomeArtifactThumbnailPayload? {
        do {
            let response: CantripHomeArtifactThumbnailPayload = try await request(
                path: "/api/v1/home/artifacts/\(id.uuidString)/thumbnail"
            )
            guard !response.data.isEmpty, response.data.count <= CantripArtifactThumbnailStore.maximumBytes,
                  response.width > 0, response.height > 0 else { throw CantripRemoteError.invalidResponse }
            return response
        } catch CantripRemoteError.http(404, _) {
            return nil
        }
    }

    func deleteHomeArtifact(id: UUID) async throws {
        struct Response: Decodable { let deleted: Bool }
        let response: Response = try await request(
            path: "/api/v1/home/artifacts/\(id.uuidString)", method: "DELETE"
        )
        guard response.deleted else { throw CantripRemoteError.invalidResponse }
    }

    func createSession() async throws -> CantripRemoteSession {
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions",
            method: "POST", includeRecentExchanges: true
        )
        return response.session
    }

    func sessionUpdate(id: String, revision: String?) async throws -> CantripRemoteSession? {
        var path = "/api/v1/sessions/\(id)"
        if let revision {
            var components = URLComponents()
            components.path = path
            components.queryItems = [URLQueryItem(name: "revision", value: revision)]
            guard let target = components.string else { throw CantripRemoteError.invalidResponse }
            path = target
        }
        let response: CantripSessionUpdate = try await request(path: path, includeRecentExchanges: true)
        if let session = response.session { return session }
        guard response.unchanged == true, revision != nil else {
            throw CantripRemoteError.invalidResponse
        }
        return nil
    }

    func olderMessages(id: String, before: String) async throws -> CantripRemoteSession {
        guard UUID(uuidString: before) != nil else { throw CantripRemoteError.invalidResponse }
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions/\(id)?before=\(before)"
        )
        return response.session
    }

    func fullMessage(sessionID: String, messageID: String) async throws -> CantripRemoteMessage {
        guard UUID(uuidString: sessionID) != nil, UUID(uuidString: messageID) != nil else {
            throw CantripRemoteError.invalidResponse
        }
        struct Response: Decodable { let message: CantripRemoteMessage }
        let response: Response = try await request(path: "/api/v1/sessions/\(sessionID)/messages/\(messageID)")
        return response.message
    }

    private func mcpAppPath(sessionID: String, appID: String) throws -> String {
        "/api/v1/sessions/\(try Self.pathComponent(sessionID))/apps/\(try Self.pathComponent(appID))"
    }

    private func subagentPath(sessionID: String, agentID: String) throws -> String {
        "/api/v1/sessions/\(try Self.pathComponent(sessionID))/subagents/\(try Self.pathComponent(agentID))"
    }

    func mcpAppPayload(sessionID: String, appID: String) async throws -> MCPAppPayload {
        try await request(path: try mcpAppPath(sessionID: sessionID, appID: appID))
    }

    func mcpAppServerRequest(sessionID: String, appID: String, method: String,
                             params: [String: Any]) async throws -> [String: Any] {
        guard ["tools/call", "tools/list", "resources/read"].contains(method),
              JSONSerialization.isValidJSONObject(params) else {
            throw MCPAppRequestError.invalidRequest
        }
        let body = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        do {
            let response: CantripMCPAppServerResponse = try await request(
                path: try mcpAppPath(sessionID: sessionID, appID: appID) + "/request",
                method: "POST",
                body: body
            )
            return response.result.mapValues { $0.any }
        } catch CantripRemoteError.http(_, let message) {
            throw MCPAppRequestError.server(message)
        }
    }

    func sendMCPAppMessage(sessionID: String, appID: String, text: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["text": text])
        let response: CantripMCPAppMessageResponse = try await request(
            path: try mcpAppPath(sessionID: sessionID, appID: appID) + "/message",
            method: "POST",
            body: body
        )
        guard response.accepted else { throw CantripRemoteError.invalidResponse }
        return response.text
    }

    func updateMCPAppContext(sessionID: String, appID: String, text: String?) async throws {
        let contextText: Any = text ?? NSNull()
        let body = try JSONSerialization.data(withJSONObject: ["text": contextText])
        let response: CantripMCPAppAcceptedResponse = try await request(
            path: try mcpAppPath(sessionID: sessionID, appID: appID) + "/context",
            method: "POST",
            body: body
        )
        guard response.accepted else { throw CantripRemoteError.invalidResponse }
    }

    func cancelSubagent(sessionID: String, agentID: String) async throws -> Bool {
        let response: CantripSubagentCancelResponse = try await request(
            path: try subagentPath(sessionID: sessionID, agentID: agentID) + "/cancel",
            method: "POST"
        )
        return response.cancelled
    }

    func send(
        _ text: String,
        mode: CantripDeliveryMode,
        sessionID: String,
        images: [ChatImageAttachment] = []
    ) async throws
        -> CantripRemoteSession {
        let body = try await prepareMessage(text, mode: mode, sessionID: sessionID, images: images)
        return try await sendMessage(body, sessionID: sessionID)
    }

    fileprivate func prepareMessage(
        _ text: String, mode: CantripDeliveryMode, sessionID: String,
        images: [ChatImageAttachment], videoID: String? = nil, fileIDs: [String] = [],
        inputRequestID: UUID? = nil
    ) async throws -> Data {
        guard images.count <= ImageAttachmentProcessor.maximumCount else {
            throw ImageAttachmentError.tooMany
        }
        // Confirm reachability and capabilities on the route that will receive the write.
        let host = try await session(id: sessionID)
        if let inputRequestID {
            guard mode == .auto, host.supportsChatInputReplies == true else {
                throw ServerConfigurationError(message: "Update and reopen Cantrip on the Mac to send chat replies with attachments.")
            }
            guard host.pendingInputs?.contains(where: {
                $0.id == inputRequestID && $0.kind == "question" && $0.expiresAt > Date().timeIntervalSince1970
            }) == true else {
                throw CantripRemoteError.http(409, "This question was already answered, cancelled or expired. Your reply was not queued.")
            }
        }
        guard images.isEmpty || host.supportsImageAttachments == true else {
            throw CantripRemoteError.imagesUnsupported
        }
        guard videoID == nil || host.supportsVideoAttachments == true else {
            throw CantripRemoteError.videosUnsupported
        }
        guard fileIDs.isEmpty || host.supportsFileAttachments == true else {
            throw FileAttachmentError.unsupportedHost
        }
        guard fileIDs.count <= FileAttachmentProcessor.maximumCount else { throw FileAttachmentError.tooMany }
        guard videoID == nil || images.isEmpty || host.supportsMixedAttachments == true else {
            throw VideoAttachmentError.mixedAttachments
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (videoID == nil && fileIDs.isEmpty) || (!trimmed.hasPrefix("/") && !trimmed.hasPrefix("!")) else {
            throw VideoAttachmentError.command
        }
        guard mode != .auto || host.supportsAutoDelivery == true else {
            throw CantripRemoteError.autoDeliveryUnsupported
        }
        return try JSONEncoder().encode(CantripMessageBody(text: text, mode: mode, images: images,
                                                         videoID: videoID, fileIDs: fileIDs,
                                                         inputRequestID: inputRequestID))
    }

    func videoStatus(sessionID: String, uploadID: UUID) async throws -> CantripVideoUploadStatus? {
        struct Response: Decodable { let upload: CantripVideoUploadStatus }
        do {
            let response: Response = try await request(path: "/api/v1/sessions/\(sessionID)/videos/\(uploadID)")
            return response.upload
        } catch CantripRemoteError.http(404, _) { return nil }
    }

    func uploadVideoChunk(_ data: Data, video: ChatVideoAttachment, sessionID: String,
                          offset: Int) async throws -> CantripVideoUploadStatus {
        var target = URLComponents()
        target.path = "/api/v1/sessions/\(sessionID)/videos/\(video.id)"
        target.queryItems = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "totalBytes", value: String(video.bytes)),
            URLQueryItem(name: "format", value: video.format),
            URLQueryItem(name: "name", value: video.name),
            URLQueryItem(name: "sha256", value: video.sha256),
        ]
        guard let path = target.string else { throw CantripRemoteError.invalidResponse }
        struct Response: Decodable { let upload: CantripVideoUploadStatus }
        let response: Response = try await request(path: path, method: "PUT", body: data)
        return response.upload
    }

    func fileStatus(sessionID: String, uploadID: UUID) async throws -> CantripVideoUploadStatus? {
        struct Response: Decodable { let upload: CantripVideoUploadStatus }
        do {
            let response: Response = try await request(path: "/api/v1/sessions/\(sessionID)/files/\(uploadID)")
            return response.upload
        } catch CantripRemoteError.http(404, _) { return nil }
    }

    func uploadFileChunk(_ data: Data, file: ChatFileAttachment, sessionID: String,
                         offset: Int) async throws -> CantripVideoUploadStatus {
        var target = URLComponents()
        target.path = "/api/v1/sessions/\(sessionID)/files/\(file.id)"
        // Any file name round-trips: everything but ASCII unreserved characters is escaped.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        target.percentEncodedQueryItems = [
            ("offset", String(offset)), ("totalBytes", String(file.bytes)),
            ("name", file.name), ("sha256", file.sha256),
        ].map { URLQueryItem(name: $0.0, value: $0.1.addingPercentEncoding(withAllowedCharacters: unreserved)) }
        guard let path = target.string else { throw CantripRemoteError.invalidResponse }
        struct Response: Decodable { let upload: CantripVideoUploadStatus }
        let response: Response = try await request(path: path, method: "PUT", body: data)
        return response.upload
    }

    func prepareVideo(sessionID: String, uploadID: UUID) async throws {
        struct Response: Decodable { let ready: Bool }
        let response: Response = try await request(path: "/api/v1/sessions/\(sessionID)/videos/\(uploadID)/prepare",
                                                   method: "POST")
        guard response.ready else { throw CantripRemoteError.invalidResponse }
    }

    fileprivate func sendMessage(_ body: Data, sessionID: String) async throws -> CantripRemoteSession {
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions/\(sessionID)/messages",
            method: "POST",
            body: body, includeRecentExchanges: true
        )
        return response.session
    }

    func action(_ action: String, sessionID: String) async throws -> CantripRemoteSession {
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions/\(sessionID)/\(action)",
            method: "POST", includeRecentExchanges: true
        )
        return response.session
    }

    func closeSession(id: String) async throws -> CantripRemoteSession {
        try await action("close", sessionID: id)
    }

    func modelSettings(id: String, refreshModels: Bool = false) async throws -> CantripModelSettings {
        do {
            return try await request(path: "/api/v1/sessions/\(id)/model-settings"
                                     + (refreshModels ? "?refresh=true" : ""))
        } catch CantripRemoteError.http(let status, _) where status == 404 || status == 405 {
            let host = try await session(id: id)
            guard host.supportsModelSettings == true else { throw CantripRemoteError.modelSettingsUnsupported }
            throw CantripRemoteError.http(status, "This tab's model settings are no longer available.")
        }
    }

    func privateLocalSettings(id: String) async throws -> CantripPrivateLocalSettings {
        do {
            return try await request(path: "/api/v1/sessions/\(id)/private-settings")
        } catch CantripRemoteError.http(let status, _) where status == 404 || status == 405 {
            throw CantripRemoteError.privateLocalUnsupported
        }
    }

    /// The tab's backend slash commands, custom commands and skills. Call only for sessions with
    /// `supportsBackendCommands`; `refresh` makes the Mac rediscover them (explicit refresh only).
    func backendCommands(sessionID: String, refresh: Bool = false) async throws -> BackendCommandsResponse {
        try await request(path: "/api/v1/sessions/\(try Self.pathComponent(sessionID))/commands"
                          + (refresh ? "?refresh=true" : ""))
    }

    func inputRequests(sessionID: String) async throws -> [CantripInputRequest] {
        struct Response: Decodable { let requests: [CantripInputRequest] }
        let response: Response = try await request(path: "/api/v1/sessions/\(sessionID)/input")
        return response.requests
    }

    func macAccess() async throws -> CantripMacAccess {
        do { return try await request(path: "/api/v1/mac-access") }
        catch CantripRemoteError.http(let status, _) where status == 404 || status == 405 {
            throw ServerConfigurationError(message: "Update and reopen Cantrip on the Mac to enable Mac Permissions & View Mac.")
        }
    }

    func openMacSettings(_ permission: String) async throws {
        struct Response: Decodable { let opened: Bool }
        let response: Response = try await request(path: "/api/v1/mac-access", method: "POST",
            body: JSONSerialization.data(withJSONObject: ["permission": permission]))
        guard response.opened else { throw CantripRemoteError.invalidResponse }
    }

    func startDesktop(control: Bool) async throws -> CantripDesktopLease {
        try await request(path: "/api/v1/desktop/start", method: "POST",
                          body: JSONSerialization.data(withJSONObject: ["control": control]))
    }

    func desktopFrame(lease: CantripDesktopLease, displayID: UInt32) async throws -> CantripDesktopFrame {
        try await request(path: "/api/v1/desktop/frame", method: "POST",
            body: JSONSerialization.data(withJSONObject: ["id": lease.id.uuidString, "token": lease.token, "displayID": displayID]))
    }

    func desktopInput(lease: CantripDesktopLease, sequence: Int, encrypted: String) async throws {
        struct Response: Decodable { let accepted: Bool }
        let response: Response = try await request(path: "/api/v1/desktop/input", method: "POST",
            body: JSONSerialization.data(withJSONObject: ["id": lease.id.uuidString, "token": lease.token,
                                                         "sequence": sequence, "encrypted": encrypted]))
        guard response.accepted else { throw CantripRemoteError.invalidResponse }
    }

    func stopDesktop(lease: CantripDesktopLease) async throws {
        struct Response: Decodable { let stopped: Bool }
        let response: Response = try await request(path: "/api/v1/desktop/stop", method: "POST",
            body: JSONSerialization.data(withJSONObject: ["id": lease.id.uuidString, "token": lease.token]))
        guard response.stopped else { throw CantripRemoteError.invalidResponse }
    }

    fileprivate func prepareInput(sessionID: String, id: UUID, answer: CantripInputAnswer,
                                  questionOnly: Bool = false) async throws -> Data {
        let current = try await inputRequests(sessionID: sessionID)
        guard current.contains(where: {
            $0.id == id && $0.expiresAt > Date().timeIntervalSince1970 && (!questionOnly || $0.kind == "question")
        }) else {
            throw CantripRemoteError.http(409, "This request was already answered, cancelled or expired.")
        }
        return try JSONEncoder().encode(answer)
    }

    fileprivate func respondToInput(sessionID: String, id: UUID, body: Data) async throws -> Bool {
        struct Response: Decodable { let accepted: Bool }
        let response: Response = try await request(path: "/api/v1/sessions/\(sessionID)/input/\(id)",
                                                   method: "POST", body: body)
        return response.accepted
    }

    func privateLocalModels(id: String, baseURL: String) async throws -> [String] {
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "baseURL", value: baseURL)]
        struct Response: Decodable { let models: [String] }
        let response: Response = try await request(path: "/api/v1/sessions/\(id)/private-models?\(query.percentEncodedQuery ?? "")")
        return response.models
    }

    fileprivate func preparePrivateLocalSettings(id: String, change: CantripPrivateLocalChange) async throws -> Data {
        let current = try await privateLocalSettings(id: id)
        guard current.revision == change.revision else {
            throw CantripRemoteError.http(409, "Private Local settings changed on another device. Reload before saving.")
        }
        if let reason = current.unavailableReason { throw CantripRemoteError.http(409, reason) }
        return try JSONEncoder().encode(change)
    }

    fileprivate func updatePrivateLocalSettings(id: String, body: Data) async throws -> CantripPrivateLocalSettings {
        try await request(path: "/api/v1/sessions/\(id)/private-settings", method: "POST", body: body)
    }

    fileprivate func prepareModelSettings(id: String, change: CantripModelSettingsChange) async throws -> Data {
        let current = try await modelSettings(id: id)
        guard current.revision == change.revision else {
            throw CantripRemoteError.http(409, "Model settings changed on another device. Reload before saving.")
        }
        if let reason = current.unavailableReason { throw CantripRemoteError.http(409, reason) }
        return try JSONEncoder().encode(change)
    }

    fileprivate func updateModelSettings(id: String, body: Data) async throws -> CantripModelSettings {
        try await request(path: "/api/v1/sessions/\(id)/model-settings", method: "POST", body: body)
    }

    func updateTab(id: String, name: String? = nil, isLocked: Bool? = nil) async throws -> CantripRemoteSession {
        let body = try await prepareTabUpdate(id: id, name: name, isLocked: isLocked)
        return try await updateTab(id: id, body: body)
    }

    fileprivate func prepareTabUpdate(id: String, name: String?, isLocked: Bool?) async throws -> Data {
        struct Body: Encodable {
            var customTitle: String?
            var isLocked: Bool?
        }
        var validatedName: String?
        if let name {
            var metadata = ChatTabMetadata()
            try metadata.rename(name)
            validatedName = metadata.customTitle ?? ""
        }
        let host = try await session(id: id)
        guard host.supportsTabMetadata == true else {
            throw CantripRemoteError.tabMetadataUnsupported
        }
        return try JSONEncoder().encode(Body(customTitle: validatedName, isLocked: isLocked))
    }

    fileprivate func updateTab(id: String, body: Data) async throws -> CantripRemoteSession {
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions/\(id)/metadata",
            method: "POST",
            body: body, includeRecentExchanges: true
        )
        return response.session
    }

    fileprivate func prepareTabMove(id: String, targetID: String, after: Bool) async throws -> Data {
        let host = try await session(id: id)
        guard host.supportsTabReordering == true else {
            throw CantripRemoteError.tabReorderingUnsupported
        }
        struct Body: Encodable {
            let targetID: String
            let placement: String
        }
        return try JSONEncoder().encode(Body(targetID: targetID, placement: after ? "after" : "before"))
    }

    fileprivate func requireTabSections() async throws {
        guard try await sessionListing().supportsTabSections == true else {
            throw CantripRemoteError.tabSectionsUnsupported
        }
    }

    fileprivate func createSection(name: String) async throws -> CantripTabSectionsResponse {
        try await request(path: "/api/v1/sections", method: "POST",
                          body: try JSONSerialization.data(withJSONObject: ["name": name]))
    }

    /// Renames and/or reorders a section (`position` among the sections).
    fileprivate func updateSection(id: String, name: String? = nil, position: Int? = nil) async throws
        -> CantripTabSectionsResponse {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let position { body["position"] = position }
        return try await request(path: "/api/v1/sections/\(id)", method: "PATCH",
                                 body: try JSONSerialization.data(withJSONObject: body))
    }

    fileprivate func deleteSection(id: String) async throws -> CantripTabSectionsResponse {
        try await request(path: "/api/v1/sections/\(id)", method: "DELETE")
    }

    /// Files a tab under a section; nil returns it to Tabs.
    fileprivate func fileTab(id: String, sectionID: String?) async throws -> CantripRemoteSession {
        let body = try JSONSerialization.data(withJSONObject: ["sectionID": sectionID as Any? ?? NSNull()])
        return try await updateTab(id: id, body: body)
    }

    fileprivate func createSession(sectionID: String) async throws -> CantripRemoteSession {
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions", method: "POST",
            body: try JSONSerialization.data(withJSONObject: ["sectionID": sectionID]), includeRecentExchanges: true
        )
        return response.session
    }

    fileprivate func moveTab(id: String, body: Data) async throws -> [CantripRemoteSession] {
        let response: CantripSessionsResponse = try await request(
            path: "/api/v1/sessions/\(id)/move", method: "POST", body: body
        )
        return response.sessions
    }

    func removeQueuedPrompt(id: String, sessionID: String) async throws -> CantripRemoteSession {
        try await prepareQueueRemoval(sessionID: sessionID)
        return try await deleteQueuedPrompt(id: id, sessionID: sessionID)
    }

    fileprivate func prepareQueueRemoval(sessionID: String) async throws {
        let host = try await session(id: sessionID)
        guard host.supportsQueueRemoval == true else {
            throw CantripRemoteError.queueRemovalUnsupported
        }
    }

    fileprivate func deleteQueuedPrompt(id: String, sessionID: String) async throws -> CantripRemoteSession {
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions/\(sessionID)/queue/\(id)",
            method: "DELETE", includeRecentExchanges: true
        )
        return response.session
    }

    /// Delivers a queued message now instead of waiting for its turn.
    func sendQueuedPromptNow(id: String, sessionID: String) async throws -> CantripRemoteSession {
        try await prepareQueueSendNow(sessionID: sessionID)
        return try await postQueuedPromptNow(id: id, sessionID: sessionID)
    }

    fileprivate func prepareQueueSendNow(sessionID: String) async throws {
        let host = try await session(id: sessionID)
        guard host.supportsQueueSendNow == true else {
            throw CantripRemoteError.queueSendNowUnsupported
        }
    }

    fileprivate func postQueuedPromptNow(id: String, sessionID: String) async throws -> CantripRemoteSession {
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions/\(try Self.pathComponent(sessionID))/queue/\(try Self.pathComponent(id))/send",
            method: "POST", body: Data("{}".utf8), includeRecentExchanges: true
        )
        return response.session
    }

    /// Starts the tab's next prompt in a new model session; its title, settings and history stay.
    func startFresh(sessionID: String) async throws -> CantripRemoteSession {
        try await prepareStartFresh(sessionID: sessionID)
        return try await postStartFresh(sessionID: sessionID)
    }

    fileprivate func prepareStartFresh(sessionID: String) async throws {
        let host = try await session(id: sessionID)
        switch host.supportsStartFresh {
        case true?: return
        case false?: throw CantripRemoteError.http(409, "This conversation can't start fresh.")
        case nil: throw CantripRemoteError.startFreshUnsupported
        }
    }

    fileprivate func postStartFresh(sessionID: String) async throws -> CantripRemoteSession {
        try await action("start-fresh", sessionID: try Self.pathComponent(sessionID))
    }

    private func request<Response: Decodable>(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        includeRecentExchanges: Bool = false
    ) async throws -> Response {
        try Task.checkCancellation()
        guard var target = URLComponents(string: path), target.host == nil else {
            throw CantripRemoteError.invalidResponse
        }
        target.queryItems = (target.queryItems ?? []) + [URLQueryItem(name: "history", value: "recent")]
        if includeRecentExchanges {
            target.queryItems?.append(URLQueryItem(name: "recentExchanges",
                                                  value: String(CantripHistoryWindow.recentExchanges)))
        }
        guard let path = target.string else { throw CantripRemoteError.invalidResponse }
        if case .lan(let endpoint) = transport {
            return try await requestLAN(
                endpoint: endpoint,
                path: path,
                method: method,
                body: body
            )
        }
        guard case .remote(let baseURL) = transport else {
            throw CantripRemoteError.invalidResponse
        }
        let url = try endpoint(path: path, baseURL: baseURL)
        let isImageUpload = (body?.count ?? 0) > 256 * 1024 || (method != "GET" && Self.isUploadRoute(path))
        let isContentRead = Self.isContentRead(method: method, path: path)
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: method == "GET" ? (isContentRead ? 20 : 3) : (isImageUpload ? 60 : 12)
        )
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue(method == "PUT" && Self.isUploadRoute(path) ? "application/octet-stream" : "application/json",
                             forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            let session = urlSession ?? (method == "GET" && !isContentRead
                ? Self.readSession : (isImageUpload ? Self.imageSession : Self.session))
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw CantripRemoteError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CantripRemoteError.invalidResponse
        }
        if http.statusCode == 401 {
            throw CantripRemoteError.authentication
        }
        guard (200..<300).contains(http.statusCode) else {
            let serverMessage = (try? JSONDecoder().decode(CantripErrorResponse.self, from: data))?.error
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw CantripRemoteError.http(http.statusCode, serverMessage)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CantripRemoteError.decoding
        }
    }

    private func requestLAN<Response: Decodable>(
        endpoint: NWEndpoint,
        path: String,
        method: String,
        body: Data?
    ) async throws -> Response {
        let response = try await CantripLANRequest(
            endpoint: endpoint,
            token: token,
            method: method,
            path: path,
            body: body
        ).run()
        if response.statusCode == 401 {
            throw CantripRemoteError.authentication
        }
        guard (200..<300).contains(response.statusCode) else {
            let serverMessage = (
                try? JSONDecoder().decode(CantripErrorResponse.self, from: response.body)
            )?.error ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw CantripRemoteError.http(response.statusCode, serverMessage)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: response.body)
        } catch {
            throw CantripRemoteError.decoding
        }
    }

    private func endpoint(path: String, baseURL: URL) throws -> URL {
        guard path.hasPrefix("/"),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let target = URLComponents(string: path), target.host == nil
        else { throw CantripRemoteError.invalidResponse }
        components.percentEncodedPath = target.percentEncodedPath
        components.percentEncodedQuery = target.percentEncodedQuery
        components.fragment = nil
        guard let url = components.url,
              url.scheme?.lowercased() == baseURL.scheme?.lowercased(),
              url.host?.lowercased() == baseURL.host?.lowercased(),
              url.port == baseURL.port
        else { throw CantripRemoteError.invalidResponse }
        return url
    }
}

@MainActor
final class CantripRemoteModel: ObservableObject {
    @Published var modelSettingsSession: CantripRemoteSession?
    @Published var inputRequestsSession: CantripRemoteSession?
    @Published var inputContext: CantripInputContext?
    @Published var inputReplyID: UUID?
    @Published var showingMacAccess = false
    /// Sections the Mac groups its tabs into, in order (empty: one flat list).
    @Published private(set) var tabSections: [CantripTabSection] = []
    @Published private(set) var supportsTabSections = false
    /// A section name being asked for, shown by `cantripSectionPrompt(model:)`.
    @Published var sectionPrompt: CantripSectionPrompt?
    @Published private(set) var connectionState: CantripRemoteConnectionState = .disconnected
    @Published private(set) var configuredURL: String
    @Published private(set) var hasStoredToken: Bool
    @Published private(set) var sessions: [CantripRemoteSession] = []
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var selectedSession: CantripRemoteSession?
    @Published private(set) var isHomeSelected = false
    /// Cantrip Home's latest listed summary, kept current while a project tab is open.
    @Published private(set) var homeSummary: CantripRemoteSession?
    @Published private(set) var homeTasks: [CantripHomeTask] = []
    @Published private(set) var homeArtifacts: [CantripHomeArtifact] = []
    let artifactThumbnails = CantripArtifactThumbnailStore()
    /// Backend "/" commands per session; views observe it directly so fetches don't redraw everything.
    let slashCommands = BackendSlashCommandStore()
    /// Home's Builds tab: the Mac's over-the-air install page; nil until first loaded.
    @Published private(set) var homeBuilds: CantripOTABuildsSnapshot?
    @Published private(set) var homeBuildsError: String?
    @Published private(set) var homeDataError: String?
    @Published private(set) var isLoadingHomeData = false
    @Published private(set) var homeTasksSupportReordering = false
    @Published private(set) var homeBackground: CantripHomeBackgroundSnapshot?
    /// The hidden run (by session ID) the Background sheet should reveal, e.g. from a push.
    @Published var homeBackgroundFocus: String?
    /// Bumped to open Cantrip Home's tab drawer, e.g. from a widget's "all tabs" link.
    @Published private(set) var tabDrawerRequest = 0

    func requestTabDrawer() { tabDrawerRequest += 1 }
    @Published private(set) var homeBackgroundError: String?
    private var homeBackgroundRefreshInFlight = false
    /// Opened once by the next regular-lane selection even though it is not a tab.
    private var pendingUnlistedSessionID: String?
    /// A hidden run or log opened explicitly by ID. Polling keeps it selected even though it is
    /// never listed, instead of falling back to the first tab, until it is gone or replaced.
    private var unlistedSessionID: String?
    private var homeDataRefreshInFlight = false
    private var homeBuildsRefreshInFlight = false
    private var homeTaskOrderRevision = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isMutating = false
    @Published private(set) var videoUploadProgress: VideoUploadProgress?
    private var videoUploadTask: Task<Void, Error>?
    var isUploadingVideo: Bool { videoUploadTask != nil }
    @Published private(set) var isReorderingTabs = false
    @Published private(set) var stoppingSessionID: String?
    /// The queued message being sent now, so every queue control can show it in flight.
    @Published private(set) var sendingQueuedPromptID: String?
    @Published private(set) var detailError: String?
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var historyPrependRevision = 0
    private(set) var historyPrependAnchor: String?
    private var detailCache: [String: CantripRemoteSession] = [:]
    private var regularSelectedSessionID: String?
    private var cacheOrder: [String] = []
    private var expandedHistory: Set<String> = []
    /// Tabs whose last older-history page failed. Automatic loading pauses until a manual retry.
    @Published private(set) var olderHistoryFailures: [String: String] = [:]
    var canAutomaticallyLoadHistory: Bool {
        guard let session = selectedSession, session.hasOlderMessages == true else { return false }
        return olderHistoryFailures[session.id] == nil
    }
    var olderHistoryError: String? {
        guard let session = selectedSession, session.hasOlderMessages == true else { return nil }
        return olderHistoryFailures[session.id]
    }
    private var selectionRevision = 0
    private var selectingSessionID: String?
    private var mutationRevision = 0
    @Published private(set) var transcriptRevision = 0
    @Published private(set) var isLocalNetworkAvailable = false
    @Published private(set) var tailscaleOnly: Bool
    @Published private(set) var usageIdentity = UUID()
    let servers: ServerProfiles
    @Published private(set) var selectedServerID: UUID?
    @Published private(set) var notificationStatus: String?
    @Published private(set) var isUpdatingNotifications = false
    @Published private(set) var notificationNavigationID = UUID()
    private var notificationRegistrationTask: Task<Void, Never>?
    private let completionAlerts: CantripNotifications
    private var notificationRegistrationSucceeded = false
    private var notificationRegistrationAttempt: Date?

    var isConnected: Bool { connectionState == .connected }
    var connectionLabel: String {
        switch connectionState {
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting..."
        case .disconnected: return "Disconnected"
        }
    }
    /// Fast only while the tab on screen (or Home) is working; other tabs' status still refreshes
    /// every 5 s, and every 15 s while the Mac app is behind other apps.
    var pollDelay: Duration {
        let viewedBusy = selectedSession?.isStreaming == true || (selectedSession?.queuedCount ?? 0) > 0
            || sessions.contains { $0.id == selectedSessionID && ($0.isStreaming || $0.queuedCount > 0) }
        let delay = viewedBusy || detailError != nil || !isConnected ? Self.pollInterval : .seconds(5)
        return isFrontmost ? delay : max(delay, Self.backgroundPollInterval)
    }
    var hasConfiguration: Bool { baseURL != nil || token != nil }
    var isConfigured: Bool {
        token != nil && (baseURL != nil || directEndpoint != nil || (!tailscaleOnly && !lanEndpoints.isEmpty))
    }

    var endpointHost: String {
        if case .lan(let endpoint) = activeTransport {
            return endpoint == directEndpoint ? directAddress ?? "Direct address" : "Local network"
        }
        if activeTransport == nil, isLocalNetworkAvailable {
            return "Local network"
        }
        guard let baseURL else { return directAddress ?? "Not configured" }
        if let port = baseURL.port {
            return "\(baseURL.host ?? baseURL.absoluteString):\(port)"
        }
        return baseURL.host ?? baseURL.absoluteString
    }

    /// The Mac's browser remote opened on one tab, for clients without Remote tabs of their own.
    /// Nil when the Mac is paired only over the local network, which browsers can't reach.
    var canOpenWebTabs: Bool { baseURL != nil }

    func webTabURL(_ tabID: String) -> URL? {
        guard let baseURL, UUID(uuidString: tabID) != nil,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/"
        components.fragment = "tab=\(tabID.uppercased())"
        return components.url
    }

    private static let endpointKey = "cantrip.remote.base-url"
    private static let tailscaleOnlyKey = "cantrip.remote.tailscale-only"
    // Allow a bounded HTTPS-to-LAN failover plus the polling interval.
    private static let staleInterval: Duration = .seconds(10)
    private static let pollInterval: Duration = .milliseconds(1500)
    private static let backgroundPollInterval: Duration = .seconds(15)

    private var baseURL: URL?
    private var token: String?
    private var appIsActive = false
    /// False while the Mac app is visible but another app is frontmost; iOS never sets it.
    private var isFrontmost = true
    /// The revision each Home list came from, with the list as fetched: the revision is sent
    /// only while the shown list is still that one, so any other change refetches in full.
    private var homeTasksFetched: (revision: String, tasks: [CantripHomeTask])?
    private var homeArtifactsFetched: (revision: String, artifacts: [CantripHomeArtifact])?
    private var pollingTask: Task<Void, Never>?
    private var detailRefreshTask: Task<Void, Never>?
    private var detailRefreshKey: String?
    private var detailRefreshID = UUID()
    private var staleTask: Task<Void, Never>?
    private var lastAuthenticatedAt: Date?
    private var configurationGeneration = 0
    private var lanEndpoints: [NWEndpoint] = []
    /// The selected profile's saved direct address (host:port of the Mac's TLS-PSK listener).
    @Published private(set) var directAddress: String?
    private var directEndpoint: NWEndpoint?
    private var activeTransport: CantripTransport?
    private let lanBrowser = CantripLANBrowser()
    private let requestGate = CantripRequestGate()
    private let router = CantripRemoteRouter()
    private let urlSession: URLSession?
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 12 << 20
        return cache
    }()

    private let authorizeSensitiveAction: (String) async throws -> Void
    /// Only the app's model feeds the widget and Live Activity; test models don't.
    private let liveStatus: CantripLiveStatusController?

    init(urlSession: URLSession? = nil, servers: ServerProfiles? = nil,
         completionAlerts: CantripNotifications? = nil,
         liveStatus: CantripLiveStatusController? = nil,
         authorizeSensitiveAction: @escaping (String) async throws -> Void = CantripBiometrics.authorize) {
        self.urlSession = urlSession
        self.liveStatus = liveStatus
        self.authorizeSensitiveAction = authorizeSensitiveAction
        self.completionAlerts = completionAlerts ?? .shared
        self.servers = servers ?? ServerProfiles(kind: .cantrip)
        let storedURL = UserDefaults.standard.string(forKey: Self.endpointKey) ?? ""
        configuredURL = storedURL
        tailscaleOnly = UserDefaults.standard.bool(forKey: Self.tailscaleOnlyKey)
        token = CantripRemoteCredentials.loadToken()
        hasStoredToken = token != nil
        do {
            if !self.servers.hasSavedState, let token {
                try self.servers.migrate(url: storedURL, credential: token, tailscaleOnly: tailscaleOnly)
            }
            if let server = self.servers.selected {
                token = try self.servers.credential(for: server)
                configuredURL = server.url
                tailscaleOnly = server.tailscaleOnly
                directAddress = try CantripDirectAddress.normalized(server.directAddress)
                directEndpoint = CantripDirectAddress.endpoint(directAddress)
                selectedServerID = server.id
            } else if self.servers.hasSavedState {
                configuredURL = ""
                token = nil
                tailscaleOnly = false
            }
            if let issue = self.servers.loadIssue {
                throw ServerConfigurationError(message: issue)
            }
            hasStoredToken = token != nil
            baseURL = try Self.normalizedBaseURL(configuredURL)
            if baseURL == nil, !configuredURL.isEmpty {
                errorMessage = "The saved Remote URL is invalid. Open settings and save it again."
            }
        } catch {
            baseURL = nil
            token = nil
            hasStoredToken = false
            errorMessage = error.localizedDescription
        }
        if let liveStatus {
            liveStatus.uploader = { [weak self] body in
                guard let self else { throw CancellationError() }
                return try await self.performAuthenticated(allowFallback: true) {
                    try await $0.liveStatusSubscription(body: body)
                }
            }
            liveStatus.fetcher = { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.performAuthenticated(allowFallback: true) { try await $0.liveStatus() }
            }
            syncLiveStatusPairing()
        }
    }

    /// Shares the selected pairing with the widget (nil clears it).
    private func syncLiveStatusPairing() {
        liveStatus?.pairingChanged(serverID: token == nil ? nil : selectedServerID, token: token, baseURL: baseURL,
                                   tailscaleOnly: tailscaleOnly, installationID: completionAlerts.installationID)
    }

    /// Opens the Mac tab a widget or Live Activity row points at.
    func openLiveStatusLink(_ target: CantripDeepLink.Target) async {
        let serverID: String?
        let sessionID: String?
        switch target {
        case .tabs(let server): serverID = server; sessionID = nil
        case .tab(let id, let server): serverID = server; sessionID = id
        }
        do {
            if let serverID, serverID != selectedServerID?.uuidString {
                guard let server = servers.servers.first(where: { $0.id.uuidString == serverID }) else {
                    throw ServerConfigurationError(message: "That widget belongs to a Mac that is no longer paired.")
                }
                try await selectServer(server)
            }
            guard let sessionID else { return }
            guard !isMutating, !isUploadingVideo else {
                throw ServerConfigurationError(message: "Finish the current upload or request before opening another tab.")
            }
            await selectSession(sessionID)
            notificationNavigationID = UUID()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addServer(_ draft: ServerDraft) throws {
        try servers.add(draft)
    }

    func selectServer(_ server: SavedServer) async throws {
        guard selectedServerID != server.id else { return }
        let credential = try servers.credential(for: server)
        guard await configure(
            url: server.url, pairingToken: credential, tailscaleOnly: server.tailscaleOnly,
            directAddress: server.directAddress
        ) else {
            throw ServerConfigurationError(message: errorMessage ?? "Could not select the server.")
        }
        try servers.select(server)
        selectedServerID = server.id
        syncLiveStatusPairing()
        notificationStatus = nil
        refreshCompletionNotificationRegistration(force: true)
    }

    func removeServer(_ server: SavedServer) throws {
        guard !isUpdatingNotifications else {
            throw ServerConfigurationError(message: "Wait for notification settings to finish updating.")
        }
        guard !completionAlerts.hasSubscription(serverID: server.id) else {
            throw ServerConfigurationError(message: "Select this Mac and turn off its completion alerts before removing it.")
        }
        guard !isMutating, !isUploadingVideo else {
            throw ServerConfigurationError(message: "Wait for the current request to finish before removing a server.")
        }
        if selectedServerID == server.id {
            guard clearConfiguration() else {
                throw ServerConfigurationError(message: errorMessage ?? "Could not disconnect the server.")
            }
        }
        try servers.remove(server)
    }

    /// Gateway Mac: slows polling while another app is frontmost and catches up on return.
    func setFrontmost(_ frontmost: Bool) {
        guard isFrontmost != frontmost else { return }
        isFrontmost = frontmost
    }

    func setAppActive(_ active: Bool) {
        guard appIsActive != active else { return }
        appIsActive = active
        if active {
            startLANDiscovery()
            startPolling()
            refreshCompletionNotificationRegistration(force: true)
        } else {
            videoUploadTask?.cancel()
            lanBrowser.stop()
            stopPolling()
        }
    }

    func completionNotificationStatus() async throws -> CantripPushStatus {
        try await performAuthenticated(allowFallback: true) { try await $0.completionNotifications() }
    }

    func setCompletionNotifications(enabled: Bool) async throws {
        guard !isUpdatingNotifications else {
            throw ServerConfigurationError(message: "Wait for notification settings to finish updating.")
        }
        guard let serverID = selectedServerID, let token else {
            throw ServerConfigurationError(message: "Save and select a Cantrip server first.")
        }
        isUpdatingNotifications = true
        defer { isUpdatingNotifications = false }
        let identity = usageIdentity
        let notifications = completionAlerts
        var body: [String: Any] = ["installationID": notifications.installationID.uuidString,
                                      "serverID": serverID.uuidString]
        if enabled {
            let status = try await completionNotificationStatus()
            guard status.configured else { throw ServerConfigurationError(message: status.message) }
            body["deviceToken"] = try await notifications.register()
            guard let environment = Bundle.main.object(forInfoDictionaryKey: "CantripPushEnvironment") as? String,
                  ["development", "production"].contains(environment) else {
                throw ServerConfigurationError(message: "This build has no valid Apple push environment.")
            }
            body["environment"] = environment
            body["inputNeeded"] = true
        }
        guard usageIdentity == identity, selectedServerID == serverID else { throw CancellationError() }
        let data = try JSONSerialization.data(withJSONObject: body)
        if enabled {
            notifications.prepareRegistration(serverID: serverID, fingerprint: CantripLANProtocol.tokenFingerprint(token))
        }
        // Registration/removal are idempotent, so an uncertain response can
        // safely retry over the other authenticated route.
        _ = try await performAuthenticated(allowFallback: true) {
            try await $0.completionNotifications(method: enabled ? "POST" : "DELETE", body: data)
        }
        guard usageIdentity == identity, selectedServerID == serverID else { throw CancellationError() }
        notifications.save(serverID: serverID, fingerprint: enabled ? CantripLANProtocol.tokenFingerprint(token) : nil)
        notificationStatus = nil
        notificationRegistrationSucceeded = enabled
    }

    func refreshCompletionNotificationRegistration(force: Bool = false) {
        if force {
            notificationRegistrationSucceeded = false
            notificationRegistrationAttempt = nil
        }
        guard appIsActive, isConfigured, !isUpdatingNotifications, notificationRegistrationTask == nil,
              !notificationRegistrationSucceeded,
              notificationRegistrationAttempt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true,
              completionAlerts.hasSubscription(serverID: selectedServerID) else { return }
        notificationRegistrationAttempt = Date()
        let identity = usageIdentity
        notificationRegistrationTask = Task { [weak self] in
            guard let self else { return }
            defer { notificationRegistrationTask = nil }
            do { try await setCompletionNotifications(enabled: true) }
            catch is CancellationError {}
            catch {
                if usageIdentity == identity { notificationStatus = error.localizedDescription }
            }
        }
    }

    private func selectNotificationServer(_ target: CantripNotificationTarget) async throws {
        await notificationRegistrationTask?.value
        guard let server = servers.servers.first(where: { $0.id == target.serverID }),
              CantripLANProtocol.tokenFingerprint(try servers.credential(for: server)) == target.fingerprint else {
            throw ServerConfigurationError(message: "This notification belongs to a removed or re-paired Cantrip server.")
        }
        try await selectServer(server)
        guard !isMutating, !isUploadingVideo else {
            throw ServerConfigurationError(message: "Finish the current upload or request before opening this notification.")
        }
    }

    /// A background run's request opens Home's Background list on that run, where it is
    /// answered in place; the run's hidden session never opens as a tab.
    func openHomeRunNotification(_ target: CantripNotificationTarget) async {
        do {
            try await selectNotificationServer(target)
            await selectHome()
            homeBackgroundFocus = target.sessionID.uuidString
            await refreshHomeBackground()
            notificationNavigationID = UUID()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openCompletionNotification(_ target: CantripNotificationTarget) async {
        do {
            try await selectNotificationServer(target)
            await selectSession(target.sessionID.uuidString)
            if target.kind == "input" {
                showingMacAccess = false
                inputRequestsSession = nil
            }
            if target.kind == "macAttention" {
                inputRequestsSession = nil
                showingMacAccess = true
            }
            notificationNavigationID = UUID()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func configure(
        url rawURL: String,
        pairingToken rawToken: String,
        tailscaleOnly: Bool = false,
        directAddress rawDirectAddress: String? = nil
    ) async -> Bool {
        guard !isMutating, !isUploadingVideo, !isUpdatingNotifications else {
            errorMessage = "Wait for the current request to finish before switching servers."
            return false
        }
        do {
            let normalized = try Self.normalizedBaseURL(rawURL)
            let direct = try CantripDirectAddress.normalized(rawDirectAddress)
            guard !tailscaleOnly || normalized != nil else {
                throw CantripRemoteError.invalidURL("Enter a Tailscale URL to use Tailscale only.")
            }
            let enteredToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveToken = enteredToken.isEmpty ? token : enteredToken
            guard let effectiveToken, !effectiveToken.isEmpty else {
                throw CantripRemoteError.missingToken
            }
            if !enteredToken.isEmpty {
                try CantripRemoteCredentials.saveToken(enteredToken)
            }

            stopPolling()
            lanBrowser.stop()
            configurationGeneration += 1
            usageIdentity = UUID()
            imageCache.removeAllObjects()
            artifactThumbnails.removeAll()
            slashCommands.removeAll()
            resetHistory()
            router.reset()
            baseURL = normalized
            directAddress = direct
            directEndpoint = CantripDirectAddress.endpoint(direct)
            self.tailscaleOnly = tailscaleOnly
            UserDefaults.standard.set(tailscaleOnly, forKey: Self.tailscaleOnlyKey)
            token = effectiveToken
            configuredURL = normalized?.absoluteString ?? ""
            hasStoredToken = true
            activeTransport = nil
            lanEndpoints = []
            isLocalNetworkAvailable = false
            sessions = []
            homeSummary = nil
            tabSections = []
            supportsTabSections = false
            selectedSessionID = nil
            selectedSession = nil
            isHomeSelected = false
            homeTasks = []
            homeTasksSupportReordering = false
            homeArtifacts = []
            homeTasksFetched = nil
            homeArtifactsFetched = nil
            homeBuilds = nil
            homeBuildsError = nil
            homeBackground = nil
            homeBackgroundError = nil
            transcriptRevision += 1
            if configuredURL.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.endpointKey)
            } else {
                UserDefaults.standard.set(configuredURL, forKey: Self.endpointKey)
            }
            errorMessage = nil
            if appIsActive {
                startLANDiscovery()
                startPolling()
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            markDisconnected()
            return false
        }
    }

    @discardableResult
    func clearConfiguration() -> Bool {
        guard !isMutating, !isUploadingVideo, !isUpdatingNotifications else {
            errorMessage = "Wait for the current request to finish before disconnecting."
            return false
        }
        do {
            try CantripRemoteCredentials.removeToken()
            stopPolling()
            lanBrowser.stop()
            configurationGeneration += 1
            usageIdentity = UUID()
            imageCache.removeAllObjects()
            artifactThumbnails.removeAll()
            slashCommands.removeAll()
            resetHistory()
            router.reset()
            UserDefaults.standard.removeObject(forKey: Self.endpointKey)
            UserDefaults.standard.removeObject(forKey: Self.tailscaleOnlyKey)
            tailscaleOnly = false
            baseURL = nil
            directAddress = nil
            directEndpoint = nil
            token = nil
            activeTransport = nil
            lanEndpoints = []
            isLocalNetworkAvailable = false
            configuredURL = ""
            hasStoredToken = false
            sessions = []
            homeSummary = nil
            tabSections = []
            supportsTabSections = false
            selectedSessionID = nil
            selectedSession = nil
            isHomeSelected = false
            homeTasks = []
            homeTasksSupportReordering = false
            homeArtifacts = []
            homeTasksFetched = nil
            homeArtifactsFetched = nil
            homeBuilds = nil
            homeBuildsError = nil
            homeBackground = nil
            homeBackgroundError = nil
            selectedServerID = nil
            errorMessage = nil
            transcriptRevision += 1
            syncLiveStatusPairing()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refreshNow() async {
        await refresh()
        await detailRefreshTask?.value
    }

    func githubBuilds() async throws -> CantripBuildSnapshot {
        guard isConfigured else {
            throw CantripRemoteError.transport("Configure Cantrip Remote in Settings and connect to your Mac to view GitHub builds.")
        }
        return try await performAuthenticated(allowFallback: true) { api in
            try await api.githubBuilds()
        }
    }

    func memoryCatalog(query: String, after: String?) async throws -> CantripMemoryCatalog {
        guard isConfigured else {
            throw CantripRemoteError.transport("Configure Cantrip Remote in Settings and connect to your Mac to view its saved memory.")
        }
        return try await performHistoryRead { try await $0.memoryCatalog(query: query, after: after) }
    }

    func maintenanceStatus() async throws -> CantripMaintenanceSnapshot {
        try await performHistoryRead { try await $0.maintenance() }
    }

    func startMaintenance(_ request: CantripMaintenanceRequest) async throws -> CantripMaintenanceSnapshot {
        guard let token else { throw CantripRemoteError.missingToken }
        let generation = configurationGeneration
        updateRoutes()
        let reader = router.independentReader()
        let result = try await reader.performMutation { transport in
            try await CantripRemoteAPI(transport: transport, token: token, urlSession: urlSession).maintenance()
        } operation: { transport, _ in
            guard generation == self.configurationGeneration else { throw CancellationError() }
            return try await CantripRemoteAPI(transport: transport, token: token, urlSession: urlSession).maintenance(request)
        }
        guard generation == configurationGeneration else { throw CancellationError() }
        return result
    }

    func memoryDocument(id: String, offset: Int, revision: String?) async throws -> CantripMemoryPage {
        try await performHistoryRead { try await $0.memoryDocument(id: id, offset: offset, revision: revision) }
    }

    func voiceVocabulary() async throws -> CantripVoiceVocabulary? {
        guard isConfigured else { return nil }
        return try await performHistoryRead { try await $0.voiceVocabulary() }
    }

    func copilotUsage() async throws -> CopilotUsageSnapshot {
        guard isConfigured else {
            throw CantripRemoteError.transport("Configure Cantrip Remote in Settings and connect to your Mac to view Copilot usage.")
        }
        return try await performAuthenticated(allowFallback: true) { api in
            try await api.copilotUsage()
        }
    }

    func image(sessionID: String, imageID: String, thumbnail: Bool) async throws -> UIImage {
        let identity = usageIdentity
        let key = "\(usageIdentity)/\(sessionID)/\(imageID)/\(thumbnail)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        let data = try await performAuthenticated(allowFallback: true) { api in
            try await api.imageData(sessionID: sessionID, imageID: imageID, thumbnail: thumbnail)
        }
        let isPreview = ChatMessageImage.validPreviewID(imageID)
        let image = try await Task.detached(priority: .userInitiated) {
            try ChatImageDecoder.decode(
                data, maximumDimension: isPreview
                    ? (thumbnail ? GeneratedImagePreview.thumbnailDimension : GeneratedImagePreview.maximumDimension)
                    : (thumbnail ? 320 : ImageAttachmentProcessor.maximumDimension),
                maximumBytes: isPreview ? GeneratedImagePreview.maximumImageBytes : ImageAttachmentProcessor.maximumImageBytes
            )
        }.value
        try Task.checkCancellation()
        guard identity == usageIdentity else { throw CancellationError() }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
        imageCache.setObject(image, forKey: key, cost: cost)
        return image
    }

    func selectSession(_ id: String) async {
        guard id != selectedSessionID || selectedSession?.id != id else { return }
        isHomeSelected = false
        regularSelectedSessionID = id
        unlistedSessionID = sessions.contains(where: { $0.id == id }) ? nil : id
        cancelDetailRefresh()
        selectionRevision += 1
        let selection = selectionRevision
        let revision = mutationRevision
        selectingSessionID = id
        defer {
            if selection == selectionRevision { selectingSessionID = nil }
        }
        selectedSessionID = id
        selectedSession = detailCache[id]
        detailError = nil
        transcriptRevision += 1
        do {
            let detail = try await performHistoryRead { api in
                try await api.session(id: id)
            }
            guard selectedSessionID == id, selection == selectionRevision,
                  revision == mutationRevision else { return }
            apply(detail)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard selectedSessionID == id, selection == selectionRevision else { return }
            detailError = "Could not update this conversation. \(error.localizedDescription)"
            errorMessage = error.localizedDescription
            handleReadFailure(error, detailOnly: true)
        }
    }

    /// Makes the next switch to the Remote lane open this tab instead of the last one.
    func prepareToOpenTab(_ id: String) {
        regularSelectedSessionID = id
    }

    /// Home's background log is reachable by ID but never listed as a tab.
    func prepareToOpenHomeBackgroundLog() {
        pendingUnlistedSessionID = homeBackground?.sessionID
    }

    /// A live hidden background run is reachable by ID while it runs.
    func prepareToOpenHomeRun(sessionID: String) {
        pendingUnlistedSessionID = sessionID
    }

    /// Stops one background run (or skips one still waiting) and refreshes the list.
    func stopHomeBackgroundRun(_ id: UUID) async -> Bool {
        guard homeBackground?.supportsStop == true, !isMutating else { return false }
        isMutating = true
        defer { isMutating = false }
        do {
            let snapshot = try await performAuthenticated(allowFallback: false) {
                try await $0.stopHomeBackgroundRun(id: id)
            }
            if homeBackground != snapshot { homeBackground = snapshot }
            homeBackgroundError = nil
            return true
        } catch {
            homeBackgroundError = error.localizedDescription
            return false
        }
    }

    func selectHome() async {
        if isHomeSelected, selectedSession?.isCantripHome == true { return }
        if !isHomeSelected { regularSelectedSessionID = selectedSessionID }
        cancelDetailRefresh()
        selectionRevision += 1
        let selection = selectionRevision
        let revision = mutationRevision
        isHomeSelected = true
        selectedSessionID = nil
        selectedSession = nil
        detailError = nil
        transcriptRevision += 1
        do {
            let detail = try await performHistoryRead { api in
                try await api.homeSession()
            }
            guard isHomeSelected, selection == selectionRevision,
                  revision == mutationRevision else { return }
            selectedSessionID = detail.id
            apply(detail)
            await refreshHomeData()
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard isHomeSelected, selection == selectionRevision else { return }
            detailError = "Cantrip Home is unavailable. \(error.localizedDescription)"
            errorMessage = error.localizedDescription
            handleReadFailure(error, detailOnly: true)
        }
    }

    func selectRegularSession() async {
        isHomeSelected = false
        if let id = pendingUnlistedSessionID {
            pendingUnlistedSessionID = nil
            await selectSession(id)
            return
        }
        let id = regularSelectedSessionID.flatMap { candidate in
            sessions.contains(where: { $0.id == candidate }) ? candidate : nil
        } ?? sessions.first?.id
        guard let id else {
            selectedSessionID = nil
            selectedSession = nil
            transcriptRevision += 1
            return
        }
        await selectSession(id)
    }

    func refreshHomeData() async {
        guard isHomeSelected, isConfigured, !homeDataRefreshInFlight else { return }
        homeDataRefreshInFlight = true
        let showsInitialLoading = homeTasks.isEmpty && homeArtifacts.isEmpty
        if showsInitialLoading { isLoadingHomeData = true }
        defer {
            homeDataRefreshInFlight = false
            if showsInitialLoading { isLoadingHomeData = false }
        }
        let orderRevision = homeTaskOrderRevision
        let tasksRevision = homeTasksFetched.flatMap { $0.tasks == homeTasks ? $0.revision : nil }
        let artifactsRevision = homeArtifactsFetched.flatMap { $0.artifacts == homeArtifacts ? $0.revision : nil }
        do {
            async let tasks = performHistoryRead { try await $0.homeTasks(ifChangedFrom: tasksRevision) }
            async let artifacts = performHistoryRead { try await $0.homeArtifacts(ifChangedFrom: artifactsRevision) }
            let values = try await (tasks, artifacts)
            guard isHomeSelected else { return }
            if let snapshot = values.0 {
                // A snapshot fetched across a reorder may still carry the old order.
                if orderRevision == homeTaskOrderRevision {
                    if homeTasks != snapshot.tasks { homeTasks = snapshot.tasks }
                    homeTasksFetched = (snapshot.revision, snapshot.tasks)
                }
                if homeTasksSupportReordering != snapshot.supportsReordering {
                    homeTasksSupportReordering = snapshot.supportsReordering
                }
                if homeDataError != snapshot.error { homeDataError = snapshot.error }
            } else if homeDataError != nil {
                // Unchanged means the Mac saved its tasks fine; clear a stale fetch error.
                homeDataError = nil
            }
            if let snapshot = values.1 {
                if homeArtifacts != snapshot.artifacts { homeArtifacts = snapshot.artifacts }
                homeArtifactsFetched = (snapshot.revision, snapshot.artifacts)
            }
            if (selectedSession?.backgroundInputCount ?? 0) > 0
                || homeBackground?.runs.contains(where: \.needsInput) == true {
                await refreshHomeBackground()
            }
        } catch is CancellationError {
            return
        } catch {
            guard isHomeSelected else { return }
            let message = error.localizedDescription
            if homeDataError != message { homeDataError = message }
        }
    }

    func refreshHomeBuilds() async {
        guard isHomeSelected, isConfigured, !homeBuildsRefreshInFlight else { return }
        homeBuildsRefreshInFlight = true
        defer { homeBuildsRefreshInFlight = false }
        do {
            let snapshot = try await performHistoryRead { try await $0.homeBuilds() }
            guard isHomeSelected else { return }
            if homeBuilds != snapshot { homeBuilds = snapshot }
            if homeBuildsError != nil { homeBuildsError = nil }
        } catch is CancellationError {
            return
        } catch {
            guard isHomeSelected else { return }
            let message = Self.homeBuildsErrorMessage(error)
            if homeBuildsError != message { homeBuildsError = message }
        }
    }

    static func homeBuildsErrorMessage(_ error: Error) -> String {
        switch error {
        case CantripRemoteError.http(404, _):
            return "Update Cantrip on the Mac to list its install builds."
        case let error where CantripRemoteError.isRouteFailure(error):
            return "Can't reach Cantrip on your Mac. Turn on Tailscale (or join the Mac's Wi-Fi) "
                + "and make sure Cantrip is running."
        default:
            return error.localizedDescription
        }
    }

    /// The build's PNG icon from the Mac; nil when it has none.
    func homeBuildIcon(_ build: CantripOTABuild) async throws -> Data? {
        let parts = build.id.split(separator: "/", omittingEmptySubsequences: false)
        guard build.hasIcon, parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return try await performHistoryRead { try await $0.homeBuildIcon(id: build.id) }
    }

    func refreshHomeBackground() async {
        guard isHomeSelected, isConfigured, selectedSession?.supportsBackgroundRuns == true,
              !homeBackgroundRefreshInFlight else { return }
        homeBackgroundRefreshInFlight = true
        defer { homeBackgroundRefreshInFlight = false }
        do {
            let snapshot = try await performHistoryRead { try await $0.homeBackground() }
            guard isHomeSelected else { return }
            if homeBackground != snapshot { homeBackground = snapshot }
            if homeBackgroundError != nil { homeBackgroundError = nil }
        } catch is CancellationError {
            return
        } catch {
            guard isHomeSelected else { return }
            let message = error.localizedDescription
            if homeBackgroundError != message { homeBackgroundError = message }
        }
    }

    func updateHomeTask(_ task: CantripHomeTask, title: String? = nil,
                        prompt: String? = nil, enabled: Bool? = nil) async -> Bool {
        guard !isMutating else { return false }
        isMutating = true
        defer { isMutating = false }
        do {
            let updated = try await performAuthenticated(allowFallback: false) { api in
                try await api.updateHomeTask(
                    id: task.id, title: title, prompt: prompt, enabled: enabled
                )
            }
            if let index = homeTasks.firstIndex(where: { $0.id == updated.id }) {
                homeTasks[index] = updated
            }
            homeDataError = nil
            return true
        } catch {
            homeDataError = error.localizedDescription
            return false
        }
    }

    /// Applies the move locally first so List drops do not snap back while the Mac saves.
    @discardableResult
    func moveHomeTask(_ id: UUID, relativeTo targetID: UUID, after: Bool) async -> Bool {
        guard id != targetID else { return true }
        guard homeTasksSupportReordering else {
            homeDataError = "Update Cantrip on the Mac to reorder tasks."
            return false
        }
        guard !isMutating else { return false }
        guard let source = homeTasks.firstIndex(where: { $0.id == id }),
              let target = homeTasks.firstIndex(where: { $0.id == targetID }) else {
            homeDataError = "A task changed on the Mac. Refresh Tasks and try again."
            return false
        }
        let previousOrder = homeTasks
        var preview = homeTasks
        let moved = preview.remove(at: source)
        preview.insert(moved, at: target - (source < target ? 1 : 0) + (after ? 1 : 0))
        homeTasks = preview
        homeTaskOrderRevision += 1
        isMutating = true
        defer {
            isMutating = false
            homeTaskOrderRevision += 1
        }
        do {
            let snapshot = try await performAuthenticated(allowFallback: false) {
                try await $0.moveHomeTask(id: id, targetID: targetID, after: after)
            }
            guard isHomeSelected else { return false }
            if homeTasks != snapshot.tasks { homeTasks = snapshot.tasks }
            homeTasksFetched = (snapshot.revision, snapshot.tasks)
            homeTasksSupportReordering = snapshot.supportsReordering
            homeDataError = snapshot.error
            return true
        } catch {
            guard isHomeSelected else { return false }
            if homeTasks == preview { homeTasks = previousOrder }
            homeDataError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func moveHomeTask(_ id: UUID, offset: Int) async -> Bool {
        guard [-1, 1].contains(offset),
              let index = homeTasks.firstIndex(where: { $0.id == id }),
              homeTasks.indices.contains(index + offset) else { return false }
        return await moveHomeTask(id, relativeTo: homeTasks[index + offset].id, after: offset > 0)
    }

    func deleteHomeTask(_ task: CantripHomeTask) async -> Bool {
        guard !isMutating else { return false }
        isMutating = true
        defer { isMutating = false }
        do {
            try await performAuthenticated(allowFallback: false) {
                try await $0.deleteHomeTask(id: task.id)
            }
            homeTasks.removeAll { $0.id == task.id }
            homeDataError = nil
            return true
        } catch {
            homeDataError = error.localizedDescription
            return false
        }
    }

    func saveHomeTaskRecord(
        taskID: UUID, recordID: UUID?, values: [String: String]
    ) async -> Bool {
        guard !isMutating else { return false }
        isMutating = true
        defer { isMutating = false }
        do {
            let updated = try await performAuthenticated(allowFallback: false) { api in
                if let recordID {
                    return try await api.updateHomeTaskRecord(
                        taskID: taskID, recordID: recordID, values: values
                    )
                }
                return try await api.createHomeTaskRecord(taskID: taskID, values: values)
            }
            if let index = homeTasks.firstIndex(where: { $0.id == updated.id }) {
                homeTasks[index] = updated
            }
            homeDataError = nil
            return true
        } catch {
            homeDataError = error.localizedDescription
            return false
        }
    }

    func deleteHomeTaskRecord(taskID: UUID, recordID: UUID) async -> Bool {
        guard !isMutating else { return false }
        isMutating = true
        defer { isMutating = false }
        do {
            let updated = try await performAuthenticated(allowFallback: false) {
                try await $0.deleteHomeTaskRecord(taskID: taskID, recordID: recordID)
            }
            if let index = homeTasks.firstIndex(where: { $0.id == updated.id }) {
                homeTasks[index] = updated
            }
            homeDataError = nil
            return true
        } catch {
            homeDataError = error.localizedDescription
            return false
        }
    }

    func deleteHomeArtifact(_ artifact: CantripHomeArtifact) async -> Bool {
        guard !isMutating else { return false }
        isMutating = true
        defer { isMutating = false }
        do {
            try await performAuthenticated(allowFallback: false) {
                try await $0.deleteHomeArtifact(id: artifact.id)
            }
            homeArtifacts.removeAll { $0.id == artifact.id }
            homeDataError = nil
            return true
        } catch {
            homeDataError = error.localizedDescription
            return false
        }
    }

    func homeArtifactThumbnail(_ artifact: CantripHomeArtifact) async -> CantripArtifactThumbnail? {
        let generation = configurationGeneration
        return await artifactThumbnails.thumbnail(for: artifact) { [weak self] in
            guard let self, generation == self.configurationGeneration else { throw CancellationError() }
            return try await self.performHistoryRead { try await $0.homeArtifactThumbnail(id: artifact.id) }
        }
    }

    /// The full image for the viewer, decoded off the main actor and kept in the image cache.
    func homeArtifactImage(_ artifact: CantripHomeArtifact) async throws -> UIImage {
        let identity = usageIdentity
        let key = "\(identity)/artifact/\(CantripArtifactThumbnailStore.key(artifact))" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        let data = try await performHistoryRead { try await $0.homeArtifactData(id: artifact.id) }
        let image = try await Task.detached(priority: .userInitiated) {
            try ChatImageDecoder.decode(data, maximumDimension: GeneratedImagePreview.maximumDimension,
                                        maximumBytes: 20 * 1024 * 1024)
        }.value
        try Task.checkCancellation()
        guard identity == usageIdentity else { throw CancellationError() }
        imageCache.setObject(image, forKey: key, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count)
        return image
    }

    func homeArtifactFile(_ artifact: CantripHomeArtifact) async throws -> URL {
        let data = try await performHistoryRead {
            try await $0.homeArtifactData(id: artifact.id)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CantripHomeArtifacts", isDirectory: true)
            .appendingPathComponent(artifact.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let source = URL(fileURLWithPath: artifact.relativePath)
        let ext = source.pathExtension
        let base = artifact.title.replacingOccurrences(
            of: #"[^A-Za-z0-9._ -]"#, with: "_", options: .regularExpression
        )
        let url = directory.appendingPathComponent(
            ext.isEmpty || base.lowercased().hasSuffix(".\(ext.lowercased())")
                ? base : "\(base).\(ext)"
        )
        try data.write(to: url, options: [.atomic])
        return url
    }

    /// Starts the next older page unless one is already loading, a failure is awaiting
    /// retry, or the start of history has been reached.
    func requestOlderMessages() {
        guard canAutomaticallyLoadHistory, !isLoadingHistory, !isMutating else { return }
        Task { await loadOlderMessages(automatically: true) }
    }

    func loadOlderMessages(automatically: Bool = false) async {
        guard !automatically || canAutomaticallyLoadHistory else { return }
        guard !isLoadingHistory, !isMutating,
              let current = selectedSession, current.hasOlderMessages == true,
              let before = current.transcript.first?.id else { return }
        let revision = mutationRevision
        let selection = selectionRevision
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let page = try await performHistoryRead { api in
                try await api.olderMessages(id: current.id, before: before)
            }
            guard revision == mutationRevision, selection == selectionRevision,
                  var latest = selectedSession, latest.id == current.id,
                  page.id == current.id,
                  latest.historyStartID == page.historyStartID,
                  latest.transcript.first?.id == before else { return }
            let existing = Set(latest.transcript.map(\.id))
            let received = page.transcript.filter { !existing.contains($0.id) }
            guard !received.isEmpty || page.hasOlderMessages == false else {
                throw CantripRemoteError.invalidResponse
            }
            latest.messages = received + latest.transcript
            latest.hasOlderMessages = page.hasOlderMessages == true
            olderHistoryFailures.removeValue(forKey: current.id)
            expandedHistory.insert(current.id)
            historyPrependAnchor = before
            apply(latest, mergeHistory: false)
            historyPrependRevision += 1
            detailError = nil
        } catch is CancellationError {
            return
        } catch {
            guard selection == selectionRevision else { return }
            let message = "Couldn't load older messages. \(error.localizedDescription)"
            olderHistoryFailures[current.id] = message
            // Announce every failure, so a retry that fails the same way is not silent.
            AccessibilityNotification.Announcement(message).post()
            handleReadFailure(error, detailOnly: true)
        }
    }

    func fullMessage(sessionID: String, messageID: String) async throws -> CantripRemoteMessage {
        try await performHistoryRead { api in
            try await api.fullMessage(sessionID: sessionID, messageID: messageID)
        }
    }

    func mcpAppPayload(sessionID: String, appID: String) async throws -> MCPAppPayload {
        try await performHistoryRead { api in
            try await api.mcpAppPayload(sessionID: sessionID, appID: appID)
        }
    }

    func mcpAppServerRequest(sessionID: String, appID: String, method: String,
                             params: [String: Any]) async throws -> [String: Any] {
        try await performAuthenticated(allowFallback: false) { api in
            try await api.mcpAppServerRequest(sessionID: sessionID, appID: appID, method: method, params: params)
        }
    }

    func sendMCPAppMessage(sessionID: String, appID: String, text: String) async throws -> Bool {
        _ = try await performAuthenticated(allowFallback: false) { api in
            try await api.sendMCPAppMessage(sessionID: sessionID, appID: appID, text: text)
        }
        return true
    }

    func updateMCPAppContext(sessionID: String, appID: String, text: String?) async throws {
        try await performAuthenticated(allowFallback: false) { api in
            try await api.updateMCPAppContext(sessionID: sessionID, appID: appID, text: text)
        }
    }

    @discardableResult
    func cancelSubagent(sessionID: String, agentID: String) async throws -> Bool {
        let cancelled = try await performAuthenticated(allowFallback: false) { api in
            try await api.cancelSubagent(sessionID: sessionID, agentID: agentID)
        }
        guard selectedSessionID == sessionID else { return cancelled }
        do {
            let detail = try await performHistoryRead { api in
                try await api.session(id: sessionID)
            }
            guard selectedSessionID == sessionID else { return cancelled }
            apply(detail)
            detailError = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            detailError = "Could not update this conversation. \(error.localizedDescription)"
            handleReadFailure(error, detailOnly: true)
        }
        return cancelled
    }

    private func performHistoryRead<T>(
        _ operation: (CantripRemoteAPI) async throws -> T
    ) async throws -> T {
        guard let token else { throw CantripRemoteError.missingToken }
        let generation = configurationGeneration
        updateRoutes()
        // Large history downloads must not hold the polling/mutation request gate.
        let reader = router.independentReader()
        let result = try await reader.perform(readOnly: true) { transport in
            try await operation(CantripRemoteAPI(transport: transport, token: token, urlSession: urlSession))
        }
        try Task.checkCancellation()
        guard generation == configurationGeneration else { throw CancellationError() }
        return result
    }

    func modelSettings(id: String, refreshModels: Bool = false) async throws -> CantripModelSettings {
        try await performHistoryRead { try await $0.modelSettings(id: id, refreshModels: refreshModels) }
    }

    func updateModelSettings(id: String, change: CantripModelSettingsChange, identity: UUID) async -> Bool {
        guard identity == usageIdentity else {
            errorMessage = "The connected Mac changed. Reopen model settings before saving."
            return false
        }
        let result = await mutate(prepare: { api in
            try await api.prepareModelSettings(id: id, change: change)
        }, { api, body in
            try await api.updateModelSettings(id: id, body: body)
        })
        return result != nil
    }

    func privateLocalSettings(id: String) async throws -> CantripPrivateLocalSettings {
        try await performHistoryRead { try await $0.privateLocalSettings(id: id) }
    }

    /// The backend commands for "/" suggestions; never holds the polling/mutation gate.
    func fetchBackendCommands(sessionID: String) async throws -> BackendCommandsResponse {
        #if DEBUG
        if let fixture = CantripUITestFixtures.backendCommands { return fixture }
        #endif
        return try await performHistoryRead { try await $0.backendCommands(sessionID: sessionID) }
    }

    /// The selected session's cache identity for "/" suggestions, when its Mac lists backend commands.
    var slashCommandContext: BackendSlashCommandStore.Context? {
        guard let session = selectedSession, session.id == selectedSessionID,
              session.offersBackendCommands else { return nil }
        return BackendSlashCommandStore.Context(
            key: "\(usageIdentity.uuidString)/\(session.id)", sessionID: session.id,
            workdir: session.workdir, modelSettingsRevision: session.modelSettingsRevision
        )
    }

    /// Fetches the selected session's commands when the cache is missing, old or for another backend.
    func refreshSlashCommandsIfNeeded() {
        guard let context = slashCommandContext else { return }
        slashCommands.refreshIfNeeded(context) { [weak self] sessionID in
            guard let self else { throw CancellationError() }
            return try await self.fetchBackendCommands(sessionID: sessionID)
        }
    }

    func privateLocalModels(id: String, baseURL: String) async throws -> [String] {
        try await performHistoryRead { try await $0.privateLocalModels(id: id, baseURL: baseURL) }
    }

    func inputRequests(sessionID: String) async throws -> [CantripInputRequest] {
        try await performHistoryRead { try await $0.inputRequests(sessionID: sessionID) }
    }

    func showInputRequests(sessionID: String) async {
        await selectSession(sessionID)
        inputRequestsSession = nil
        notificationNavigationID = UUID()
    }

    func macAccess() async throws -> CantripMacAccess {
        try await performHistoryRead { try await $0.macAccess() }
    }

    func openMacSettings(_ permission: String, identity: UUID) async throws {
        guard usageIdentity == identity else { throw CancellationError() }
        let result: Bool? = await mutate(prepare: { api in _ = try await api.macAccess() }, { api, _ in
            try await api.openMacSettings(permission)
            return true
        })
        guard result == true else { throw ServerConfigurationError(message: errorMessage ?? "Settings could not be opened.") }
    }

    func startDesktop(control: Bool, identity: UUID) async throws -> CantripDesktopLease {
        guard usageIdentity == identity else { throw CancellationError() }
        try await authorizeSensitiveAction(control ? "Allow viewing and controlling your Mac for five minutes." : "Allow viewing your Mac screen for five minutes.")
        try Task.checkCancellation()
        guard usageIdentity == identity else { throw CancellationError() }
        let result = await mutate(prepare: { api in
            let status = try await api.macAccess()
            guard status.desktopEnabled else { throw ServerConfigurationError(message: "Enable View Mac in Cantrip settings on the Mac first.") }
        }, { api, _ in try await api.startDesktop(control: control) })
        guard let result else { throw ServerConfigurationError(message: errorMessage ?? "View Mac could not start. It may have reached the Mac; check before retrying.") }
        return result
    }

    func desktopFrame(lease: CantripDesktopLease, displayID: UInt32, identity: UUID) async throws -> CantripDesktopFrame {
        guard usageIdentity == identity else { throw CancellationError() }
        return try await performHistoryRead { try await $0.desktopFrame(lease: lease, displayID: displayID) }
    }

    func desktopInput(lease: CantripDesktopLease, sequence: Int, encrypted: String, identity: UUID) async throws {
        guard usageIdentity == identity else { throw CancellationError() }
        let result: Bool? = await mutate(prepare: { api in _ = try await api.macAccess() }, { api, _ in
            try await api.desktopInput(lease: lease, sequence: sequence, encrypted: encrypted)
            return true
        })
        guard result == true else { throw ServerConfigurationError(message: errorMessage ?? "Desktop input could not be confirmed.") }
    }

    func stopDesktop(lease: CantripDesktopLease, identity: UUID) async throws {
        guard usageIdentity == identity else { throw CancellationError() }
        // Stop is idempotent in effect, but still never replay keyboard/pointer commands.
        try await performHistoryRead { try await $0.stopDesktop(lease: lease) }
    }

    func respondToInput(sessionID: String, id: UUID, answer: CantripInputAnswer, identity: UUID,
                        questionOnly: Bool = false) async -> Bool {
        guard usageIdentity == identity else {
            errorMessage = "The connected Mac changed. Reopen the input request before responding."
            return false
        }
        if !questionOnly && (answer.decision == "approve" || answer.decision == "submit") {
            do {
                try await authorizeSensitiveAction("Confirm your response to the pending Cantrip request.")
                try Task.checkCancellation()
                guard usageIdentity == identity else { throw CancellationError() }
            } catch is CancellationError {
                errorMessage = "Authentication was cancelled or the connected Mac changed. Nothing was sent."
                return false
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        let accepted = await mutate(prepare: { api in
            try await api.prepareInput(sessionID: sessionID, id: id, answer: answer, questionOnly: questionOnly)
        }, { api, data in
            try await api.respondToInput(sessionID: sessionID, id: id, body: data)
        })
        return accepted == true
    }

    func updatePrivateLocalSettings(id: String, change: CantripPrivateLocalChange, identity: UUID) async -> Bool {
        guard identity == usageIdentity else {
            errorMessage = "The connected Mac changed. Reopen Private Local settings before saving."
            return false
        }
        let result = await mutate(prepare: { api in
            try await api.preparePrivateLocalSettings(id: id, change: change)
        }, { api, body in
            try await api.updatePrivateLocalSettings(id: id, body: body)
        })
        return result != nil
    }

    @discardableResult
    func createSession() async -> Bool {
        guard let session = await mutate({ api in
            try await api.createSession()
        }) else { return false }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        selectedSessionID = session.id
        apply(session)
        return true
    }

    /// Creates a project tab without opening it, so Cantrip Home can open it as a tab (selecting
    /// it here would show it in Home's place). Returns the new tab's ID.
    func createTab() async -> String? {
        guard let session = await mutate({ api in
            try await api.createSession()
        }) else { return nil }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        return session.id
    }

    @discardableResult
    func send(
        _ text: String,
        mode: CantripDeliveryMode,
        images: [ChatImageAttachment] = [],
        video: ChatVideoAttachment? = nil,
        files: [ChatFileAttachment] = [],
        sessionID: String? = nil
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty || video != nil || !files.isEmpty,
              let sessionID = sessionID ?? selectedSessionID else { return false }
        let question = mode == .auto && sessionID == selectedSessionID ? chatInputRequest : nil
        if let question, selectedSession?.supportsChatInputReplies != true {
            guard images.isEmpty, video == nil, files.isEmpty else {
                errorMessage = "Update and reopen Cantrip on the Mac to attach files to this chat reply."
                return false
            }
            return await respondToInput(sessionID: sessionID, id: question.id,
                answer: .init(decision: "submit", text: trimmed), identity: usageIdentity, questionOnly: true)
        }
        if video != nil || !files.isEmpty {
            guard await uploadAttachments(video: video, files: files, text: trimmed, mode: mode,
                                          images: images, sessionID: sessionID) else { return false }
        }
        guard let session = await mutate(prepare: { api in
            try await api.prepareMessage(trimmed, mode: mode, sessionID: sessionID, images: images,
                                         videoID: video?.id.uuidString, fileIDs: files.map(\.id.uuidString),
                                         inputRequestID: question?.id)
        }, { api, body in
            try await api.sendMessage(body, sessionID: sessionID)
        }) else { return false }
        guard selectedSessionID == sessionID else { return true }
        apply(session)
        return true
    }

    func cancelVideoUpload() { videoUploadTask?.cancel() }

    /// Uploads a send's video and files before its prompt. Chunks resume where the Mac left off
    /// and are verified there, so only these transfers retry; the prompt itself never does.
    private func uploadAttachments(video: ChatVideoAttachment?, files: [ChatFileAttachment], text: String,
                                   mode: CantripDeliveryMode, images: [ChatImageAttachment],
                                   sessionID: String) async -> Bool {
        guard !isMutating, !isUploadingVideo else {
            errorMessage = "Wait for the current request to finish."
            return false
        }
        let generation = configurationGeneration
        let subject = video != nil && !files.isEmpty ? "attachments"
            : video != nil ? "video" : files.count == 1 ? "file" : "files"
        let total = (video?.bytes ?? 0) + files.reduce(0) { $0 + $1.bytes }
        // An older Mac or a command prompt can't take this message: say so before uploading anything.
        do {
            _ = try await performHistoryRead {
                try await $0.prepareMessage(text, mode: mode, sessionID: sessionID, images: images,
                                            videoID: video?.id.uuidString, fileIDs: files.map(\.id.uuidString))
            }
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        guard !isMutating, !isUploadingVideo, generation == configurationGeneration else {
            errorMessage = "Wait for the current request to finish."
            return false
        }
        videoUploadProgress = VideoUploadProgress(fraction: 0, isPreparing: false, subject: subject)
        let task = Task {
            var uploaded = 0
            let report: (Int) -> Void = { offset in
                self.videoUploadProgress = VideoUploadProgress(
                    fraction: total > 0 ? Double(uploaded + offset) / Double(total) : 1,
                    isPreparing: false, subject: subject
                )
            }
            if let video {
                try await self.uploadChunks(
                    bytes: video.bytes, sha256: video.sha256,
                    status: { try await $0.videoStatus(sessionID: sessionID, uploadID: video.id) },
                    chunk: { try VideoAttachmentProcessor.chunk(video, offset: $0) },
                    put: { try await $0.uploadVideoChunk($1, video: video, sessionID: sessionID, offset: $2) },
                    progress: report
                )
                uploaded += video.bytes
            }
            for file in files {
                try await self.uploadChunks(
                    bytes: file.bytes, sha256: file.sha256,
                    status: { try await $0.fileStatus(sessionID: sessionID, uploadID: file.id) },
                    chunk: { try FileAttachmentProcessor.chunk(file, offset: $0) },
                    put: { try await $0.uploadFileChunk($1, file: file, sessionID: sessionID, offset: $2) },
                    progress: report
                )
                uploaded += file.bytes
            }
            if let video {
                self.videoUploadProgress = VideoUploadProgress(fraction: 1, isPreparing: true, subject: subject)
                try await self.performHistoryRead { try await $0.prepareVideo(sessionID: sessionID, uploadID: video.id) }
            }
            try Task.checkCancellation()
            guard generation == self.configurationGeneration else { throw CancellationError() }
        }
        videoUploadTask = task
        defer { videoUploadTask = nil; videoUploadProgress = nil }
        let what = subject == "video" ? "Video" : subject == "file" ? "The file" : "The \(subject)"
        do {
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            return true
        } catch is CancellationError {
            errorMessage = "Upload cancelled. No prompt was sent; your draft has been kept."
            return false
        } catch {
            errorMessage = "\(what) \(subject == "video" || subject == "file" ? "was" : "were") not sent. "
                + "\(error.localizedDescription) Retry to resume the upload."
            return false
        }
    }

    /// One resumable, verified chunked upload. Chunk PUTs check repeated bytes on the Mac.
    private func uploadChunks(
        bytes: Int, sha256: String,
        status: (CantripRemoteAPI) async throws -> CantripVideoUploadStatus?,
        chunk: @escaping @Sendable (Int) throws -> Data,
        put: (CantripRemoteAPI, Data, Int) async throws -> CantripVideoUploadStatus,
        progress: (Int) -> Void
    ) async throws {
        var offset = 0
        if let current = try await performHistoryRead({ try await status($0) }) {
            guard current.totalBytes == bytes, current.sha256 == sha256,
                  (0...bytes).contains(current.receivedBytes) else { throw CantripRemoteError.invalidResponse }
            offset = current.receivedBytes
        }
        while offset < bytes {
            try Task.checkCancellation()
            let start = offset
            let data = try await Task.detached(priority: .userInitiated) { try chunk(start) }.value
            let current = try await performHistoryRead { try await put($0, data, start) }
            guard current.totalBytes == bytes, current.sha256 == sha256,
                  current.receivedBytes >= start + data.count, current.receivedBytes <= bytes else {
                throw CantripRemoteError.invalidResponse
            }
            offset = current.receivedBytes
            progress(offset)
        }
    }

    @discardableResult
    func stop(sessionID: String) async -> Bool {
        guard !isMutating else {
            errorMessage = "Wait for the current request to finish, then try stopping again."
            return false
        }
        stoppingSessionID = sessionID
        defer { stoppingSessionID = nil }
        return await sessionAction("cancel", sessionID: sessionID)
    }

    @discardableResult
    func removeQueuedPrompt(_ id: String, sessionID: String) async -> Bool {
        guard !isMutating else {
            errorMessage = "Wait for the current request to finish, then try removing the message again."
            return false
        }
        guard let session = await mutate(prepare: { api in
            try await api.prepareQueueRemoval(sessionID: sessionID)
        }, { api, _ in
            try await api.deleteQueuedPrompt(id: id, sessionID: sessionID)
        }) else { return false }
        guard selectedSessionID == sessionID else { return true }
        apply(session)
        return true
    }

    /// Delivers a queued message into the current turn now, or starts it if the tab is idle.
    @discardableResult
    func sendQueuedPromptNow(_ id: String, sessionID: String) async -> Bool {
        guard !isMutating else {
            errorMessage = "Wait for the current request to finish, then try sending the message again."
            return false
        }
        sendingQueuedPromptID = id
        defer { sendingQueuedPromptID = nil }
        guard let session = await mutate(prepare: { api in
            try await api.prepareQueueSendNow(sessionID: sessionID)
        }, { api, _ in
            try await api.postQueuedPromptNow(id: id, sessionID: sessionID)
        }) else { return false }
        guard selectedSessionID == sessionID else { return true }
        apply(session)
        return true
    }

    /// The tab's next prompt starts a new model session. Its title, folder, settings, lock and
    /// visible history stay; the Mac adds a divider so earlier messages read as not sent.
    @discardableResult
    func startFresh(sessionID: String) async -> Bool {
        guard !isMutating else {
            errorMessage = "Wait for the current request to finish, then try starting fresh again."
            return false
        }
        guard let session = await mutate(prepare: { api in
            try await api.prepareStartFresh(sessionID: sessionID)
        }, { api, _ in
            try await api.postStartFresh(sessionID: sessionID)
        }) else { return false }
        if selectedSessionID == sessionID {
            apply(session)
        } else if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[index] = session
        }
        return true
    }

    @discardableResult
    func resume() async -> Bool {
        await sessionAction("resume")
    }

    @discardableResult
    func newConversation() async -> Bool {
        await sessionAction("new-conversation")
    }

    @discardableResult
    func closeSession(_ id: String) async -> Bool {
        guard sessions.contains(where: { $0.id == id }) else { return false }
        guard sessions.first(where: { $0.id == id })?.isLocked != true else {
            errorMessage = ChatTabError.locked.localizedDescription
            return false
        }
        guard let replacement = await mutate(sessionID: id, { api in
            try await api.closeSession(id: id)
        }) else { return false }

        sessions.removeAll { $0.id == id }
        if let index = sessions.firstIndex(where: { $0.id == replacement.id }) {
            sessions[index] = replacement
        } else {
            sessions.append(replacement)
        }

        if selectedSessionID == id {
            selectedSessionID = replacement.id
            apply(replacement)
        }
        return true
    }

    @discardableResult
    func updateTab(_ id: String, name: String? = nil, isLocked: Bool? = nil) async -> Bool {
        guard !isMutating else {
            errorMessage = "Wait for the current request to finish before editing this tab."
            return false
        }
        guard let session = await mutate(prepare: { api in
            try await api.prepareTabUpdate(id: id, name: name, isLocked: isLocked)
        }, { api, body in
            try await api.updateTab(id: id, body: body)
        }) else { return false }
        if selectedSessionID == id {
            apply(session)
        } else if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index] = session
        }
        return true
    }

    private func sessionAction(_ action: String, sessionID: String? = nil) async -> Bool {
        guard let sessionID = sessionID ?? selectedSessionID else { return false }
        guard action != "new-conversation" || selectedSession?.isLocked != true else {
            errorMessage = ChatTabError.locked.localizedDescription
            return false
        }
        guard let session = await mutate(sessionID: sessionID, { api in
            try await api.action(action, sessionID: sessionID)
        }) else { return false }
        if selectedSessionID == sessionID {
            apply(session)
        } else if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[index] = session
        }
        return true
    }

    @discardableResult
    func moveTab(_ id: String, relativeTo targetID: String, after: Bool) async -> Bool {
        guard !isMutating else {
            errorMessage = "Wait for the current request to finish before reordering tabs."
            return false
        }
        guard let source = sessions.firstIndex(where: { $0.id == id }),
              let target = sessions.firstIndex(where: { $0.id == targetID }) else {
            errorMessage = "A tab is no longer open. Refresh the tabs and try again."
            return false
        }
        guard id != targetID else { return true }
        let previousOrder = sessions
        isReorderingTabs = true
        defer { isReorderingTabs = false }
        var preview = sessions
        let moved = preview.remove(at: source)
        preview.insert(moved, at: target - (source < target ? 1 : 0) + (after ? 1 : 0))
        sessions = preview
        guard let reordered = await mutate(prepare: { api in
            try await api.prepareTabMove(id: id, targetID: targetID, after: after)
        }, { api, body in
            try await api.moveTab(id: id, body: body)
        }) else {
            sessions = previousOrder
            return false
        }
        // A list response has no transcript. Keep the selected detail and draft mounted.
        sessions = reordered
        return true
    }

    @discardableResult
    func moveTab(_ id: String, offset: Int) async -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              [-1, 1].contains(offset), sessions.indices.contains(index + offset) else {
            errorMessage = "The tab cannot move farther in that direction. Refresh the tabs and try again."
            return false
        }
        return await moveTab(id, relativeTo: sessions[index + offset].id, after: offset > 0)
    }

    // MARK: Tab sections

    /// Where this device's collapsed sections are kept: per paired Mac.
    var tabSectionScope: String { selectedServerID?.uuidString ?? usageIdentity.uuidString }

    /// Adds a section and, when `tabID` is given, files that tab in it.
    @discardableResult
    func createSection(named name: String, filing tabID: String? = nil) async -> Bool {
        // Like a reorder: the tab drawer stays open while the Mac saves it.
        isReorderingTabs = true
        defer { isReorderingTabs = false }
        guard let response = await mutate(prepare: { api in try await api.requireTabSections() }, { api, _ in
            let created = try await api.createSection(name: name)
            if let tabID, let section = created.section { _ = try await api.fileTab(id: tabID, sectionID: section.id) }
            return created
        }) else { return false }
        tabSections = response.sections
        await refreshNow()
        return true
    }

    @discardableResult
    func renameSection(_ id: String, to name: String) async -> Bool {
        // Like a reorder: the tab drawer stays open while the Mac saves it.
        isReorderingTabs = true
        defer { isReorderingTabs = false }
        guard let response = await mutate(prepare: { api in try await api.requireTabSections() }, { api, _ in
            try await api.updateSection(id: id, name: name)
        }) else { return false }
        tabSections = response.sections
        return true
    }

    /// Moves a section up (-1) or down (1) among the sections.
    @discardableResult
    func moveSection(_ id: String, offset: Int) async -> Bool {
        guard let index = tabSections.firstIndex(where: { $0.id == id }),
              tabSections.indices.contains(index + offset) else { return false }
        isReorderingTabs = true
        defer { isReorderingTabs = false }
        guard let response = await mutate(prepare: { api in try await api.requireTabSections() }, { api, _ in
            try await api.updateSection(id: id, position: index + offset)
        }) else { return false }
        tabSections = response.sections
        return true
    }

    /// Deletes a section; its tabs go back to Tabs.
    @discardableResult
    func deleteSection(_ id: String) async -> Bool {
        // Like a reorder: the tab drawer stays open while the Mac saves it.
        isReorderingTabs = true
        defer { isReorderingTabs = false }
        guard let response = await mutate(prepare: { api in try await api.requireTabSections() }, { api, _ in
            try await api.deleteSection(id: id)
        }) else { return false }
        tabSections = response.sections
        await refreshNow()
        return true
    }

    /// Files a tab under a section (nil: Tabs). The Mac puts it after the section's last tab.
    @discardableResult
    func fileTab(_ id: String, in sectionID: String?) async -> Bool {
        // Like a reorder: the tab drawer stays open while the Mac saves it.
        isReorderingTabs = true
        defer { isReorderingTabs = false }
        guard await mutate(prepare: { api in try await api.requireTabSections() }, { api, _ in
            try await api.fileTab(id: id, sectionID: sectionID)
        }) != nil else { return false }
        if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].sectionID = sectionID }
        await refreshNow()
        return true
    }

    /// A new tab filed under a section, not opened (callers open it). Returns its ID.
    func createTab(inSection sectionID: String) async -> String? {
        guard let session = await mutate(prepare: { api in try await api.requireTabSections() }, { api, _ in
            try await api.createSession(sectionID: sectionID)
        }) else { return nil }
        if !sessions.contains(where: { $0.id == session.id }) { sessions.append(session) }
        return session.id
    }

    private func mutate<T>(
        sessionID: String? = nil,
        _ operation: @escaping (CantripRemoteAPI) async throws -> T
    ) async -> T? {
        await mutate(prepare: { api in
            if let sessionID {
                _ = try await api.session(id: sessionID)
            } else {
                _ = try await api.sessions()
            }
        }, { api, _ in
            try await operation(api)
        })
    }

    private func mutate<Prepared, T>(
        prepare: @escaping (CantripRemoteAPI) async throws -> Prepared,
        _ operation: @escaping (CantripRemoteAPI, Prepared) async throws -> T
    ) async -> T? {
        guard !isMutating, !isUploadingVideo else {
            errorMessage = "Wait for the current request to finish."
            return nil
        }
        mutationRevision += 1
        isMutating = true
        defer { isMutating = false }
        do {
            guard let token else { throw CantripRemoteError.missingToken }
            let generation = configurationGeneration
            let result = try await requestGate.withLock {
                guard generation == self.configurationGeneration else { throw CancellationError() }
                self.updateRoutes()
                return try await self.router.performMutation(prepare: { transport in
                    try await prepare(CantripRemoteAPI(
                        transport: transport, token: token, urlSession: self.urlSession
                    ))
                }, operation: { transport, prepared in
                    try await operation(CantripRemoteAPI(
                        transport: transport, token: token, urlSession: self.urlSession
                    ), prepared)
                })
            }
            try Task.checkCancellation()
            guard generation == configurationGeneration else { throw CancellationError() }
            activeTransport = router.preferred
            markAuthenticatedSuccess()
            errorMessage = nil
            return result
        } catch is CancellationError {
            return nil
        } catch {
            if shouldDisconnect(for: error) {
                markDisconnected()
            }
            errorMessage = error.localizedDescription
            if CantripRemoteError.isRouteFailure(error) {
                errorMessage = "\(error.localizedDescription) The request may have reached Cantrip. Check the session before sending again."
            }
            return nil
        }
    }

    private func refresh() async {
        guard appIsActive, isConfigured, !isRefreshing, !isMutating else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let requestedID = selectedSessionID
        let revision = mutationRevision
        let selection = selectionRevision
        do {
            let generation = configurationGeneration
            let listing = try await performAuthenticated(allowFallback: true) { api in
                try await api.sessionListing()
            }
            let listed = listing.sessions
            guard generation == configurationGeneration else { throw CancellationError() }
            guard revision == mutationRevision else { return }
            sessions = listed
            if homeSummary != listing.home { homeSummary = listing.home }
            let sections = listing.sections ?? []
            if tabSections != sections { tabSections = sections }
            if supportsTabSections != (listing.supportsTabSections == true) {
                supportsTabSections = listing.supportsTabSections == true
            }
            errorMessage = nil
            syncLiveStatusPairing()
            liveStatus?.refreshIfDue(anyStreaming: listed.contains { $0.isStreaming }
                                    || selectedSession?.isStreaming == true)
            var publicIDs = Set(listed.map(\.id))
            if isHomeSelected, let selectedSessionID { publicIDs.insert(selectedSessionID) }
            if !isHomeSelected, let unlistedSessionID, unlistedSessionID == selectedSessionID {
                publicIDs.insert(unlistedSessionID)
            }
            detailCache = detailCache.filter { publicIDs.contains($0.key) }
            cacheOrder.removeAll { !publicIDs.contains($0) }
            expandedHistory.formIntersection(publicIDs)
            if olderHistoryFailures.keys.contains(where: { !publicIDs.contains($0) }) {
                olderHistoryFailures = olderHistoryFailures.filter { publicIDs.contains($0.key) }
            }
            guard selection == selectionRevision else { return }
            if isHomeSelected,
               requestedID == nil || selectedSession?.isCantripHome != true {
                await selectHome()
                recoverTailscale()
                return
            }
            let chosenID = isHomeSelected ? requestedID : requestedID.flatMap { id in
                listed.contains(where: { $0.id == id }) || id == unlistedSessionID ? id : nil
            } ?? listed.first?.id
            selectedSessionID = chosenID
            if !isHomeSelected { regularSelectedSessionID = chosenID }
            if selectedSession?.id != chosenID {
                selectedSession = chosenID.flatMap { detailCache[$0] }
                transcriptRevision += 1
            }
            if let chosenID, selectingSessionID == chosenID {
                if isHomeSelected { await refreshHomeData() }
                recoverTailscale()
                return
            }
            if let chosenID {
                let cachedRevision = selectedSession?.historyRevision
                let listedRevision = listed.first { $0.id == chosenID }?.historyRevision
                if let cachedRevision, cachedRevision == listedRevision {
                    detailError = nil
                } else {
                    let key = "\(generation):\(revision):\(selection):\(chosenID)"
                    if detailRefreshKey != key {
                        cancelDetailRefresh()
                        detailRefreshKey = key
                        let requestID = detailRefreshID
                        detailRefreshTask = Task { [weak self] in
                            guard let self else { return }
                            defer {
                                if self.detailRefreshID == requestID {
                                    self.detailRefreshTask = nil
                                    self.detailRefreshKey = nil
                                }
                            }
                            do {
                                let detail = try await self.performHistoryRead { api in
                                    try await api.sessionUpdate(id: chosenID, revision: cachedRevision)
                                }
                                guard !Task.isCancelled, generation == self.configurationGeneration,
                                      revision == self.mutationRevision, selection == self.selectionRevision,
                                      self.selectedSessionID == chosenID else { return }
                                if let detail { self.apply(detail) }
                                self.detailError = nil
                            } catch is CancellationError {
                                return
                            } catch {
                                guard self.detailRefreshID == requestID,
                                      generation == self.configurationGeneration,
                                      revision == self.mutationRevision, selection == self.selectionRevision,
                                      self.selectedSessionID == chosenID else { return }
                                if case CantripRemoteError.http(404, _) = error, chosenID == self.unlistedSessionID {
                                    // A finished background run's session is gone; its report is in Home.
                                    self.unlistedSessionID = nil
                                    self.detailError = "This background run has finished. Its report is in Home's Background list."
                                    return
                                }
                                self.detailError = "Could not update this conversation. \(error.localizedDescription)"
                                self.handleReadFailure(error, detailOnly: true)
                            }
                        }
                    }
                }
            } else {
                cancelDetailRefresh()
                detailError = nil
            }
            if isHomeSelected { await refreshHomeData() }
            recoverTailscale()
        } catch is CancellationError {
            return
        } catch {
            guard revision == mutationRevision, selection == selectionRevision else { return }
            errorMessage = error.localizedDescription
            handleReadFailure(error, detailOnly: false)
        }
    }

    private func cancelDetailRefresh() {
        detailRefreshTask?.cancel()
        detailRefreshTask = nil
        detailRefreshKey = nil
        detailRefreshID = UUID()
    }

    private func performAuthenticated<T>(
        allowFallback: Bool,
        _ operation: @escaping (CantripRemoteAPI) async throws -> T
    ) async throws -> T {
        guard let token else {
            throw CantripRemoteError.missingToken
        }
        let generation = configurationGeneration
        let result = try await requestGate.withLock {
            try await self.performRouted(
                generation: generation, token: token,
                allowFallback: allowFallback, operation: operation
            )
        }
        try Task.checkCancellation()
        guard generation == configurationGeneration else { throw CancellationError() }
        activeTransport = router.preferred
        markAuthenticatedSuccess()
        return result
    }

    private func performRouted<T>(
        generation: Int,
        token: String,
        allowFallback: Bool,
        operation: (CantripRemoteAPI) async throws -> T
    ) async throws -> T {
        guard generation == configurationGeneration else { throw CancellationError() }
        updateRoutes()
        return try await router.perform(readOnly: allowFallback) { transport in
            let api = CantripRemoteAPI(transport: transport, token: token, urlSession: self.urlSession)
            return try await operation(api)
        }
    }

    /// Tailscale URL first, then Bonjour peers on this network, then the saved direct address
    /// (an explicit choice, so Tailscale-only mode keeps it; it only skips Bonjour discovery).
    private func updateRoutes() {
        let discovered = tailscaleOnly ? [] : lanEndpoints.filter { $0 != directEndpoint }
        router.available = (baseURL.map { [.remote($0)] } ?? [])
            + discovered.map(CantripTransport.lan)
            + (directEndpoint.map { [.lan($0)] } ?? [])
    }

    private func recoverTailscale() {
        // Tailscale-only skips Bonjour but keeps a saved direct address, which can become preferred.
        guard appIsActive, let token, !tailscaleOnly || directEndpoint != nil else { return }
        router.recoverTailscale { [urlSession] transport in
            _ = try await CantripRemoteAPI(
                transport: transport, token: token, urlSession: urlSession
            ).sessions()
        }
    }

    private func apply(_ incoming: CantripRemoteSession, mergeHistory: Bool = true) {
        var session = incoming
        if detailCache[session.id]?.historyStartID != session.historyStartID {
            expandedHistory.remove(session.id)
            olderHistoryFailures.removeValue(forKey: session.id)
        }
        if mergeHistory, let previous = detailCache[session.id],
           let start = session.historyStartID, start == previous.historyStartID,
           let first = session.transcript.first?.id,
           let overlap = previous.transcript.firstIndex(where: { $0.id == first }) {
            session.messages = Array(previous.transcript.prefix(overlap)) + session.transcript
            session.hasOlderMessages = previous.hasOlderMessages
        }
        if !expandedHistory.contains(session.id), session.supportsPagedHistory == true {
            let bounded = Self.historySuffix(session.transcript, groups: CantripHistoryWindow.recentExchanges)
            if bounded.count < session.transcript.count {
                session.messages = bounded
                session.hasOlderMessages = true
            }
        }
        if !expandedHistory.contains(session.id), session.supportsPagedHistory == true,
           session.transcript.count > 120, !session.transcript.contains(where: { $0.role == "user" }) {
            session.messages = Array(session.transcript.suffix(120))
            session.hasOlderMessages = true
        }
        detailCache[session.id] = session
        cacheOrder.removeAll { $0 == session.id }
        cacheOrder.append(session.id)
        while cacheOrder.count > 5 {
            let removed = cacheOrder.removeFirst()
            detailCache.removeValue(forKey: removed)
            expandedHistory.remove(removed)
            olderHistoryFailures.removeValue(forKey: removed)
        }
        if selectedSession != session {
            selectedSession = session
            transcriptRevision += 1
        }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        }
    }

    private static func historySuffix(_ messages: [CantripRemoteMessage], groups: Int) -> [CantripRemoteMessage] {
        guard groups > 0 else { return [] }
        let prompts = messages.indices.filter { messages[$0].role == "user" }
        guard prompts.count > groups else { return messages }
        return Array(messages[prompts[prompts.count - groups]...])
    }

    private func startPolling() {
        guard appIsActive, isConfigured, pollingTask == nil else {
            if !isConfigured { markDisconnected() }
            return
        }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                // Re-reads the delay while waiting, so selecting a busy tab or bringing the Mac
                // app forward shortens a slow wait instead of finishing it.
                let started = ContinuousClock.now
                do {
                    while ContinuousClock.now - started < self.pollDelay {
                        try await Task.sleep(for: .milliseconds(250))
                    }
                } catch {
                    return
                }
            }
        }
    }

    private func startLANDiscovery() {
        guard let token, !tailscaleOnly else {
            lanBrowser.stop()
            updateLANEndpoints([])
            return
        }
        updateLANEndpoints([])
        lanBrowser.onEndpointsChanged = { [weak self] endpoints in
            guard let self, self.token == token else { return }
            self.updateLANEndpoints(endpoints)
        }
        lanBrowser.start(token: token)
    }

    private func updateLANEndpoints(_ endpoints: [NWEndpoint]) {
        guard endpoints != lanEndpoints else { return }
        lanEndpoints = endpoints
        isLocalNetworkAvailable = !endpoints.isEmpty
        updateRoutes()
        if case .lan(let endpoint) = activeTransport,
           endpoint != directEndpoint, !endpoints.contains(endpoint) {
            activeTransport = nil
            markDisconnected()
        }
        if appIsActive {
            startPolling()
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        cancelDetailRefresh()
        staleTask?.cancel()
        staleTask = nil
        router.cancelProbe()
        markDisconnected()
    }

    private func markAuthenticatedSuccess() {
        guard appIsActive, pollingTask != nil else {
            markDisconnected()
            return
        }
        let completedAt = Date()
        lastAuthenticatedAt = completedAt
        connectionState = .connected
        refreshCompletionNotificationRegistration()
        staleTask?.cancel()
        staleTask = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self, self.lastAuthenticatedAt == completedAt else { return }
                // Measured against the current poll interval, so switching the Mac app to the
                // background (15 s polls) never reads as a lost connection between polls.
                let elapsed = Duration.seconds(Date().timeIntervalSince(completedAt))
                if elapsed >= max(Self.staleInterval, self.pollDelay + .seconds(5)) {
                    self.markDisconnected()
                    return
                }
            }
        }
    }

    private func markDisconnected() {
        connectionState = .disconnected
    }

    private func resetHistory() {
        cancelDetailRefresh()
        detailCache.removeAll()
        cacheOrder.removeAll()
        expandedHistory.removeAll()
        olderHistoryFailures.removeAll()
        unlistedSessionID = nil
        detailError = nil
        selectionRevision += 1
        selectingSessionID = nil
        historyPrependAnchor = nil
    }

    private func handleReadFailure(_ error: Error, detailOnly: Bool) {
        if case CantripRemoteError.authentication = error {
            markDisconnected()
        } else if !detailOnly, CantripRemoteError.isRouteFailure(error) {
            connectionState = .reconnecting
        }
    }

    private func shouldDisconnect(for error: Error) -> Bool {
        if CantripRemoteError.isRouteFailure(error) { return true }
        switch error {
        case is CancellationError:
            return false
        case CantripRemoteError.http:
            return false
        case CantripRemoteError.imagesUnsupported, CantripRemoteError.videosUnsupported, CantripRemoteError.queueRemovalUnsupported,
             CantripRemoteError.queueSendNowUnsupported, CantripRemoteError.startFreshUnsupported,
             CantripRemoteError.autoDeliveryUnsupported, CantripRemoteError.tabMetadataUnsupported,
             CantripRemoteError.tabReorderingUnsupported,
             is ImageAttachmentError, is VideoAttachmentError:
            return false
        default:
            return true
        }
    }

    static func normalizedBaseURL(_ rawValue: String) throws -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            throw CantripRemoteError.invalidURL("Enter a valid HTTPS URL.")
        }
        guard components.user == nil, components.password == nil else {
            throw CantripRemoteError.invalidURL("The Remote URL cannot contain a username or password.")
        }
        guard components.query == nil, components.fragment == nil else {
            throw CantripRemoteError.invalidURL("The Remote URL cannot contain a query string or fragment.")
        }
        guard components.path.isEmpty || components.path == "/" else {
            throw CantripRemoteError.invalidURL("Use the Cantrip server origin without an extra path.")
        }

        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw CantripRemoteError.invalidURL(
                "Use HTTPS. HTTP is allowed only for localhost, 127.0.0.1, or ::1 development."
            )
        }

        components.scheme = scheme
        components.host = host
        if components.port == (scheme == "https" ? 443 : 80) { components.port = nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw CantripRemoteError.invalidURL("Enter a valid HTTPS URL.")
        }
        return url
    }
}

struct CantripRemoteView: View {
    @EnvironmentObject private var model: CantripRemoteModel
    @State private var showSettings = false
    @State private var showCantripMaintenance = false
    @State private var draft = ""
    @State private var deliveryMode: CantripDeliveryMode = .auto
    @State private var renamingSession: CantripRemoteSession?
    @State private var showTabs = false
    @State private var chatAvailableHeight: CGFloat = 600
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if model.isConfigured {
                    remoteContent
                } else {
                    CantripRemoteSetupView(model: model)
                }
            }
            .navigationTitle("Remote")
            .modifier(ChatNavigationActions(
                showsHorizontalBar: true,
                leading: {
                    ChatTabsButton(isEnabled: model.isConfigured && !model.isMutating) {
                        showTabs = true
                    }
                }, refresh: {}, settings: {
                    ChatSettingsButton { showSettings = true }
                }, trailing: {
                    StableMenu(state: model.isConfigured) {
                        if model.isConfigured {
                            CantripLiveActivityToggle()
                        }
                        CantripMacMenuActions(remote: model, showingMaintenance: $showCantripMaintenance) {
                            composerFocused = false
                        }
                        Button { showSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        ChatMenuIcon()
                    }
                    .equatable()
                    .accessibilityLabel("Remote menu")
                }
            ))
            .sheet(isPresented: $showSettings) {
                CantripRemoteSettingsSheet(model: model)
            }
            .sheet(item: $renamingSession) { session in
                CantripTabRenameSheet(model: model, session: session)
            }
            .sheet(item: $model.modelSettingsSession) { session in
                CantripSessionSettingsView(model: model, session: session, identity: model.usageIdentity)
            }
            .sheet(item: $model.inputRequestsSession) { session in
                CantripInputRequestsView(model: model, session: session)
            }
            .sheet(isPresented: $model.showingMacAccess) {
                NavigationStack { CantripMacAccessView(remote: model) }
            }
            .sheet(isPresented: $showCantripMaintenance) {
                CantripMaintenanceSheet(remote: model)
            }
        }
        .cantripTabDrawer(
            isPresented: $showTabs,
            isEnabled: model.isConfigured && (!model.isMutating || model.isReorderingTabs)
        ) {
            CantripSessionDrawer(
                model: model,
                onDismiss: { showTabs = false },
                onSelect: { id in Task { await model.selectSession(id) } },
                onCreate: { Task { await model.createSession() } },
                onRename: { renamingSession = $0 },
                onClose: { id in Task { await model.closeSession(id) } }
            )
        }
        .onChange(of: showTabs) { _, showing in
            if showing { composerFocused = false }
        }
        .modifier(ChatDisplayObserver())
    }

    private var remoteContent: some View {
        VStack(spacing: 0) {
            connectionBanner
            CantripDetailNotice(model: model)
                .padding(.horizontal)
            Divider()
            sessionPicker
            Divider()
            if model.selectedSession != nil {
                sessionControls
                Divider()
                CantripRemoteTranscript(model: model)
                Divider()
                composer
            } else {
                ContentUnavailableView {
                    Label("No Remote Sessions", systemImage: "rectangle.stack.badge.plus")
                } description: {
                    Text("Create a session in Cantrip or start one here.")
                } actions: {
                    Button("Create Session") {
                        Task { await model.createSession() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isMutating)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
            chatAvailableHeight = $0
        }
    }

    private var connectionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle()
                    .fill(model.isConnected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(model.connectionLabel)
                    .font(.caption.weight(.semibold))
                Text(model.endpointHost)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await model.refreshNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh Remote")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.connectionLabel)

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var sessionPicker: some View {
        CantripSessionBar(
            sessions: model.sessions,
            selectedSessionID: model.selectedSessionID,
            deliveryMode: $deliveryMode,
            isMutating: model.isMutating
        ) {
            showTabs = true
        } actions: {
            if let session = model.selectedSession {
                sessionActions(session)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func sessionActions(_ session: CantripRemoteSession) -> some View {
        CantripTabActions(model: model, session: session,
            onRename: { renamingSession = session },
            onClose: { Task { await model.closeSession(session.id) } })
    }

    private var sessionControls: some View {
        HStack(spacing: 12) {
            if let session = model.selectedSession {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.status ?? (session.isStreaming ? "Working…" : "Ready"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if session.queuedCount > 0 {
                        Text("\(session.queuedCount) queued")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if session.canResume {
                    Button("Resume") {
                        Task { await model.resume() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isMutating)
                }
                Button {
                    Task { await model.newConversation() }
                } label: {
                    Label("New", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .disabled(session.isStreaming || model.isMutating || session.isLocked == true)
                .accessibilityLabel("Start new conversation")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let status = model.selectedSession?.deliveryStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ChatComposer {
                EmptyView()
            } message: {
                TextField(CantripInputComposer.placeholder(for: model.chatInputRequest, mode: deliveryMode),
                          text: $draft, axis: .vertical)
                    .focused($composerFocused)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(model.isMutating || !composerAcceptsText)
                    .submitLabel(.send)
                    .onSubmit { submit() }
            } trailing: {
                CantripStopButton(
                    session: model.selectedSession,
                    isConnected: model.isConnected,
                    isMutating: model.isMutating,
                    isStopping: model.stoppingSessionID != nil
                        && model.stoppingSessionID == model.selectedSessionID,
                    iconOnly: true
                ) { id in
                    Task { await model.stop(sessionID: id) }
                }
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .disabled(
                    model.isMutating
                        || !composerAcceptsText
                        || model.selectedSessionID == nil
                        || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityLabel(deliveryMode == .auto && model.chatInputRequest != nil ? "Send reply" : "Send prompt")
            } accessory: {
                CantripInputComposer(
                    model: model, deliveryMode: deliveryMode,
                    maxHeight: min(320, max(72, chatAvailableHeight * 0.45))
                )
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var composerAcceptsText: Bool {
        CantripInputComposer.acceptsText(for: model.chatInputRequest, mode: deliveryMode)
    }

    private func submit() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, composerAcceptsText, !model.isMutating else { return }
        Task {
            if await model.send(prompt, mode: deliveryMode) {
                draft = ""
                deliveryMode = .auto
            }
        }
    }
}

private struct CantripRemoteTranscript: View {
    @ObservedObject var model: CantripRemoteModel
    @State private var followsBottom = true
    @State private var userIsScrolling = false
    @State private var scrollPhase = ScrollPhase.idle
    @State private var scrollPosition = ScrollPosition(idType: String.self, edge: .bottom)
    @State private var prependAnchor = HistoryPrependAnchor()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                CantripHistoryControls(model: model)
                ForEach(model.selectedSession?.transcript ?? []) { message in
                    CantripRemoteMessageBubble(
                        message: message, model: model, sessionID: model.selectedSession?.id ?? ""
                    )
                        .id(message.id)
                    if message.isPreview == true {
                        CantripMessageDetailsButton(model: model, message: message,
                                                    sessionID: model.selectedSession?.id ?? "")
                    }
                }
                CantripInputTranscript(model: model)
                Color.clear
                    .frame(height: 1)
                    .id("remote-transcript-bottom")
            }
            .scrollTargetLayout()
            .padding()
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .onUpwardHistoryScroll(prependRevision: model.historyPrependRevision) {
            model.requestOlderMessages()
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height - geometry.visibleRect.maxY < 72
        } action: { _, isNearBottom in
            if userIsScrolling {
                followsBottom = isNearBottom
            }
        }
        .onScrollPhaseChange { oldPhase, newPhase, context in
            let endedUserScroll = newPhase == .idle
                && (oldPhase == .tracking
                    || oldPhase == .interacting
                    || oldPhase == .decelerating)
            userIsScrolling = newPhase == .tracking
                || newPhase == .interacting
                || newPhase == .decelerating
            scrollPhase = newPhase
            if newPhase == .idle, model.historyPrependAnchor != nil {
                let settled = HistoryScrollGeometry(context.geometry, prependRevision: model.historyPrependRevision)
                if let target = prependAnchor.target(previous: settled, current: settled, userIsScrolling: false) {
                    scrollPosition.scrollTo(y: target)
                }
            }
            if endedUserScroll {
                followsBottom = context.geometry.contentSize.height
                    - context.geometry.visibleRect.maxY < 72
            }
        }
        .onChange(of: model.selectedSessionID) { _, _ in
            followsBottom = true
            scrollPosition.scrollTo(edge: .bottom)
        }
        .onChange(of: model.transcriptRevision) { _, _ in
            guard followsBottom, !model.isLoadingHistory else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        .onScrollGeometryChange(for: HistoryScrollGeometry.self) { geometry in
            HistoryScrollGeometry(geometry, prependRevision: model.historyPrependRevision)
        } action: { previous, current in
            guard model.historyPrependAnchor != nil,
                  let target = prependAnchor.target(previous: previous, current: current,
                                                    userIsScrolling: scrollPhase.isFingerDriven,
                                                    momentum: scrollPhase.isMomentum) else { return }
            followsBottom = false
            scrollPosition.scrollTo(y: target)
        }
    }
}

/// Top-of-transcript status for paged history. Older pages load automatically while
/// scrolling, so this only shows progress, or a retry after a failed page.
struct CantripHistoryControls: View {
    @ObservedObject var model: CantripRemoteModel
    @AccessibilityFocusState private var accessibilityFocused: Bool

    var body: some View {
        if model.selectedSession?.supportsPagedHistory == true {
            let hasOlder = model.selectedSession?.hasOlderMessages == true
            Group {
                if let error = model.olderHistoryError {
                    HStack(spacing: 12) {
                        // A retry shows progress in place, keeping Retry where it was.
                        Group {
                            if model.isLoadingHistory {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Loading older messages…")
                                }
                            } else {
                                Text(error)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(CantripReasoningFormat.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Retry") { Task { await model.loadOlderMessages() } }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                            .disabled(model.isLoadingHistory || model.isMutating)
                            .accessibilityLabel("Retry loading older messages")
                            .accessibilityIdentifier("cantrip.retryOlderMessages")
                    }
                } else {
                    // Always laid out while history is paged, so showing or hiding progress
                    // (or reaching the start) never shifts the messages being read.
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading older messages…")
                    }
                    .font(.caption)
                    .foregroundStyle(CantripReasoningFormat.secondaryText)
                    .opacity(hasOlder && model.isLoadingHistory ? 1 : 0)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(model.isLoadingHistory ? "Loading older messages" : "Earlier messages")
                    .accessibilityHint("Older messages load automatically.")
                    .accessibilityAction { model.requestOlderMessages() }
                    .accessibilityFocused($accessibilityFocused)
                    .accessibilityHidden(!hasOlder)
                    .accessibilityIdentifier("cantrip.olderMessagesStatus")
                }
            }
            // VoiceOver readers reaching the top get the next page without an extra action.
            .onChange(of: accessibilityFocused) { _, focused in
                if focused { model.requestOlderMessages() }
            }
        }
    }
}

struct CantripDetailNotice: View {
    @ObservedObject var model: CantripRemoteModel

    var body: some View {
        if let error = model.detailError {
            VStack(alignment: .leading, spacing: 6) {
                Text(error).font(.caption).foregroundStyle(.orange)
                Button("Retry conversation") { Task { await model.refreshNow() } }
                    .font(.caption)
                    .disabled(model.isRefreshing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CantripMessageDetailsButton: View {
    @ObservedObject var model: CantripRemoteModel
    let message: CantripRemoteMessage
    let sessionID: String
    @State private var presented = false

    var body: some View {
        Button("Load full message and details") { presented = true }
            .font(.caption)
            .sheet(isPresented: $presented) {
                CantripMessageDetails(model: model, sessionID: sessionID, messageID: message.id)
            }
            .onChange(of: model.usageIdentity) { _, _ in presented = false }
    }
}

private struct CantripMessageDetails: View {
    @ObservedObject var model: CantripRemoteModel
    let sessionID: String
    let messageID: String
    @Environment(\.dismiss) private var dismiss
    @State private var message: CantripRemoteMessage?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                if let message {
                    CantripRemoteMessageBubble(message: message, model: model, sessionID: sessionID)
                        .padding()
                } else if let error {
                    VStack(spacing: 12) {
                        Text(error)
                        Button("Retry") { attempt += 1 }
                    }.padding()
                } else {
                    ProgressView("Loading full message...").padding()
                }
            }
            .navigationTitle("Message details")
            .toolbar { Button("Done") { dismiss() } }
            .task(id: attempt) {
                error = nil
                do {
                    message = try await model.fullMessage(sessionID: sessionID, messageID: messageID)
                } catch is CancellationError {
                    return
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

private struct CantripRemoteMessageBubble: View {
    let message: CantripRemoteMessage
    @ObservedObject var model: CantripRemoteModel
    let sessionID: String

    var body: some View {
        if message.isFreshStart {
            CantripFreshStartDivider(text: message.text)
        } else {
            bubble
        }
    }

    private var bubble: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 8) {
                Text(message.author ?? message.role.capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !message.thinking.isEmpty {
                    DisclosureGroup("Reasoning") {
                        Text(message.thinking)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 3)
                    }
                    .font(.caption)
                }
                if let subagents = message.subagents, !subagents.isEmpty {
                    CantripSubagentStack(remote: model, sessionID: sessionID, subagents: subagents)
                }
                if !message.presentedText.isEmpty {
                    if message.role == "user" {
                        PromptTextView(text: message.presentedText)
                    } else if message.isLocalPrivate == true {
                        Text(verbatim: message.presentedText)
                    } else {
                        ChatAssistantText(
                            text: message.presentedText,
                            images: (message.images ?? []).map { $0.inSession(sessionID) }, remote: model
                        )
                    }
                }
                ChatImageGallery(
                    images: (message.images ?? []).filter { !ChatMessageImage.validPreviewID($0.id) }
                        .map { $0.inSession(sessionID) }, remote: model
                )
                ForEach(message.activities) { activity in
                    Label {
                        Text("\(activity.toolName): \(activity.title)")
                            .lineLimit(2)
                    } icon: {
                        Image(systemName: activity.state == "running"
                              ? "progress.indicator" : activityIcon(activity.state))
                    }
                    .font(.caption2)
                    .foregroundStyle(activity.state == "failed" ? .orange : .secondary)
                    if activity.input != nil || activity.output != nil {
                        DisclosureGroup("Tool details") {
                            if let input = activity.input { PromptTextView(text: input) }
                            if let output = activity.output { PromptTextView(text: output) }
                        }
                        .font(.caption)
                    }
                }
                if message.role == "user", let usage = message.promptUsage {
                    CantripPromptUsageLine(usage: usage)
                }
            }
            .padding(11)
            .background(background, in: RoundedRectangle(cornerRadius: 14))
            .textSelection(.enabled)
            if message.role != "user" { Spacer(minLength: 36) }
        }
    }

    private var background: Color {
        switch message.role {
        case "user": return Color.accentColor.opacity(0.24)
        case "error": return Color.red.opacity(0.16)
        default: return Color(.secondarySystemBackground)
        }
    }

    private func activityIcon(_ state: String) -> String {
        switch state {
        case "succeeded": return "checkmark.circle"
        case "failed": return "exclamationmark.triangle"
        case "cancelled": return "xmark.circle"
        default: return "circle"
        }
    }
}

private struct CantripRemoteSetupView: View {
    @ObservedObject var model: CantripRemoteModel

    var body: some View {
        Form {
            Section {
                Label("Connect to Cantrip", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Text("Enter the pairing token from Cantrip. Cantrip Agent prefers your saved Tailscale Serve URL, even on the same local network. Direct LAN is used if Tailscale is unavailable or no URL is saved.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            CantripRemoteSettingsSection(model: model)
        }
    }
}

struct CantripRemoteSettingsSection: View {
    @ObservedObject var model: CantripRemoteModel

    var body: some View {
        ServerSettingsSections(
            servers: model.servers,
            canChangeSelection: !model.isMutating,
            add: { try model.addServer($0) },
            select: { try await model.selectServer($0) },
            remove: model.removeServer
        )
        if let error = model.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct CantripRemoteSettingsSheet: View {
    @ObservedObject var model: CantripRemoteModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                CantripRemoteSettingsSection(model: model)
            }
            .navigationTitle("Remote Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#if os(iOS)
enum CantripRemoteTabIcon {
    static func image(connected: Bool) -> UIImage {
        let size = CGSize(width: 30, height: 26)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
            let symbol = UIImage(
                systemName: "antenna.radiowaves.left.and.right",
                withConfiguration: symbolConfiguration
            )?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
            symbol?.draw(in: CGRect(x: 2, y: 4, width: 21, height: 19))

            let dotRect = CGRect(x: 21, y: 2, width: 7, height: 7)
            context.cgContext.setFillColor(
                (connected ? UIColor.systemGreen : UIColor.systemGray).cgColor
            )
            context.cgContext.fillEllipse(in: dotRect)
            context.cgContext.setStrokeColor(UIColor.systemBackground.cgColor)
            context.cgContext.setLineWidth(1)
            context.cgContext.strokeEllipse(in: dotRect.insetBy(dx: 0.5, dy: 0.5))
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}
#endif

#if DEBUG
extension CantripRemoteModel {
    /// UI tests build push payloads the paired server would send.
    static func notificationFingerprintForUITest(_ token: String) -> String {
        CantripLANProtocol.tokenFingerprint(token)
    }
}
#endif
