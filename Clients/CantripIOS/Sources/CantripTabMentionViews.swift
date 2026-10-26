import SwiftUI

// MARK: - Composer

/// The composer's caret for "@" suggestions: the insertion point, the end of the text when the
/// field doesn't report one, or nil while a range is selected (no suggestions then).
enum CantripMentionCaret {
    static func position(in text: String, selection: TextSelection?) -> String.Index? {
        guard let selection else { return text.endIndex }
        switch selection.indices {
        case .selection(let range):
            guard range.isEmpty else { return nil }
            // A selection from before the latest edit can point past the text.
            return range.lowerBound <= text.endIndex ? range.lowerBound : text.endIndex
        default:
            return nil
        }
    }

    /// The same from a caret read off the platform's text view: a UTF-16 offset, negative while a
    /// range is selected, nil when unknown (the end of the text).
    static func position(in text: String, utf16Offset: Int?) -> String.Index? {
        guard let utf16Offset else { return text.endIndex }
        guard utf16Offset >= 0 else { return nil }
        // An offset from before the latest edit can point past the text.
        guard utf16Offset < text.utf16.count else { return text.endIndex }
        let index = String.Index(utf16Offset: utf16Offset, in: text)
        // Never inside a character (an emoji's surrogate pair): the end of that character.
        return index.samePosition(in: text) ?? text.indices.first { $0 > index } ?? text.endIndex
    }
}

/// The arrow-key row of an "@" pop-up, for the "@" and query it was moved on.
struct CantripMentionHighlight: Equatable {
    let at: Int
    let query: String
    let index: Int

    /// The highlighted row: the first one unless the arrow keys moved it for this query.
    static func index(_ highlight: CantripMentionHighlight?, popup: CantripTabMentions.Popup?) -> Int {
        guard let popup, let highlight, highlight.at == popup.at, highlight.query == popup.query else { return 0 }
        return highlight.index
    }
}

/// Hardware-keyboard keys for the "@" pop-up on iOS (the Gateway Mac routes the same keys through
/// `MacSlashKeyMonitor`). Only unmodified keys are taken, so Shift-Return keeps its meaning.
struct CantripMentionKeyPresses: ViewModifier {
    let isActive: Bool
    let onKey: (BackendSlashKey) -> Bool

    func body(content: Content) -> some View {
        content.onKeyPress(keys: [.upArrow, .downArrow, .tab, .return, .escape], phases: .down) { press in
            guard isActive, press.modifiers.intersection([.shift, .control, .option, .command]).isEmpty else {
                return .ignored
            }
            let key: BackendSlashKey
            switch press.key {
            case .upArrow: key = .up
            case .downArrow: key = .down
            case .tab: key = .tab
            case .return: key = .return
            case .escape: key = .escape
            default: return .ignored
            }
            return onKey(key) ? .handled : .ignored
        }
    }
}

/// The "@" suggestions above a composer: open tabs to mention, in the tab list's order. Styled like
/// the "/" command list; rows grow with Dynamic Type and the list scrolls past `maxHeight`.
struct CantripMentionSuggestionList: View {
    @ObservedObject private var keyboard = BackendSlashHardwareKeyboard.shared
    let popup: CantripTabMentions.Popup
    /// The tabs by ID, for each row's status glyph.
    let sessions: [String: CantripRemoteSession]
    var highlighted = 0
    let maxHeight: CGFloat
    let onPick: (CantripTabMentions.Candidate) -> Void

    @State private var contentHeight: CGFloat = 0

    /// The keyboard highlight shows only when a keyboard can move it (always on the Mac).
    private var shownHighlight: Int? { keyboard.isAttached ? highlighted : nil }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) { content }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            #if os(iOS)
            // Scrolling the list must not drop the keyboard: that would close the list.
            .scrollDismissesKeyboard(.never)
            #endif
            .frame(height: min(max(contentHeight, 1), maxHeight))
            .onChange(of: shownHighlight) { _, position in
                let rows = popup.rows
                guard let position, rows.indices.contains(position) else { return }
                proxy.scrollTo(rows[position].id)
                // VoiceOver stays in the text field, so read the highlighted row like an active descendant.
                BackendSlashAnnouncer.announce(rows[position].accessibilityLabel, polite: false)
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab suggestions")
        .accessibilityIdentifier("chat.mentionSuggestions")
        .onAppear { announceCount() }
        .onChange(of: popup.rows.count) { _, _ in announceCount() }
    }

    @ViewBuilder private var content: some View {
        switch popup.content {
        case .rows(let rows):
            ForEach(Array(rows.enumerated()), id: \.element.id) { position, candidate in
                CantripMentionSuggestionButton(
                    candidate: candidate, session: sessions[candidate.id],
                    isHighlighted: position == shownHighlight, onPick: onPick
                )
                .id(candidate.id)
                if position < rows.count - 1 { Divider() }
            }
        case .noMatch(let query):
            Label(CantripTabMentions.noMatchText(query), systemImage: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .padding(.vertical, 6).padding(.horizontal, 12)
                .accessibilityIdentifier("chat.mentionSuggestions.noMatch")
        }
    }

    private func announceCount() {
        let count = popup.rows.count
        BackendSlashAnnouncer.announce(count == 0 ? CantripTabMentions.noMatchText(popup.query)
                                       : CantripTabMentions.countAnnouncement(count), polite: true)
    }
}

/// One tab in the "@" pop-up: its status glyph, title and what tells it apart.
private struct CantripMentionSuggestionButton: View {
    let candidate: CantripTabMentions.Candidate
    let session: CantripRemoteSession?
    let isHighlighted: Bool
    let onPick: (CantripTabMentions.Candidate) -> Void

    var body: some View {
        Button { onPick(candidate) } label: {
            CantripMentionSuggestionRow(candidate: candidate, session: session, isHighlighted: isHighlighted)
        }
        .buttonStyle(CantripMentionRowButtonStyle())
        .accessibilityLabel(candidate.accessibilityLabel)
        .accessibilityHint("Mentions this tab in your message")
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityIdentifier("chat.mentionSuggestion.\(candidate.id)")
    }
}

private struct CantripMentionRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.1) : Color.clear)
    }
}

private struct CantripMentionSuggestionRow: View {
    let candidate: CantripTabMentions.Candidate
    let session: CantripRemoteSession?
    let isHighlighted: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if let session {
                    CantripTabStatusIndicator(session: session)
                } else {
                    Image(systemName: "rectangle.stack").foregroundStyle(.secondary)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if candidate.parentTitle != nil { CantripChildTabGlyph() }
                    Text(verbatim: candidate.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                let detail = candidate.detail
                if !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The highlight is also a shape (an edge and a Return glyph), not only a color.
            if isHighlighted {
                Image(systemName: "return")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(isHighlighted ? Color.accentColor.opacity(0.25) : Color.clear)
        .overlay(alignment: .leading) {
            if isHighlighted {
                Rectangle().fill(Color.accentColor).frame(width: 3).accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The mentions picked for the draft, as removable chips above the composer (like attachments).
struct CantripMentionChips: View {
    let mentions: [CantripTabMention]
    var disabled = false
    let onRemove: (CantripTabMention) -> Void

    var body: some View {
        if !mentions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(mentions, id: \.self) { mention in
                        HStack(spacing: 0) {
                            Image(systemName: "rectangle.stack")
                                .font(.caption.weight(.semibold))
                                .padding(.leading, 10)
                                .padding(.trailing, 5)
                                .accessibilityHidden(true)
                            Text(verbatim: "@" + mention.label)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .accessibilityLabel("Mentions tab \(mention.label)")
                            Button { onRemove(mention) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.7))
                                    .font(.title3)
                                    #if os(iOS)
                                    .frame(width: 44, height: 44)
                                    #else
                                    .frame(width: 30, height: 30)
                                    #endif
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(disabled)
                            .accessibilityLabel("Remove mention \(mention.label)")
                            .accessibilityIdentifier("chat.mentionChip.remove.\(mention.id)")
                        }
                        .foregroundStyle(Color.accentColor)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("chat.mentionChips")
        }
    }
}

// MARK: - Transcripts

/// How a mention reads in message text.
enum CantripMentionStyle {
    /// Accent color, bold: replies, queue rows and other text on a plain background.
    case standard
    /// White, bold, on a light wash: the user's own bubbles, which are accent-colored.
    case onAccent
}

/// Opens a rendered mention's tab. Present only where the chat can open tabs.
struct CantripMentionLinks: Equatable {
    /// Tabs open in the tab list, by uppercased ID.
    let openable: Set<String>
    let open: (String) -> Void

    func canOpen(_ id: String) -> Bool { openable.contains(id.uppercased()) }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.openable == rhs.openable }
}

private struct CantripMentionLinksKey: EnvironmentKey {
    static let defaultValue: CantripMentionLinks? = nil
}

extension EnvironmentValues {
    var cantripMentionLinks: CantripMentionLinks? {
        get { self[CantripMentionLinksKey.self] }
        set { self[CantripMentionLinksKey.self] = newValue }
    }
}

private struct CantripMentionLinkHandler: ViewModifier {
    @Environment(\.openURL) private var openURL
    let links: CantripMentionLinks?

    func body(content: Content) -> some View {
        if let links {
            content
                .environment(\.cantripMentionLinks, links)
                .environment(\.openURL, OpenURLAction { url in
                    guard let id = CantripTabMentions.tabID(from: url) else {
                        openURL(url)
                        return .handled
                    }
                    guard links.canOpen(id) else { return .discarded }
                    links.open(id)
                    return .handled
                })
        } else {
            content
        }
    }
}

extension View {
    /// Mentions of open tabs in this transcript become links that open the tab (`onOpenTab`).
    func cantripMentionLinks(remote: CantripRemoteModel, onOpenTab: ((String) -> Void)?) -> some View {
        modifier(CantripMentionLinkHandler(links: onOpenTab.map { open in
            let current = remote.selectedSessionID?.uppercased()
            return CantripMentionLinks(
                openable: Set(remote.sessions.map { $0.id.uppercased() }.filter { $0 != current }),
                open: open
            )
        }))
    }
}

extension CantripTabMentions {
    /// Message text with each token shown as a bold "@Label" (a link when `links` can open it).
    static func attributed(_ text: String, style: CantripMentionStyle,
                           links: CantripMentionLinks? = nil) -> AttributedString {
        var result = AttributedString()
        for segment in segments(text) {
            switch segment {
            case .text(let run):
                result += AttributedString(run)
            case .mention(let label, let id):
                var run = AttributedString("@" + label)
                run.inlinePresentationIntent = .stronglyEmphasized
                switch style {
                case .standard:
                    run.foregroundColor = .accentColor
                case .onAccent:
                    run.foregroundColor = .white
                    run.backgroundColor = Color.white.opacity(0.22)
                }
                if let links, links.canOpen(id), let url = URL(string: "\(scheme):\(id)") {
                    run.link = url
                }
                result += run
            }
        }
        return result
    }
}

/// Plain message text with its mentions drawn as "@Label" (see `CantripMentionStyle`).
struct CantripMentionText: View {
    @Environment(\.cantripMentionLinks) private var links
    let text: String
    var style = CantripMentionStyle.standard

    var body: some View {
        if CantripTabMentions.parse(text).isEmpty {
            Text(verbatim: text)
        } else {
            Text(CantripTabMentions.attributed(text, style: style, links: links))
                // Links take the tint; on an accent bubble they stay white like the text.
                .tint(style == .onAccent ? .white : .accentColor)
        }
    }
}
