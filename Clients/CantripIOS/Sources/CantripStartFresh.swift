import SwiftUI

/// Start Fresh: a tab's next prompt starts a new model session. Its title, folder, model
/// settings, lock and visible history stay; nothing from before is sent to the model.
enum CantripStartFresh {
    static let title = "Start Fresh"
    static let systemImage = "arrow.counterclockwise.circle"
    static let defaultCaption = "Started fresh — earlier messages aren't sent to the model"
    static let hint = "Keeps this tab's messages, but the next prompt won't send them to the model."

    /// Nil from Macs before Start Fresh; false where it doesn't apply (Cantrip Home).
    static func support(for session: CantripRemoteSession) -> Bool? {
        session.isCantripHome == true ? false : session.supportsStartFresh
    }

    /// The Mac refuses while the tab works or has messages queued.
    static func isBusy(_ session: CantripRemoteSession) -> Bool {
        session.isStreaming || session.queuedCount > 0
    }
}

/// "Start Fresh" for tab menus, after Model Settings. Hidden where it doesn't apply; on older
/// Macs it shows disabled with an update notice, like Rename and Lock.
struct CantripStartFreshMenuItem: View {
    let model: CantripRemoteModel
    let sessionID: String
    let support: Bool?
    let isDisabled: Bool

    var body: some View {
        if support != false {
            Button {
                Task { await model.startFresh(sessionID: sessionID) }
            } label: {
                Label(CantripStartFresh.title, systemImage: CantripStartFresh.systemImage)
            }
            .disabled(isDisabled || support != true)
            .accessibilityHint(CantripStartFresh.hint)
            if support == nil {
                Text("Update and reopen Cantrip to start fresh.")
            }
        }
    }
}

/// Where a tab started fresh: hairline, the Mac's caption, hairline. Not a reply.
struct CantripFreshStartDivider: View {
    let text: String

    var caption: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? CantripStartFresh.defaultCaption : trimmed
    }

    var body: some View {
        HStack(spacing: 10) {
            hairline
            Text(caption)
                .font(.caption)
                .foregroundStyle(CantripReasoningFormat.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            hairline
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityIdentifier("cantrip.freshStartDivider")
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(minWidth: 16, maxWidth: .infinity)
            .frame(height: 1)
    }
}

/// Under an error the tab hit twice in a row: start fresh, or pick another model.
struct CantripRepeatedErrorActions: View {
    @ObservedObject var model: CantripRemoteModel
    let session: CantripRemoteSession

    private var offersStartFresh: Bool { session.supportsStartFresh == true }
    private var offersSettings: Bool { session.supportsModelSettings == true || session.isLocalPrivate == true }

    var body: some View {
        if offersStartFresh || offersSettings {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        if offersStartFresh {
            Button {
                Task { await model.startFresh(sessionID: session.id) }
            } label: {
                Label(CantripStartFresh.title, systemImage: CantripStartFresh.systemImage)
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
            .disabled(model.isMutating || CantripStartFresh.isBusy(session))
            .accessibilityHint(CantripStartFresh.hint)
            .accessibilityIdentifier("cantrip.error.startFresh")
        }
        if offersSettings {
            Button {
                model.modelSettingsSession = session
            } label: {
                Label(session.isLocalPrivate == true ? "Private Local Settings" : "Change Model",
                      systemImage: "slider.horizontal.3")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .disabled(model.isMutating)
            .accessibilityHint("Opens this tab's model settings.")
            .accessibilityIdentifier("cantrip.error.changeModel")
        }
    }
}
