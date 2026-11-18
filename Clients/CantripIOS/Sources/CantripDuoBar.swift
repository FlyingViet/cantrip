import SwiftUI

/// Home's sections in the iPhone Duo's navigation bar.
struct CantripDuoBarSections {
    var selection: Binding<CantripHomeSection>
    var runningTasks: Int
}

/// The iPhone Duo's one navigation bar on the screen's edge, in every pose, always open: the tab list
/// or sidebar toggle, Settings, View Mac and the menu. Folded, Home's sections (Chat, Tasks, Artifacts,
/// Builds) follow at the bottom; unfolded they are in the sidebar, so the bar holds only actions.
struct CantripDuoBarItems {
    /// The sidebar toggle (unfolded) or the Tabs button (folded).
    var leading: AnyView?
    var settings: AnyView
    var mac: AnyView?
    var menu: AnyView
    /// Home's sections; nil in a tab and on the unfolded Duo (`showsSections`).
    var sections: CantripDuoBarSections?

    /// Home's sections go on the bar only while the Duo is folded: unfolded, the sidebar lists them.
    static func showsSections(inHome: Bool, unfolded: Bool) -> Bool { inHome && !unfolded }
}

/// Which items the system's vertical bar holds; the toolbar is rebuilt when it changes (posture,
/// Home or a tab, View Mac).
struct CantripDuoBarLayout: Hashable {
    let toolbar: ChatToolbarLayout
    let hasLeading: Bool
    let hasMac: Bool
    let hasSections: Bool
}

/// One of Home's sections on the folded Duo's bar.
struct CantripDuoBarSectionButton: View {
    let section: CantripHomeSection
    let sections: CantripDuoBarSections
    let onChoose: (CantripHomeSection) -> Void

    private var isSelected: Bool { sections.selection.wrappedValue == section }

    var body: some View {
        Button { onChoose(section) } label: {
            Image(systemName: section.systemImage)
                .symbolVariant(isSelected ? .fill : .none)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .contentShape(Rectangle())
        }
        .tint(isSelected ? .accentColor : .primary)
        .badge(section == .tasks ? sections.runningTasks : 0)
        .accessibilityLabel(section.title)
        .accessibilityValue(section == .tasks && sections.runningTasks > 0 ? "\(sections.runningTasks) running" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("duo.bar.section.\(section.rawValue)")
    }
}

/// The bar in the system's vertical bar (folded, and unfolded on its side): one group of items at
/// the bottom of the bar, always shown. The system draws it; sections keep their place when the bar is
/// short, and the actions move into its overflow (…) first.
struct CantripDuoVerticalBar: ViewModifier {
    let items: CantripDuoBarItems

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

    private func choose(_ section: CantripHomeSection) {
        items.sections?.selection.wrappedValue = section
    }

    #if AGENTGATEWAY_DUO_SDK
    @available(iOS 27.1, *)
    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
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
