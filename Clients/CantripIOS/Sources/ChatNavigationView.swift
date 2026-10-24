import SwiftUI

struct ChatNavigationView<Sidebar: View, Content: View, PersistentSidebar: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var isTabListPresented: Bool
    let hasTabs: Bool
    let canSelectTabs: Bool
    var isReorderingTabs = false
    var allowsSidebar = UIDevice.current.userInterfaceIdiom == .pad
    /// iPhone Duo unfolded on its side: a Gateway Mac-style sidebar beside the one stack, in place
    /// of the drawer. The stack keeps its identity, so drafts and scroll positions survive folding.
    var showsPersistentSidebar = false
    @ViewBuilder var sidebar: (_ isModal: Bool, _ dismiss: @escaping () -> Void) -> Sidebar
    @ViewBuilder var content: () -> Content
    @ViewBuilder var persistentSidebar: () -> PersistentSidebar

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var usesSidebar: Bool {
        allowsSidebar && hasTabs && horizontalSizeClass == .regular
    }

    private var splitVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { usesSidebar ? columnVisibility : .detailOnly },
            set: { if usesSidebar { columnVisibility = $0 } }
        )
    }

    private var drawerPresentation: Binding<Bool> {
        Binding(
            get: { !usesSidebar && !showsPersistentSidebar && hasTabs && isTabListPresented },
            set: { isTabListPresented = $0 }
        )
    }

    var body: some View {
        Group {
            // Device idiom is stable across folding; size-dependent stacks would
            // recreate the transcript and its scroll position.
            if allowsSidebar {
                splitNavigation
            } else {
                HStack(spacing: 0) {
                    if showsPersistentSidebar {
                        persistentSidebar()
                        Divider().ignoresSafeArea()
                    }
                    NavigationStack { content() }
                }
            }
        }
        .cantripTabDrawer(
            isPresented: drawerPresentation,
            isEnabled: hasTabs && (canSelectTabs || isReorderingTabs) && !usesSidebar && !showsPersistentSidebar
        ) {
            sidebar(true, { isTabListPresented = false })
        }
        .onChange(of: usesSidebar) { _, _ in
            isTabListPresented = false
            columnVisibility = .all
        }
        .onChange(of: hasTabs) { _, _ in
            isTabListPresented = false
        }
        .onChange(of: showsPersistentSidebar) { _, _ in
            isTabListPresented = false
        }
        .onChange(of: isTabListPresented) { _, presented in
            if usesSidebar && presented {
                columnVisibility = .all
                isTabListPresented = false
            }
        }
    }

    private var splitNavigation: some View {
        NavigationSplitView(
            columnVisibility: splitVisibility,
            preferredCompactColumn: .constant(.detail)
        ) {
            if hasTabs {
                sidebar(false, { columnVisibility = .detailOnly })
                    .disabled(!canSelectTabs)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 360)
                    .toolbar(.hidden, for: .navigationBar)
            }
        } detail: {
            content()
                .toolbar(removing: .sidebarToggle)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

extension ChatNavigationView where PersistentSidebar == EmptyView {
    @MainActor
    init(
        isTabListPresented: Binding<Bool>,
        hasTabs: Bool,
        canSelectTabs: Bool,
        isReorderingTabs: Bool = false,
        allowsSidebar: Bool? = nil,
        @ViewBuilder sidebar: @escaping (_ isModal: Bool, _ dismiss: @escaping () -> Void) -> Sidebar,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            isTabListPresented: isTabListPresented, hasTabs: hasTabs, canSelectTabs: canSelectTabs,
            isReorderingTabs: isReorderingTabs,
            allowsSidebar: allowsSidebar ?? (UIDevice.current.userInterfaceIdiom == .pad),
            showsPersistentSidebar: false,
            sidebar: sidebar, content: content, persistentSidebar: { EmptyView() }
        )
    }
}
