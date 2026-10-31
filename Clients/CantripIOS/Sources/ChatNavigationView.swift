import SwiftUI

struct ChatNavigationView<Sidebar: View, Content: View, PersistentSidebar: View, PersistentRail: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var isTabListPresented: Bool
    let hasTabs: Bool
    let canSelectTabs: Bool
    var isReorderingTabs = false
    var allowsSidebar = UIDevice.current.userInterfaceIdiom == .pad
    /// iPhone Duo unfolded on its side: a Gateway Mac-style sidebar beside the one stack, in place
    /// of the drawer. The stack keeps its identity, so drafts and scroll positions survive folding.
    var showsPersistentSidebar = false
    /// The persistent sidebar slides over the chat instead of narrowing it when the window can't
    /// fit both (split screen, or unfolded upright); this reports which, and closes it on a tap outside.
    var sidebarOverlays: Binding<Bool> = .constant(false)
    var dismissPersistentSidebar: () -> Void = {}
    @ViewBuilder var sidebar: (_ isModal: Bool, _ dismiss: @escaping () -> Void) -> Sidebar
    @ViewBuilder var content: () -> Content
    @ViewBuilder var persistentSidebar: () -> PersistentSidebar
    /// iPhone Duo unfolded upright: the app's navigation rail on the right edge (empty otherwise).
    @ViewBuilder var persistentRail: () -> PersistentRail

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var containerWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The chat keeps at least this width beside the sidebar; narrower, the sidebar overlays it.
    static var minimumChatWidthBesideSidebar: CGFloat { 400 }

    static func overlaysSidebar(containerWidth: CGFloat, sidebarWidth: CGFloat = CantripDuoSidebar.width) -> Bool {
        containerWidth > 0 && containerWidth - sidebarWidth < minimumChatWidthBesideSidebar
    }

    private var overlays: Bool { Self.overlaysSidebar(containerWidth: containerWidth) }

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
                    if showsPersistentSidebar, !overlays {
                        persistentSidebar()
                        Divider().ignoresSafeArea()
                    }
                    NavigationStack { content() }
                    persistentRail()
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
                .overlay(alignment: .leading) { overlaySidebar }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: showsPersistentSidebar && overlays)
                .onChange(of: overlays, initial: true) { _, value in sidebarOverlays.wrappedValue = value }
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

    /// The sidebar over a dimmed chat, for windows too narrow to show both side by side.
    @ViewBuilder private var overlaySidebar: some View {
        if showsPersistentSidebar, overlays {
            ZStack(alignment: .leading) {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismissPersistentSidebar)
                    .gesture(DragGesture(minimumDistance: 20).onEnded { value in
                        if CantripDrawerGesture.shouldClose(translation: value.translation) { dismissPersistentSidebar() }
                    })
                    .accessibilityHidden(true)
                    .transition(.opacity)
                HStack(spacing: 0) {
                    persistentSidebar()
                    Divider().ignoresSafeArea()
                }
                // A swipe left anywhere over the sidebar puts it away, as over the dimmed chat.
                .cantripSwipeAwayGesture(dismissPersistentSidebar)
                .accessibilityAddTraits(.isModal)
                .accessibilityAction(.escape, dismissPersistentSidebar)
                .transition(reduceMotion ? .opacity : .move(edge: .leading))
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

extension ChatNavigationView where PersistentSidebar == EmptyView, PersistentRail == EmptyView {
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
            sidebar: sidebar, content: content, persistentSidebar: { EmptyView() },
            persistentRail: { EmptyView() }
        )
    }
}
