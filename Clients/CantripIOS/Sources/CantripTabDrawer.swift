import SwiftUI

enum CantripDrawerGesture {
    static func shouldOpen(start: CGPoint, translation: CGSize) -> Bool {
        (0...24).contains(start.x)
            && translation.width >= 50
            && translation.width > abs(translation.height) * 1.5
    }

    static func shouldClose(translation: CGSize) -> Bool {
        translation.width <= -50
            && -translation.width > abs(translation.height) * 1.5
    }

    static func panelWidth(available: CGFloat) -> CGFloat {
        min(380, max(0, available - 44))
    }
}

extension View {
    /// A deliberate right swipe from the left edge, e.g. from a project tab back to Home.
    func cantripEdgeSwipe(isEnabled: Bool, perform action: @escaping () -> Void) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if isEnabled, CantripDrawerGesture.shouldOpen(
                        start: value.startLocation, translation: value.translation
                    ) {
                        action()
                    }
                },
            isEnabled: isEnabled
        )
    }

    func cantripTabDrawer<Panel: View>(
        isPresented: Binding<Bool>,
        isEnabled: Bool,
        @ViewBuilder panel: @escaping () -> Panel
    ) -> some View {
        modifier(CantripTabDrawer(
            isPresented: isPresented, isEnabled: isEnabled, panel: panel
        ))
    }
}

private struct CantripTabDrawer<Panel: View>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Binding var isPresented: Bool
    let isEnabled: Bool
    @ViewBuilder var panel: () -> Panel

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!isPresented)
            .accessibilityHidden(isPresented)
            // Observe alongside transcript scrolling; only a horizontal edge swipe opens tabs.
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        if isEnabled, !isPresented,
                           CantripDrawerGesture.shouldOpen(
                            start: value.startLocation, translation: value.translation
                           ) {
                            isPresented = true
                        }
                    }
            )
            .overlay {
                GeometryReader { geometry in
                    ZStack(alignment: layoutDirection == .leftToRight ? .leading : .trailing) {
                        if isPresented {
                            Color.black.opacity(0.4)
                                .ignoresSafeArea()
                                .contentShape(Rectangle())
                                .onTapGesture { isPresented = false }
                                .gesture(
                                    DragGesture(minimumDistance: 20)
                                        .onEnded { value in
                                            if CantripDrawerGesture.shouldClose(translation: value.translation) {
                                                isPresented = false
                                            }
                                        }
                                )
                                .accessibilityHidden(true)
                                .transition(.opacity)
                        }
                        if isPresented {
                            panel()
                                .frame(width: CantripDrawerGesture.panelWidth(available: geometry.size.width))
                                .frame(maxHeight: .infinity)
                                .background(.regularMaterial)
                                .accessibilityElement(children: .contain)
                                .accessibilityAddTraits(.isModal)
                                .accessibilityAction(.escape) { isPresented = false }
                                .accessibilityIdentifier("cantrip-tab-drawer")
                                .transition(reduceMotion ? .opacity : .offset(x: -geometry.size.width))
                        }
                    }
                    .allowsHitTesting(isPresented)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: isPresented)
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isPresented = false }
            }
    }
}

struct CantripSessionDrawer: View {
    @ObservedObject var model: CantripRemoteModel
    var isModal = true
    let onDismiss: () -> Void
    let onSelect: (String) -> Void
    let onCreate: () -> Void
    let onRename: (CantripRemoteSession) -> Void
    let onClose: (String) -> Void
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tabs")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Close tabs")
            }
            .padding(.horizontal)
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        if isModal, CantripDrawerGesture.shouldClose(translation: value.translation) {
                            onDismiss()
                        }
                    }
            )

            Divider()
            if model.sessions.isEmpty {
                ContentUnavailableView("No Tabs", systemImage: "rectangle.stack",
                                       description: Text("Create a tab to start a conversation."))
            } else {
                CantripTabList(
                    sessions: model.sessions,
                    selectedSessionID: model.selectedSessionID,
                    onSelect: { id in
                        if isModal { onDismiss() }
                        onSelect(id)
                    },
                    onMove: { id, targetID, after in
                        Task { await model.moveTab(id, relativeTo: targetID, after: after) }
                    }
                ) { session in
                    CantripTabActions(
                        model: model, session: session,
                        onRename: {
                            if isModal { onDismiss() }
                            onRename(session)
                        },
                        onClose: { onClose(session.id) }
                    )
                }
                .disabled(model.isMutating)
            }
            Divider()
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .accessibilityIdentifier("cantrip-tab-error")
            }
            if model.isConfigured {
                CantripLiveActivityToggle()
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            Button(action: {
                if isModal { onDismiss() }
                onCreate()
            }) {
                Label("New Tab", systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!model.isConfigured || model.isMutating)
            .padding()
        }
        .onAppear { titleFocused = isModal }
    }
}

struct CantripTabList<Actions: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let sessions: [CantripRemoteSession]
    let selectedSessionID: String?
    let onSelect: (String) -> Void
    var onMove: ((String, String, Bool) -> Void)? = nil
    /// Rows above the tabs that scroll with them (Home's pinned rows), never reorderable.
    var header: (() -> AnyView)? = nil
    @ViewBuilder var actions: (CantripRemoteSession) -> Actions

    var selectedSession: CantripRemoteSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if let header {
                    header()
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                ForEach(sessions) { session in
                    row(session)
                        .id(session.id)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .moveDisabled(onMove == nil || session.supportsTabReordering != true || sessions.count < 2)
                }
                .onMove { source, destination in
                    move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: sessions.map(\.id))
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.top)
            .onChange(of: selectedSessionID, initial: true) { _, _ in
                if let selectedSession { proxy.scrollTo(selectedSession.id, anchor: .center) }
            }
        }
        .accessibilityIdentifier("cantrip-tab-list")
    }

    private func row(_ session: CantripRemoteSession) -> some View {
        let selected = session.id == selectedSessionID
        let detail = CantripTabRowText.detail(for: session)
        return Button { onSelect(session.id) } label: {
            HStack(alignment: .top, spacing: 12) {
                CantripTabStatusIndicator(session: session)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        HStack(spacing: 4) {
                            if session.isLocalPrivate == true {
                                Image(systemName: "lock.shield.fill").font(.caption)
                            } else if session.isLocked == true {
                                Image(systemName: "lock.fill").font(.caption)
                            }
                            Text(session.title)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                        }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        CantripTabAgeText(date: session.lastActivityDate)
                    }
                    if let detail {
                        Text(detail.text)
                            .font(.subheadline)
                            .foregroundStyle(detail.isActive ? CantripHomeBackgroundStyle.activeTint : Color.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cantrip-tab-\(session.id)")
        .accessibilityLabel(CantripSessionPicker.accessibilityTitle(for: session))
        .accessibilityValue(session.tabRowAccessibilityValue)
        .accessibilityHint("Opens this tab. Touch and hold for tab actions.")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .contextMenu { actions(session) }
    }

    @discardableResult
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) -> Bool {
        guard let onMove,
              let move = CantripTabReorder.move(sessions, fromOffsets: offsets, toOffset: destination)
        else { return false }
        onMove(move.id, move.targetID, move.after)
        return true
    }
}

enum CantripTabReorder {
    /// A `List.onMove` drop as the tab to move, the tab it lands beside and whether it goes after
    /// it. Nil for no-op drops, multi-row drags and hosts that cannot reorder tabs.
    static func move(
        _ sessions: [CantripRemoteSession], fromOffsets offsets: IndexSet, toOffset destination: Int
    ) -> (id: String, targetID: String, after: Bool)? {
        guard offsets.count == 1, let source = offsets.first,
              sessions.indices.contains(source), (0...sessions.count).contains(destination),
              destination != source, destination != source + 1 else { return nil }
        let target = source < destination ? destination - 1 : destination
        guard sessions[source].supportsTabReordering == true,
              sessions[target].supportsTabReordering == true else { return nil }
        return (sessions[source].id, sessions[target].id, source < target)
    }
}
