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
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 20)
                            .onEnded { value in
                                if CantripDrawerGesture.shouldClose(translation: value.translation) {
                                    isPresented = false
                                }
                            }
                    )
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

            Divider()
            if model.sessions.isEmpty {
                ContentUnavailableView("No Tabs", systemImage: "rectangle.stack",
                                       description: Text("Create a tab to start a conversation."))
            } else {
                CantripTabList(
                    sessions: model.sessions,
                    selectedSessionID: model.selectedSessionID,
                    onSelect: { id in
                        onDismiss()
                        onSelect(id)
                    }
                ) { session in
                    CantripTabActions(
                        model: model, session: session,
                        onRename: {
                            onDismiss()
                            onRename(session)
                        },
                        onClose: { onClose(session.id) }
                    )
                }
                .disabled(model.isMutating)
            }
            Divider()
            Button(action: {
                onDismiss()
                onCreate()
            }) {
                Label("New Tab", systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!model.isConfigured || model.isMutating)
            .padding()
        }
        .onAppear { titleFocused = true }
    }
}

struct CantripTabList<Actions: View>: View {
    let sessions: [CantripRemoteSession]
    let selectedSessionID: String?
    let onSelect: (String) -> Void
    @ViewBuilder var actions: (CantripRemoteSession) -> Actions

    var selectedSession: CantripRemoteSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(sessions) { session in
                        row(session)
                            .id(session.id)
                    }
                }
                .padding(8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.top)
            .onAppear {
                if let selectedSession { proxy.scrollTo(selectedSession.id, anchor: .center) }
            }
        }
        .accessibilityIdentifier("cantrip-tab-list")
    }

    private func row(_ session: CantripRemoteSession) -> some View {
        HStack(spacing: 0) {
            Button { onSelect(session.id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: session.id == selectedSessionID ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        CantripSessionTitle(title: session.title, isStreaming: session.isStreaming)
                            .font(.body.weight(.semibold))
                            .lineLimit(3)
                        let status = CantripSessionPicker.statusSummary(for: session)
                        if !status.isEmpty {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("cantrip-tab-\(session.id)")
            .accessibilityLabel(CantripSessionPicker.accessibilityTitle(for: session))
            .accessibilityValue(CantripSessionPicker.statusSummary(for: session))
            .accessibilityAddTraits(session.id == selectedSessionID ? [.isSelected] : [])
            .contextMenu { actions(session) }

            Menu { actions(session) } label: {
                Image(systemName: "ellipsis")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions for \(session.title)")
        }
        .background(
            session.id == selectedSessionID ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12)
        )
    }
}
