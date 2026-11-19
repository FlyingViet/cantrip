import SwiftUI

/// The iPhone Duo's one navigation bar on the screen's edge, in every pose, always open, holding only
/// actions: the tab list (folded) or sidebar toggle (unfolded), Settings, View Mac and the menu. Home's
/// sections (Chat, Tasks, Artifacts, Builds) are in the sidebar unfolded and in the tab drawer folded
/// (`CantripHomeDrawerSections`).
struct CantripDuoBarItems {
    /// The sidebar toggle (unfolded) or the Tabs button (folded).
    var leading: AnyView?
    var settings: AnyView
    var mac: AnyView?
    var menu: AnyView
}

/// Which items the system's vertical bar holds; the toolbar is rebuilt when it changes (posture,
/// Home or a tab, View Mac).
struct CantripDuoBarLayout: Hashable {
    let toolbar: ChatToolbarLayout
    let hasLeading: Bool
    let hasMac: Bool
}

/// The bar in the system's vertical bar (folded, and unfolded on its side): one group of items at
/// the bottom of the bar, always shown. The system draws it; when the bar is short, Settings, View Mac
/// and the menu move into its overflow (…) before the tab list or sidebar toggle.
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
    }
    #endif
}
