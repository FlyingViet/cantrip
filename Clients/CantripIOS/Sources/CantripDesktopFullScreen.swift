import SwiftUI

/// Where the Mac's screen sits in full screen: as large as fits (times the zoom), and which spot on
/// the Mac a tap means.
enum CantripDesktopFit {
    static func size(image: CGSize, in container: CGSize, zoom: Int) -> CGSize {
        guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / image.width, container.height / image.height) * CGFloat(max(zoom, 1))
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    /// The tap as a fraction of the screen's width and height; nil outside it.
    static func point(_ location: CGPoint, in size: CGSize) -> CGPoint? {
        guard size.width > 0, size.height > 0,
              (0...size.width).contains(location.x), (0...size.height).contains(location.y) else { return nil }
        return CGPoint(x: min(location.x / size.width, 0.999999), y: min(location.y / size.height, 0.999999))
    }

    /// "4:05": what's left of the five-minute session.
    static func remaining(until expiresAt: Double, now: Date) -> String {
        let seconds = max(0, Int((expiresAt - now.timeIntervalSince1970).rounded(.up)))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

#if os(iOS)
import UIKit

/// The full-screen Mac: the screen edge to edge, with a toolbar that drops down from the top.
/// Its keyboard sends each key to the Mac as it's typed.
struct CantripDesktopFullScreenView: View {
    @ObservedObject var desktop: CantripDesktopModel
    @Binding var clickKind: String
    @Binding var zoom: Int
    let onExit: () -> Void
    @State private var toolbarShown = true
    @State private var keyboardShown = false

    private var control: Bool { desktop.lease?.control == true }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            screen
                // Edge to edge, but above the keyboard so what's typed stays in view.
                .ignoresSafeArea(.container)
            VStack(spacing: 8) {
                if toolbarShown {
                    toolbar.transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    handle.transition(.opacity)
                }
                if let error = desktop.error {
                    Button { desktop.error = nil } label: {
                        Text(error)
                            .font(.footnote)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: 520, alignment: .leading)
                            .background(Color.orange, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Dismisses the message")
                    .accessibilityIdentifier("desktop.fullScreen.error")
                }
            }
            .padding(.top, 4)
            .padding(.horizontal, 8)
        }
        .background {
            if control {
                CantripDesktopKeyboard(isShown: $keyboardShown, desktop: desktop)
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
        }
        .animation(.snappy(duration: 0.25), value: toolbarShown)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .modifier(CantripDesktopHidesVerticalBar())
        .onChange(of: desktop.lease == nil) { _, ended in
            if ended { exit() }
        }
        .accessibilityAction(.escape) { exit() }
    }

    @ViewBuilder private var screen: some View {
        GeometryReader { geometry in
            if let image = desktop.image, let frame = desktop.frame {
                let size = CantripDesktopFit.size(image: CGSize(width: frame.width, height: frame.height),
                                                  in: geometry.size, zoom: zoom)
                ScrollView([.horizontal, .vertical], showsIndicators: zoom > 1) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { event in
                            guard control, let point = CantripDesktopFit.point(event.location, in: size) else { return }
                            Task {
                                await desktop.send(.init(frameID: frame.id, kind: clickKind,
                                                         x: Double(point.x), y: Double(point.y)))
                            }
                        })
                        .accessibilityLabel("Live Mac screen")
                        .accessibilityHint(control ? "Tap to click on the Mac." : "View only.")
                        .accessibilityIdentifier("desktop.fullScreen.screen")
                        // Centered while it's smaller than the window.
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }
                .scrollDisabled(zoom == 1)
                .scrollBounceBehavior(.basedOnSize)
            } else {
                ProgressView("Waiting for a screen frame…")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    // MARK: - Drop-down toolbar

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            toolbarRow(wide: true)
            toolbarRow(wide: false)
        }
        .padding(4)
        .glassEffect(.regular, in: Capsule())
        .environment(\.colorScheme, .dark)
        // Swipe it back up to get it out of the way.
        .simultaneousGesture(DragGesture(minimumDistance: 16).onEnded { value in
            if value.translation.height < -24 { toolbarShown = false }
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View Mac toolbar")
        .accessibilityIdentifier("desktop.fullScreen.toolbar")
    }

    private func toolbarRow(wide: Bool) -> some View {
        HStack(spacing: 0) {
            tool("Exit Full Screen", "arrow.down.right.and.arrow.up.left", id: "desktop.fullScreen.exit") { exit() }
            if control {
                tool(keyboardShown ? "Hide Keyboard" : "Show Keyboard",
                     keyboardShown ? "keyboard.chevron.compact.down" : "keyboard",
                     id: "desktop.fullScreen.keyboard") { keyboardShown.toggle() }
                tapActionMenu
                if wide {
                    ForEach(Self.keys, id: \.key) { key in
                        tool(key.title, key.symbol, id: "desktop.fullScreen.key.\(key.key)") { desktop.press(key.key) }
                    }
                    tool("Scroll Up", "arrow.up.to.line", id: "desktop.fullScreen.scrollUp") { scroll(3) }
                    tool("Scroll Down", "arrow.down.to.line", id: "desktop.fullScreen.scrollDown") { scroll(-3) }
                } else {
                    keysMenu
                }
            }
            viewMenu
            if let lease = desktop.lease {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(CantripDesktopFit.remaining(until: lease.expiresAt, now: context.date))
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 6)
                        .accessibilityLabel("Time left")
                }
            }
            tool("Hide Toolbar", "chevron.compact.up", id: "desktop.fullScreen.collapse") { toolbarShown = false }
        }
        .fixedSize()
    }

    private func tool(_ title: String, _ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    private static let tapActions: [(kind: String, title: String, symbol: String)] = [
        ("click", "Click", "cursorarrow.click"),
        ("doubleClick", "Double Click", "cursorarrow.click.2"),
        ("rightClick", "Right Click", "contextualmenu.and.cursorarrow"),
    ]

    private var tapActionMenu: some View {
        let current = Self.tapActions.first { $0.kind == clickKind } ?? Self.tapActions[0]
        return Menu {
            Picker("Tap Action", selection: $clickKind) {
                ForEach(Self.tapActions, id: \.kind) { Label($0.title, systemImage: $0.symbol).tag($0.kind) }
            }
        } label: {
            Image(systemName: current.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Tap Action")
        .accessibilityValue(current.title)
        .accessibilityIdentifier("desktop.fullScreen.tapAction")
    }

    private static let keys: [(key: String, title: String, symbol: String)] = [
        ("escape", "Escape", "escape"),
        ("tab", "Tab", "arrow.right.to.line"),
        ("return", "Return", "return"),
        ("delete", "Delete", "delete.left"),
        ("left", "Left Arrow", "arrow.left"),
        ("up", "Up Arrow", "arrow.up"),
        ("down", "Down Arrow", "arrow.down"),
        ("right", "Right Arrow", "arrow.right"),
    ]

    private var keysMenu: some View {
        Menu {
            Section("Keys") {
                ForEach(Self.keys, id: \.key) { key in
                    Button { desktop.press(key.key) } label: { Label(key.title, systemImage: key.symbol) }
                }
            }
            Section("Scroll") {
                Button { scroll(3) } label: { Label("Scroll Up", systemImage: "arrow.up.to.line") }
                Button { scroll(-3) } label: { Label("Scroll Down", systemImage: "arrow.down.to.line") }
            }
        } label: {
            Image(systemName: "command")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Keys and Scrolling")
        .accessibilityIdentifier("desktop.fullScreen.keys")
    }

    /// Zoom, and which display when the Mac has more than one.
    private var viewMenu: some View {
        Menu {
            Picker("Zoom", selection: $zoom) {
                Text("Fit").tag(1); Text("2×").tag(2); Text("3×").tag(3)
            }
            if let displays = desktop.lease?.displays, displays.count > 1 {
                Picker("Display", selection: $desktop.displayID) {
                    ForEach(displays) { Text($0.name).tag(Optional($0.id)) }
                }
            }
        } label: {
            Image(systemName: zoom > 1 ? "plus.magnifyingglass" : "display")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Zoom and Display")
        .accessibilityValue(zoom > 1 ? "\(zoom)×" : "Fit")
        .accessibilityIdentifier("desktop.fullScreen.view")
    }

    /// The toolbar folded away: a small tab to pull it back down.
    private var handle: some View {
        Button { toolbarShown = true } label: {
            Image(systemName: "chevron.compact.down")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 26)
                .background(.black.opacity(0.55), in: Capsule())
                .frame(minWidth: 88, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 8).onEnded { value in
            if value.translation.height > 16 { toolbarShown = true }
        })
        .accessibilityLabel("Show Toolbar")
        .accessibilityIdentifier("desktop.fullScreen.expand")
    }

    private func scroll(_ delta: Int) {
        guard let frame = desktop.frame else { return }
        Task { await desktop.send(.init(frameID: frame.id, kind: "scroll", delta: delta)) }
    }

    private func exit() {
        keyboardShown = false
        onExit()
    }
}

/// On the iPhone Duo, keeps the system's vertical bar from holding a column beside the Mac's screen.
private struct CantripDesktopHidesVerticalBar: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if AGENTGATEWAY_DUO_SDK
        if #available(iOS 27.1, *) {
            content.toolbarVerticalBehavior(.disabled)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - Keyboard

/// Takes the keyboard's input for the Mac. Nothing typed is shown, suggested, corrected or learned
/// on this device.
final class CantripDesktopKeyInputView: UIView, UIKeyInput {
    var onText: (String) -> Void = { _ in }
    var onDelete: () -> Void = {}
    var onKey: (String) -> Void = { _ in }
    var onResign: () -> Void = {}

    var hasText: Bool { true }
    func insertText(_ text: String) { onText(text) }
    func deleteBackward() { onDelete() }

    override var canBecomeFirstResponder: Bool { true }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign() }
        return resigned
    }

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var isSecureTextEntry: Bool = true

    /// A hardware keyboard's arrows and Escape.
    override var keyCommands: [UIKeyCommand]? {
        Self.hardwareKeys.keys.sorted().map { input in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(pressHardwareKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    private static let hardwareKeys: [String: String] = [
        UIKeyCommand.inputUpArrow: "up", UIKeyCommand.inputDownArrow: "down",
        UIKeyCommand.inputLeftArrow: "left", UIKeyCommand.inputRightArrow: "right",
        UIKeyCommand.inputEscape: "escape",
    ]

    @objc private func pressHardwareKey(_ command: UIKeyCommand) {
        if let input = command.input, let key = Self.hardwareKeys[input] { onKey(key) }
    }
}

struct CantripDesktopKeyboard: UIViewRepresentable {
    @Binding var isShown: Bool
    let desktop: CantripDesktopModel

    func makeUIView(context: Context) -> CantripDesktopKeyInputView {
        let view = CantripDesktopKeyInputView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: CantripDesktopKeyInputView, context: Context) {
        view.onText = { [desktop] in desktop.type($0) }
        view.onDelete = { [desktop] in desktop.deleteBackward() }
        view.onKey = { [desktop] in desktop.press($0) }
        // The keyboard's own dismiss key (iPad) hides it too.
        let shown = $isShown
        view.onResign = { if shown.wrappedValue { shown.wrappedValue = false } }
        if isShown, !view.isFirstResponder {
            DispatchQueue.main.async { if view.window != nil { view.becomeFirstResponder() } }
        } else if !isShown, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    static func dismantleUIView(_ view: CantripDesktopKeyInputView, coordinator: ()) {
        view.onResign = {}
        view.resignFirstResponder()
    }
}

// MARK: - Presentation

/// Hides the status bar (and the iPhone Duo's vertical bar) and the home indicator over the Mac.
final class CantripDesktopFullScreenController: UIHostingController<CantripDesktopFullScreenView> {
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .bottom }
}

@MainActor
enum CantripDesktopFullScreenPresenter {
    /// Covers the whole screen, over whatever shows View Mac (a sheet or a Settings page), which stays
    /// underneath with its session running.
    @discardableResult
    static func present(desktop: CantripDesktopModel, clickKind: Binding<String>, zoom: Binding<Int>) -> UIViewController? {
        guard let presenter = CantripImageViewerPresenter.topViewController() else { return nil }
        final class Holder { weak var controller: UIViewController? }
        let holder = Holder()
        let host = CantripDesktopFullScreenController(rootView: CantripDesktopFullScreenView(
            desktop: desktop, clickKind: clickKind, zoom: zoom,
            onExit: { holder.controller?.dismiss(animated: true) }
        ))
        host.modalPresentationStyle = .overFullScreen
        host.modalTransitionStyle = .crossDissolve
        host.modalPresentationCapturesStatusBarAppearance = true
        host.overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = .black
        host.view.accessibilityViewIsModal = true
        holder.controller = host
        presenter.present(host, animated: true) {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
        return host
    }
}
#endif
