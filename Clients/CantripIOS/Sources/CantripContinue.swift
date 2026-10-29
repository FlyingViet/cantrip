import SwiftUI

/// Continue: a run that failed or timed out on the Mac waits on its error message instead of
/// retrying, and queued messages wait behind it. Continue there picks the task up from where it
/// stopped — the same run when it's the tab's latest, otherwise a new run with its request.
enum CantripContinue {
    static let title = "Continue"
    static let systemImage = "arrow.uturn.forward"
    static let hint = "Picks this task up from where it stopped. Queued messages run after it."
    static let unsupported = "Update and reopen Cantrip on your Mac to continue from a message. Nothing in the tab has changed."
    static let busy = "Wait for the current task to finish, then tap Continue."
    static let gone = "That task can't be continued anymore."

    /// The tab-wide Resume, for a paused run whose error row isn't offering Continue (older Macs,
    /// or a row outside the loaded history). Never both.
    static func showsTabResume(_ session: CantripRemoteSession) -> Bool {
        session.canResume && (session.continuableMessageIDs ?? []).isEmpty
    }
}

/// Continue under a failed run's error row.
struct CantripContinueButton: View {
    @ObservedObject var model: CantripRemoteModel
    let session: CantripRemoteSession
    let messageID: String

    var body: some View {
        Button {
            Task { await model.continueFailedRun(messageID: messageID, sessionID: session.id) }
        } label: {
            Label(CantripContinue.title, systemImage: CantripContinue.systemImage)
                .font(.callout.weight(.medium))
        }
        .buttonStyle(.borderedProminent)
        .frame(minHeight: 44)
        .disabled(model.isMutating || session.isStreaming)
        .accessibilityHint(CantripContinue.hint)
        .accessibilityIdentifier("cantrip.error.continue")
    }
}
