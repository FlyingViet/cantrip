import Accessibility
import Combine
import SwiftUI
#if canImport(GameController)
import GameController
#endif

/// How suggestion rows are laid out.
enum BackendSlashRowStyle: Equatable {
    /// iPhone rows: descriptions wrap to two lines; no keyboard highlight.
    case touch
    /// Gateway Mac rows: one-line descriptions, tighter spacing, and the keyboard highlight
    /// (Up/Down, Tab, Return, Escape) when a hardware keyboard is attached.
    case compact
    /// iPhone Duo's sidebar Skills rows: compact, with the title kept to two lines in the
    /// narrow column (any lines at accessibility sizes).
    case sidebar

    /// Compact only where the system puts navigation in a vertical side bar and the window is
    /// landscape (iPhone Duo unfolded on its side). Portrait or folded Duo and other iPhones keep
    /// touch rows.
    static func resolve(_ traits: ChatDisplayTraits) -> Self {
        traits.hasVerticalBar && traits.isLandscape && !traits.isFolded ? .compact : .touch
    }
}

/// Whether a hardware keyboard can drive the suggestion highlight: always on the Mac; on iOS
/// while one is connected.
@MainActor
final class BackendSlashHardwareKeyboard: ObservableObject {
    static let shared = BackendSlashHardwareKeyboard()
    @Published private(set) var isAttached: Bool
    private var observers: [NSObjectProtocol] = []

    private init() {
        #if os(iOS)
        isAttached = GCKeyboard.coalesced != nil
        #if DEBUG
        if CantripUITestFixtures.attachesHardwareKeyboard { isAttached = true }
        #endif
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let shared = BackendSlashHardwareKeyboard.shared
                    shared.isAttached = GCKeyboard.coalesced != nil
                    #if DEBUG
                    if CantripUITestFixtures.attachesHardwareKeyboard { shared.isAttached = true }
                    #endif
                }
            })
        }
        #else
        isAttached = true
        #endif
    }
}

/// Hardware-keyboard keys for compact suggestion rows on iOS (the Gateway Mac routes the same keys
/// through its own monitor). Only unmodified keys are taken, so Shift-Return and friends keep
/// their usual meaning, and only while the list shows compact rows with a keyboard attached.
struct BackendSlashKeyPresses: ViewModifier {
    @Environment(\.chatDisplayTraits) private var displayTraits
    @ObservedObject private var keyboard = BackendSlashHardwareKeyboard.shared
    let isActive: Bool
    let onKey: (BackendSlashKey) -> Bool

    func body(content: Content) -> some View {
        content.onKeyPress(keys: [.upArrow, .downArrow, .tab, .return, .escape], phases: .down) { press in
            guard isActive, keyboard.isAttached, BackendSlashRowStyle.resolve(displayTraits) == .compact,
                  press.modifiers.intersection([.shift, .control, .option, .command]).isEmpty,
                  let key = Self.key(press.key) else { return .ignored }
            return onKey(key) ? .handled : .ignored
        }
    }

    private static func key(_ key: KeyEquivalent) -> BackendSlashKey? {
        switch key {
        case .upArrow: return .up
        case .downArrow: return .down
        case .tab: return .tab
        case .return: return .return
        case .escape: return .escape
        default: return nil
        }
    }
}

/// The "/" suggestions above a Cantrip composer: the tab backend's slash commands, custom commands
/// and skills (iPhone, iPad and the Gateway Mac). Rows grow with Dynamic Type; the list scrolls
/// once it reaches `maxHeight`.
struct BackendSlashSuggestionList: View {
    @Environment(\.chatDisplayTraits) private var displayTraits
    @ObservedObject private var keyboard = BackendSlashHardwareKeyboard.shared
    let presentation: BackendSlashPresentation
    /// The keyboard highlight (a position in the matches); shown with compact rows only.
    var highlighted: Int? = nil
    let maxHeight: CGFloat
    var canOpenModelSettings = false
    /// Nil picks the style from the chat's display (`BackendSlashRowStyle.resolve`).
    var style: BackendSlashRowStyle? = nil
    /// Caps the list at this many rows (a part row shows there is more to scroll); nil keeps only
    /// `maxHeight`. Measured from the rows themselves, so it follows Dynamic Type.
    var maxVisibleRows: Double? = nil
    let onChoose: (BackendCommandMatch) -> Void

    @State private var contentHeight: CGFloat = 0
    @State private var rowHeights: [Int: CGFloat] = [:]

    private var rowStyle: BackendSlashRowStyle { style ?? .resolve(displayTraits) }

    private var shownHighlight: Int? {
        rowStyle == .compact && keyboard.isAttached ? highlighted : nil
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) { content }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            // Shows that more rows wait below the cap.
            .scrollIndicatorsFlash(onAppear: true)
            #if os(iOS)
            // Scrolling the list must not drop the keyboard: that would close the list.
            .scrollDismissesKeyboard(.never)
            #endif
            .frame(height: min(contentHeight, maxHeight, rowCap ?? .infinity))
            #if DEBUG
            .task(id: presentation.matches.count) {
                // `-CantripUITestSlashScrollToEnd`: screenshots of the last (unavailable) rows.
                guard CantripUITestFixtures.scrollsSlashListToEnd, let last = presentation.matches.last else { return }
                try? await Task.sleep(for: .milliseconds(600))
                proxy.scrollTo(last.id, anchor: .bottom)
            }
            #endif
            .onChange(of: shownHighlight) { _, position in
                guard let position, presentation.matches.indices.contains(position) else { return }
                proxy.scrollTo(presentation.matches[position].id)
                // VoiceOver stays in the text field, so read the highlighted row like an active descendant.
                BackendSlashAnnouncer.announce(
                    BackendSlashCommands.accessibilityLabel(for: presentation.matches[position].command), polite: false
                )
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command suggestions")
        .accessibilityIdentifier("chat.slashSuggestions")
        .onAppear { announceCount() }
        .onChange(of: countAnnouncement) { _, _ in announceCount() }
    }

    @ViewBuilder private var content: some View {
        switch presentation {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading commands…").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.slashSuggestions.loading")
        case .rows(let matches, let status):
            ForEach(Array(matches.enumerated()), id: \.element.id) { position, match in
                row(match, isHighlighted: position == shownHighlight)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeights[position] = $0 }
                if position < matches.count - 1 || status != nil { Divider() }
            }
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    .accessibilityIdentifier("chat.slashSuggestions.status")
            }
        }
    }

    private func row(_ match: BackendCommandMatch, isHighlighted: Bool) -> some View {
        BackendSlashSuggestionButton(match: match, isHighlighted: isHighlighted, style: rowStyle,
                                     canOpenModelSettings: canOpenModelSettings, onChoose: onChoose)
            .id(match.id)
    }

    /// Two full rows and half of the third, once they have been measured.
    private var rowCap: CGFloat? {
        guard let maxVisibleRows, maxVisibleRows > 0 else { return nil }
        let count = presentation.matches.count
        guard Double(count) > maxVisibleRows else { return nil }
        var height: CGFloat = 0
        var remaining = maxVisibleRows
        for position in 0..<count where remaining > 0 {
            guard let row = rowHeights[position] else { return nil }
            // Rows are separated by one-point dividers.
            height += (row + 1) * CGFloat(min(1, remaining))
            remaining -= 1
        }
        return height
    }

    private var countAnnouncement: String? {
        guard case .rows(let matches, _) = presentation else { return nil }
        return BackendSlashCommands.countAnnouncement(matches.count)
    }

    private func announceCount() {
        if let countAnnouncement { BackendSlashAnnouncer.announce(countAnnouncement, polite: true) }
    }
}

enum BackendSlashAnnouncer {
    /// Polite announcements wait for VoiceOver to finish echoing the typed character.
    @MainActor
    static func announce(_ text: String, polite: Bool) {
        var announcement = AttributedString(text)
        announcement.accessibilitySpeechAnnouncementPriority = polite ? .low : .high
        AccessibilityNotification.Announcement(announcement).post()
    }
}

/// One suggestion as a button: the pop-up's rows and the Duo sidebar's Skills rows.
struct BackendSlashSuggestionButton: View {
    let match: BackendCommandMatch
    let isHighlighted: Bool
    let style: BackendSlashRowStyle
    let canOpenModelSettings: Bool
    let onChoose: (BackendCommandMatch) -> Void

    var body: some View {
        let command = match.command
        Button { onChoose(match) } label: {
            BackendSlashSuggestionRow(command: command, isHighlighted: isHighlighted, style: style)
        }
        .buttonStyle(SuggestionRowButtonStyle())
        // Disabled for taps and VoiceOver ("dimmed"); the row draws its own dimming.
        .disabled(command.isUnavailable)
        .accessibilityLabel(BackendSlashCommands.accessibilityLabel(for: command))
        .accessibilityHint(BackendSlashCommands.accessibilityHint(for: command,
                                                                  canOpenModelSettings: canOpenModelSettings))
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityIdentifier("chat.slashSuggestion.\(command.name)")
    }
}

/// Pressed feedback without the plain style's disabled fade, which would also fade the note
/// explaining why a row can't run.
private struct SuggestionRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.1) : Color.clear)
    }
}

private struct BackendSlashSuggestionRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let command: BackendCommand
    let isHighlighted: Bool
    let style: BackendSlashRowStyle

    private var descriptionLineLimit: Int { style == .touch ? 2 : 1 }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // No room beside the text at accessibility sizes: the source goes underneath.
                VStack(alignment: .leading, spacing: 3) {
                    details
                    source
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    details
                    Spacer(minLength: 4)
                    source
                }
            }
        }
        .padding(.vertical, style == .touch ? 8 : 6).padding(.horizontal, style == .sidebar ? 8 : 12)
        .background(isHighlighted ? Color.accentColor.opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Long names and hints wrap instead of truncating what would be inserted.
            title
                .lineLimit(style == .sidebar && !dynamicTypeSize.isAccessibilitySize ? 2 : nil)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(dimming)
            if !command.description.isEmpty {
                Text(command.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(descriptionLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(dimming)
            }
            // The reason a row can't run stays fully legible; dimming isn't the only signal.
            if let note = command.trimmedNote {
                Label {
                    Text(note)
                } icon: {
                    Image(systemName: command.isUnavailable ? "nosign" : "info.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: Text {
        let name = Text(command.title)
            .font(.callout.monospaced().weight(.semibold))
            .foregroundStyle(command.isUnavailable ? Color.secondary : Color.accentColor)
        guard let hint = command.trimmedInputHint else { return name }
        let hintText = Text(hint).font(.caption.monospaced()).foregroundStyle(.secondary)
        return Text("\(name) \(hintText)")
    }

    @ViewBuilder private var source: some View {
        if !command.source.isEmpty {
            Text(command.source)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
                .opacity(dimming)
        }
    }

    private var dimming: Double { command.isUnavailable ? 0.55 : 1 }
}
