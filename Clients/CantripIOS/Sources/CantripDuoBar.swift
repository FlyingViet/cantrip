import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Home's sections in the iPhone Duo's navigation bar.
struct CantripDuoBarSections {
    var selection: Binding<CantripHomeSection>
    var runningTasks: Int
}

/// The iPhone Duo's one navigation bar on the screen's edge, in every pose: the tab list or
/// sidebar toggle, Settings, View Mac and the menu, then (in Home) Chat, Tasks, Artifacts and
/// Builds at the bottom. Minimized it is one pill showing where you are; a tap expands it.
struct CantripDuoBarItems {
    /// The sidebar toggle (unfolded) or the Tabs button (folded).
    var leading: AnyView?
    var settings: AnyView
    var mac: AnyView?
    var menu: AnyView
    /// Home's sections; nil in a tab.
    var sections: CantripDuoBarSections?
    var workingTabs = 0
    var tabsNeedingInput = 0

    var summary: CantripDuoBarSummary {
        CantripDuoBarSummary(
            section: sections?.selection.wrappedValue, runningTasks: sections?.runningTasks ?? 0,
            workingTabs: workingTabs, tabsNeedingInput: tabsNeedingInput
        )
    }
}

/// What the minimized pill shows and says: the current section (in a tab, an up chevron: the tab's
/// menu is already an ellipsis), with a
/// badge for what the folded-away items would show: "?" while a tab needs input, else Home's
/// running tasks (or, in a tab, the working tabs).
struct CantripDuoBarSummary: Equatable {
    let section: CantripHomeSection?
    let runningTasks: Int
    let workingTabs: Int
    let tabsNeedingInput: Int

    var systemImage: String { section?.systemImage ?? "chevron.up" }
    var badgeCount: Int { section == nil ? workingTabs : runningTasks }

    var accessibilityValue: String {
        var parts: [String] = []
        if let section { parts.append(section.title) }
        if runningTasks > 0 { parts.append("\(runningTasks) \(runningTasks == 1 ? "task" : "tasks") running") }
        if tabsNeedingInput > 0 {
            parts.append("\(tabsNeedingInput) \(tabsNeedingInput == 1 ? "tab needs" : "tabs need") your input")
        }
        if section == nil, workingTabs > 0 { parts.append("\(workingTabs) \(workingTabs == 1 ? "tab" : "tabs") working") }
        return parts.joined(separator: ", ")
    }

    static let accessibilityLabel = "Navigation"
    static let accessibilityHint = "Shows Tabs, Settings, View Mac, the menu and Home's sections."
}

/// Which items the system's vertical bar holds; the toolbar is rebuilt when it changes (posture,
/// Home or a tab, View Mac), never for minimizing or expanding.
struct CantripDuoBarLayout: Hashable {
    let toolbar: ChatToolbarLayout
    let hasLeading: Bool
    let hasMac: Bool
    let hasSections: Bool
}

enum CantripDuoBar {
    static func animation(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .snappy }
}

/// The minimized bar: the current section's icon (or an up chevron) and its badge. Tapping expands.
struct CantripDuoBarPill: View {
    let summary: CantripDuoBarSummary
    /// The app-drawn rail sizes and highlights it; the system's bar styles its own items.
    var inAppRail = false
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            Image(systemName: summary.systemImage)
                .symbolVariant(summary.section == nil ? .none : .fill)
                .font(inAppRail ? .title3 : nil)
                .foregroundStyle(summary.section == nil ? Color.primary : Color.accentColor)
                .frame(width: inAppRail ? 48 : nil, height: inAppRail ? 44 : nil)
                .background {
                    if inAppRail, summary.section != nil { Capsule().fill(Color.accentColor.opacity(0.2)) }
                }
                .overlay(alignment: .topTrailing) {
                    CantripTabsBadge(workingCount: summary.badgeCount, inputCount: summary.tabsNeedingInput)
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .contentShape(Rectangle())
        }
        .tint(summary.section == nil ? .primary : .accentColor)
        .accessibilityLabel(CantripDuoBarSummary.accessibilityLabel)
        .accessibilityValue(summary.accessibilityValue)
        .accessibilityHint(CantripDuoBarSummary.accessibilityHint)
        .accessibilityIdentifier("duo.bar.pill")
    }
}

/// One of Home's sections in the expanded bar. Choosing one (or the current one again) minimizes
/// the bar.
struct CantripDuoBarSectionButton: View {
    let section: CantripHomeSection
    let sections: CantripDuoBarSections
    var inAppRail = false
    let onChoose: (CantripHomeSection) -> Void

    private var isSelected: Bool { sections.selection.wrappedValue == section }

    var body: some View {
        Button { onChoose(section) } label: {
            Image(systemName: section.systemImage)
                .symbolVariant(isSelected ? .fill : .none)
                .font(inAppRail ? .title3 : nil)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .frame(width: inAppRail ? 48 : nil, height: inAppRail ? 44 : nil)
                .background {
                    if inAppRail, isSelected { Capsule().fill(Color.accentColor.opacity(0.2)) }
                }
                .overlay(alignment: .topTrailing) {
                    if inAppRail, section == .tasks, sections.runningTasks > 0 {
                        CantripTabsBadge(workingCount: sections.runningTasks)
                    }
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .contentShape(Rectangle())
        }
        .tint(isSelected ? .accentColor : .primary)
        .badge(!inAppRail && section == .tasks ? sections.runningTasks : 0)
        .accessibilityLabel(section.title)
        .accessibilityValue(section == .tasks && sections.runningTasks > 0 ? "\(sections.runningTasks) running" : "")
        .accessibilityHint(isSelected ? "Minimizes the navigation bar" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("duo.bar.section.\(section.rawValue)")
    }
}

/// The bar in the system's vertical bar (folded, and unfolded on its side): one group of items at
/// the bottom of the bar, or one pill when minimized. The system draws and animates it; sections
/// keep their place when the bar is short, and the actions move into its overflow (…) first.
struct CantripDuoVerticalBar: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let items: CantripDuoBarItems
    @Binding var isExpanded: Bool

    func body(content: Content) -> some View {
        #if AGENTGATEWAY_DUO_SDK
        if #available(iOS 27.1, *) {
            content
                .toolbar { toolbarItems }
                .toolbar(.visible, for: .bottomBar)
        } else {
            content
        }
        #else
        content
        #endif
    }

    private func expand() {
        withAnimation(CantripDuoBar.animation(reduceMotion: reduceMotion)) { isExpanded = true }
    }

    private func choose(_ section: CantripHomeSection) {
        withAnimation(CantripDuoBar.animation(reduceMotion: reduceMotion)) {
            items.sections?.selection.wrappedValue = section
            isExpanded = false
        }
    }

    #if AGENTGATEWAY_DUO_SDK
    @available(iOS 27.1, *)
    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        if isExpanded {
            if let leading = items.leading {
                ToolbarItem(placement: .bottomBar) { leading.environment(\.cantripSystemBarItem, true) }
                    .axisBehavior(.verticalPreferred)
            }
            ToolbarItem(placement: .bottomBar) { items.settings.environment(\.cantripSystemBarItem, true) }
                .axisBehavior(.verticalPreferred)
                .visibilityPriority(.low)
            if let mac = items.mac {
                ToolbarItem(placement: .bottomBar) { mac.environment(\.cantripSystemBarItem, true) }
                    .axisBehavior(.verticalPreferred)
                    .visibilityPriority(.low)
            }
            ToolbarItem(placement: .bottomBar) { items.menu.environment(\.cantripSystemBarItem, true) }
                .axisBehavior(.verticalPreferred)
                .visibilityPriority(.low)
            if let sections = items.sections {
                sectionItem(.chat, sections)
                sectionItem(.tasks, sections)
                sectionItem(.artifacts, sections)
                #if os(iOS)
                sectionItem(.builds, sections)
                #endif
            }
        } else {
            ToolbarItem(placement: .bottomBar) {
                CantripDuoBarPill(summary: items.summary, onExpand: expand)
            }
            .axisBehavior(.verticalPreferred)
        }
    }

    @available(iOS 27.1, *)
    private func sectionItem(_ section: CantripHomeSection, _ sections: CantripDuoBarSections) -> some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            CantripDuoBarSectionButton(section: section, sections: sections, onChoose: choose)
        }
        .axisBehavior(.verticalPreferred)
        .visibilityPriority(.high)
    }
    #endif
}

/// Minimizes the expanded bar on a tap or a scroll anywhere outside it. Watches the window without
/// taking its touches (nothing else misses a tap); installed only while the bar is expanded.
struct CantripDuoBarDismissal: View {
    let isActive: Bool
    /// The app-drawn rail's width at the trailing edge; nil where the system's vertical bar holds
    /// the bar (its own edge and width are read from the window).
    var appRailWidth: CGFloat? = nil
    let onDismiss: () -> Void

    var body: some View {
        #if os(iOS)
        CantripDuoBarDismissalProbe(isActive: isActive, appRailWidth: appRailWidth, onDismiss: onDismiss)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        #else
        EmptyView()
        #endif
    }
}

#if os(iOS)
private struct CantripDuoBarDismissalProbe: UIViewRepresentable {
    let isActive: Bool
    let appRailWidth: CGFloat?
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ view: Probe, context: Context) {
        view.appRailWidth = appRailWidth
        view.onDismiss = onDismiss
        view.isActive = isActive
    }

    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.isActive = false }

    final class Probe: UIView, UIGestureRecognizerDelegate {
        var appRailWidth: CGFloat?
        var onDismiss: (() -> Void)?
        var isActive = false { didSet { if isActive != oldValue { install() } } }
        private lazy var tap: UITapGestureRecognizer = recognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        private lazy var pan: UIPanGestureRecognizer = recognizer(UIPanGestureRecognizer(target: self, action: #selector(panned)))
        private weak var installedWindow: UIWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            install()
        }

        private func recognizer<R: UIGestureRecognizer>(_ recognizer: R) -> R {
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            return recognizer
        }

        private func install() {
            if let installedWindow, installedWindow !== window || !isActive {
                installedWindow.removeGestureRecognizer(tap)
                installedWindow.removeGestureRecognizer(pan)
                self.installedWindow = nil
            }
            guard isActive, let window, installedWindow == nil else { return }
            window.addGestureRecognizer(tap)
            window.addGestureRecognizer(pan)
            installedWindow = window
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended { onDismiss?() }
        }

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began { onDismiss?() }
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let window = installedWindow else { return false }
            return !barRegion(in: window).contains(touch.location(in: window))
        }

        /// The edge column holding the bar: the system's vertical bar (its side's safe-area inset)
        /// or the app-drawn rail at the trailing edge.
        private func barRegion(in window: UIWindow) -> CGRect {
            let bounds = window.bounds
            let insets = window.safeAreaInsets
            if let appRailWidth {
                let width = appRailWidth + insets.right
                return CGRect(x: bounds.maxX - width, y: 0, width: width, height: bounds.height)
            }
            // The vertical bar is the wide horizontal inset (about 84 pt); the other edge has none.
            if insets.left > insets.right {
                return CGRect(x: 0, y: 0, width: insets.left, height: bounds.height)
            }
            return CGRect(x: bounds.maxX - insets.right, y: 0, width: insets.right, height: bounds.height)
        }
    }
}
#endif
