import SwiftUI

/// Delete Message: removes a message's whole exchange (the prompt and its replies) from the tab's
/// history on the Mac, so the model doesn't have it anymore. In the context menu of prompt and
/// error rows (long press on iPhone and Duo, right-click on Gateway Mac), confirmed first. Replies
/// get no menu, so their text keeps native selection; deleting the prompt removes them too. Shown
/// only while the tab is idle on a Mac with `supportsDeleteMessage`.
enum CantripDeleteMessage {
    static let title = "Delete Message"
    static let systemImage = "trash"
    static let confirmationTitle = "Delete this message?"
    static let confirmationMessage = "This removes the message and its reply from this tab's history on the Mac, and the model won't have them anymore. This can't be undone."
    static let confirm = "Delete"
    static let unsupported = "Update and reopen Cantrip on your Mac to delete messages. Nothing in the tab has changed."
    static let busy = "Wait for this tab to finish before deleting a message."

    /// Rows with the menu: prompts and errors. Never replies (native text selection), Start Fresh
    /// dividers, handoff results or child tab cards.
    static func hasMenu(_ message: CantripRemoteMessage) -> Bool {
        ["user", "error"].contains(message.role) && message.childResult == nil && message.handoffResult == nil
    }

    /// The row's menu offers Delete Message now: the tab is idle on a Mac that deletes messages.
    static func offers(_ message: CantripRemoteMessage, in session: CantripRemoteSession) -> Bool {
        session.supportsDeleteMessage == true && !session.isStreaming && hasMenu(message)
    }

    /// The message as Copy puts it on the pasteboard: a prompt with tab mentions as "@Title", an
    /// error as shown.
    static func copyText(_ message: CantripRemoteMessage) -> String {
        message.role == "error" ? message.text : CantripTabMentions.plain(message.presentedText)
    }

    /// Drops the tab's deleted messages (`deletedMessageIDs`, from any device) from its transcript.
    static func dropDeleted(from session: inout CantripRemoteSession) {
        guard let ids = session.deletedMessageIDs, !ids.isEmpty, let messages = session.messages else { return }
        let deleted = Set(ids)
        guard messages.contains(where: { deleted.contains($0.id) }) else { return }
        session.messages = messages.filter { !deleted.contains($0.id) }
    }
}

/// A prompt or error row's context menu while it offers Delete Message: Copy, then Delete Message
/// (confirmed first). Rows without `attached` (replies, cards, local rows) get no menu at all, so
/// their text keeps native selection. Fixed per row, so a row never swaps views when the tab starts
/// or stops working; the menu is just empty then.
struct CantripMessageMenu: ViewModifier {
    struct Target: Equatable {
        let sessionID: String
        let messageID: String
    }

    let model: CantripRemoteModel
    let attached: Bool
    let target: Target?
    /// What Copy puts on the pasteboard; nil hides Copy.
    var copyText: String?
    /// A bubble's corner radius, so iOS lifts just the bubble while the menu shows.
    var previewCornerRadius: CGFloat?
    @State private var confirming: Target?

    @ViewBuilder func body(content: Content) -> some View {
        if attached { menu(content) } else { content }
    }

    private func menu(_ content: Content) -> some View {
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
    /// A prompt or error from the Mac: the row has the menu (Copy, Delete Message).
    var hasMessageMenu: Bool { remoteMessage.map(CantripDeleteMessage.hasMenu) ?? false }

    /// The row's menu, attached only to prompt and error rows.
    func messageMenu(previewCornerRadius: CGFloat? = nil) -> CantripMessageMenu {
        CantripMessageMenu(model: remote, attached: hasMessageMenu, target: deleteMessageTarget,
                           copyText: menuCopyText, previewCornerRadius: previewCornerRadius)
    }

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
