import SwiftUI

struct ChatNavigationView<Sidebar: View, Content: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var isTabListPresented: Bool
    let hasTabs: Bool
    let canSelectTabs: Bool
    @ViewBuilder var sidebar: (_ isModal: Bool, _ dismiss: @escaping () -> Void) -> Sidebar
    @ViewBuilder var content: () -> Content

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var usesSidebar: Bool {
        hasTabs && horizontalSizeClass == .regular
    }

    private var splitVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { usesSidebar ? columnVisibility : .detailOnly },
            set: { if usesSidebar { columnVisibility = $0 } }
        )
    }

    private var drawerPresentation: Binding<Bool> {
        Binding(
            get: { !usesSidebar && hasTabs && isTabListPresented },
            set: { isTabListPresented = $0 }
        )
    }

    var body: some View {
        // Keep the detail in one navigation hierarchy as the window changes size.
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
        .cantripTabDrawer(
            isPresented: drawerPresentation,
            isEnabled: hasTabs && canSelectTabs && !usesSidebar
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
        .onChange(of: isTabListPresented) { _, presented in
            if usesSidebar && presented {
                columnVisibility = .all
                isTabListPresented = false
            }
        }
    }
}
