import SwiftUI

/// Delete Message: removes a message's whole exchange (the prompt and its replies) from the tab's
/// history on the Mac, so the model doesn't have it anymore. In every row's context menu (long
/// press on iPhone and Duo, right-click on Gateway Mac) for prompts, replies and errors, confirmed
/// first. Shown only while the tab is idle on a Mac with `supportsDeleteMessage`.
enum CantripDeleteMessage {
    static let title = "Delete Message"
    static let systemImage = "trash"
    static let confirmationTitle = "Delete this message?"
    static let confirmationMessage = "This removes the message and its reply from this tab's history on the Mac, and the model won't have them anymore. This can't be undone."
    static let confirm = "Delete"
    static let unsupported = "Update and reopen Cantrip on your Mac to delete messages. Nothing in the tab has changed."
    static let busy = "Wait for this tab to finish before deleting a message."

    /// Prompts, replies and errors; never Start Fresh dividers, handoff results or child tab cards.
    static func offers(_ message: CantripRemoteMessage, in session: CantripRemoteSession) -> Bool {
        session.supportsDeleteMessage == true && !session.isStreaming
            && ["user", "assistant", "error"].contains(message.role)
            && message.childResult == nil && message.handoffResult == nil
    }

    /// The message as Copy puts it on the pasteboard: tab mentions as "@Title", replies without
    /// their inline Markdown, as the selected text would read.
    static func copyText(_ message: CantripRemoteMessage) -> String {
        let text = CantripTabMentions.plain(message.presentedText)
        guard message.role == "assistant",
              let markdown = try? AttributedString(
                  markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
              ) else { return text }
        return String(markdown.characters)
    }

    /// Drops the tab's deleted messages (`deletedMessageIDs`, from any device) from its transcript.
    static func dropDeleted(from session: inout CantripRemoteSession) {
        guard let ids = session.deletedMessageIDs, !ids.isEmpty, let messages = session.messages else { return }
        let deleted = Set(ids)
        guard messages.contains(where: { deleted.contains($0.id) }) else { return }
        session.messages = messages.filter { !deleted.contains($0.id) }
    }
}

/// A transcript row's context menu while it offers Delete Message: Copy, then Delete Message
/// (confirmed first). The menu takes the long press from iOS's text selection, so it keeps Copy.
/// Rows that can't be deleted get no menu, and their text stays selectable as before.
struct CantripMessageMenu: ViewModifier {
    struct Target: Equatable {
        let sessionID: String
        let messageID: String
    }

    let model: CantripRemoteModel
    let target: Target?
    /// What Copy puts on the pasteboard; nil hides Copy.
    var copyText: String?
    /// A bubble's corner radius, so iOS lifts just the bubble while the menu shows.
    var previewCornerRadius: CGFloat?
    @State private var confirming: Target?

    func body(content: Content) -> some View {
        preview(content)
            .contextMenu {
                if let target {
                    if let copyText, !copyText.isEmpty {
                        Button {
                            UIPasteboard.general.string = copyText
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                    Button(role: .destructive) {
                        confirming = target
                    } label: {
                        Label(CantripDeleteMessage.title, systemImage: CantripDeleteMessage.systemImage)
                    }
                    .accessibilityIdentifier("cantrip.message.delete")
                }
            }
            .confirmationDialog(
                CantripDeleteMessage.confirmationTitle,
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible,
                presenting: confirming
            ) { target in
                Button(CantripDeleteMessage.confirm, role: .destructive) {
                    confirming = nil
                    Task { await model.deleteMessage(target.messageID, sessionID: target.sessionID) }
                }
                Button("Cancel", role: .cancel) { confirming = nil }
            } message: { _ in
                Text(CantripDeleteMessage.confirmationMessage)
            }
    }

    @ViewBuilder private func preview(_ content: Content) -> some View {
        #if os(iOS)
        if let previewCornerRadius {
            content.contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: previewCornerRadius))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension TurnView {
    /// This row's message, when it offers Delete Message in the tab on screen.
    var deleteMessageTarget: CantripMessageMenu.Target? {
        guard let message = remoteMessage, let session = remote.selectedSession,
              session.id == cantripSessionID, CantripDeleteMessage.offers(message, in: session) else { return nil }
        return .init(sessionID: session.id, messageID: message.id)
    }

    /// The row's text as its menu's Copy puts it on the pasteboard.
    var menuCopyText: String? {
        guard let message = remoteMessage else { return nil }
        return CantripDeleteMessage.copyText(message)
    }
}
