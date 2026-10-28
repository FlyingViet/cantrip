import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ChatDisplayTraits: Equatable {
    var hasVerticalBar = false
    /// The window (not the keyboard-shortened content) is wider than tall.
    var isLandscape = false
    /// iPhone Duo folded shut, on its outer display: the iPhone layout in either orientation.
    var isFolded = false
    /// False on iPad, which keeps its own split navigation.
    var allowsSidebarLayout = true

    /// iPhone Duo unfolded on its side: a Gateway Mac-style layout with a persistent sidebar and the
    /// chat's actions in its own header. Upright and folded windows and other iPhones keep today's.
    var usesSidebarLayout: Bool { allowsSidebarLayout && hasVerticalBar && isLandscape && !isFolded }

    /// Header actions go to the system's vertical bar, except in the sidebar layout.
    var placesActionsInVerticalBar: Bool { hasVerticalBar && !usesSidebarLayout }
}

private struct ChatDisplayTraitsKey: EnvironmentKey {
    static let defaultValue = ChatDisplayTraits()
}

extension EnvironmentValues {
    var chatDisplayTraits: ChatDisplayTraits {
        get { self[ChatDisplayTraitsKey.self] }
        set { self[ChatDisplayTraitsKey.self] = newValue }
    }
}

struct ChatDisplayObserver: ViewModifier {
    @State private var traits = ChatDisplayTraits()
    /// Reports the traits to the view applying the observer, which can't read this environment.
    var onChange: (ChatDisplayTraits) -> Void = { _ in }

    func body(content: Content) -> some View {
        content
            .environment(\.chatDisplayTraits, traits)
            .onChange(of: traits, initial: true) { _, value in onChange(value) }
            .onAppear {
                #if os(iOS)
                traits.allowsSidebarLayout = UIDevice.current.userInterfaceIdiom == .phone
                #endif
            }
            .background {
                #if os(iOS)
                // The window's own shape: the keyboard never turns a portrait window landscape.
                ChatWindowShapeObserver { traits.isLandscape = $0 }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                #else
                Color.clear
                    .ignoresSafeArea()
                    .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: {
                        traits.isLandscape = $0
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                #endif
            }
            .background {
                #if AGENTGATEWAY_DUO_SDK
                if #available(iOS 27.1, *) {
                    ChatVerticalBarObserver { traits.hasVerticalBar = $0 }
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                #endif
            }
            .modifier(ChatHingeObserver { traits.isFolded = $0 })
    }
}

/// Reports whether an iPhone Duo is folded shut; never on other devices.
private struct ChatHingeObserver: ViewModifier {
    let onChange: (Bool) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        #if AGENTGATEWAY_DUO_SDK
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, context in onChange(context.hinge?.status == .closed) }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if os(iOS)
/// The hosting window's bounds, which (unlike the safe area) don't shrink for the keyboard.
private struct ChatWindowShapeObserver: UIViewRepresentable {
    let onChange: (Bool) -> Void

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ view: Probe, context: Context) {
        view.onChange = onChange
        view.report()
    }

    final class Probe: UIView {
        var onChange: ((Bool) -> Void)?
        private var reportedValue: Bool?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        func report() {
            // Deliver after SwiftUI's update; rotating or unfolding resizes this view and lays it out.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                let value = window.bounds.width > window.bounds.height
                guard value != self.reportedValue else { return }
                self.reportedValue = value
                self.onChange?(value)
            }
        }
    }
}
#endif

struct ChatAdaptiveToolbar: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if AGENTGATEWAY_DUO_SDK
        if #available(iOS 27.1, *) {
            content.toolbarVerticalBehavior(.automatic)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

struct ChatNavigationActions<Leading: View, Refresh: View, Settings: View, Trailing: View>: ViewModifier {
    @Environment(\.chatDisplayTraits) private var displayTraits
    var showsHorizontalBar = false
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var refresh: () -> Refresh
    @ViewBuilder var settings: () -> Settings
    @ViewBuilder var trailing: () -> Trailing

    private var usesVerticalBar: Bool { displayTraits.placesActionsInVerticalBar }

    func body(content: Content) -> some View {
        content
            .toolbar(usesVerticalBar || showsHorizontalBar ? .visible : .hidden, for: .navigationBar)
            .toolbar(usesVerticalBar ? .visible : .hidden, for: .bottomBar)
            .toolbar { actions }
            .modifier(ChatAdaptiveToolbar())
    }

    @ToolbarContentBuilder private var actions: some ToolbarContent {
        #if AGENTGATEWAY_DUO_SDK
        if #available(iOS 27.1, *), usesVerticalBar {
            ToolbarItem(placement: .bottomBar) { leading() }
                .axisBehavior(.verticalPreferred)
            ToolbarItem(placement: .topBarTrailing) { settings() }
                .axisBehavior(.verticalPreferred)
            ToolbarItem(placement: .topBarTrailing) { refresh() }
                .axisBehavior(.verticalPreferred)
            ToolbarItem(placement: .topBarTrailing) { trailing() }
                .axisBehavior(.verticalPreferred)
        } else {
            horizontalActions
        }
        #else
        horizontalActions
        #endif
    }

    @ToolbarContentBuilder private var horizontalActions: some ToolbarContent {
        if showsHorizontalBar {
            ToolbarItem(placement: .topBarLeading) { leading() }
            ToolbarItem(placement: .topBarTrailing) { trailing() }
        }
    }
}

#if AGENTGATEWAY_DUO_SDK
@available(iOS 27.1, *)
private struct ChatVerticalBarObserver: UIViewRepresentable {
    let onChange: (Bool) -> Void

    func makeUIView(context: Context) -> Probe {
        Probe()
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.onChange = onChange
        view.report()
    }

    final class Probe: UIView {
        var onChange: ((Bool) -> Void)?
        private var reportedValue: Bool?

        init() {
            super.init(frame: .zero)
            registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) {
                (view: Probe, _: UITraitCollection) in view.report()
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        func report() {
            // Deliver after SwiftUI's update, using this window's current traits.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                let value = self.traitCollection.verticalBarEdge != .unspecified
                guard value != self.reportedValue else { return }
                self.reportedValue = value
                self.onChange?(value)
            }
        }
    }
}
#endif
