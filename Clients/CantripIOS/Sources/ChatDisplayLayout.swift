import SwiftUI
import UIKit

struct ChatDisplayTraits: Equatable {
    var hasVerticalBar = false
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

    func body(content: Content) -> some View {
        content
            .environment(\.chatDisplayTraits, traits)
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
    }
}

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

    private var usesVerticalBar: Bool { displayTraits.hasVerticalBar }

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
