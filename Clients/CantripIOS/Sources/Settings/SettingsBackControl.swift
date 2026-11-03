import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A page opened from a row inside Settings. On the Mac there's no swipe back, so its toolbar gets
/// a back chevron at the leading edge, named for the page it returns to ("Back to About & Updates"),
/// that also answers ⌘[ and Esc. Esc in a text field first ends the edit (as clicking away does);
/// the next Esc goes back. iOS keeps its navigation bar's back button and swipe.
struct SettingsBackControl: ViewModifier {
    let parent: String
    @Environment(\.dismiss) private var dismiss

    static func label(_ parent: String) -> String { "Back to \(parent)" }

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        dismiss()
                    } label: {
                        Label(Self.label(parent), systemImage: "chevron.backward")
                            .labelStyle(.iconOnly)
                    }
                    .help("\(Self.label(parent)) (⌘[)")
                    .accessibilityLabel(Self.label(parent))
                    .accessibilityIdentifier("settings.back")
                    .keyboardShortcut("[", modifiers: .command)
                }
            }
            .background {
                Button(Self.label(parent), action: escape)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        #else
        content
        #endif
    }

    #if os(macOS)
    private func escape() {
        if let window = NSApp.keyWindow, window.firstResponder is NSText {
            window.makeFirstResponder(nil)
        } else {
            dismiss()
        }
    }
    #endif
}

extension View {
    /// See `SettingsBackControl`.
    func settingsBack(to parent: String) -> some View {
        modifier(SettingsBackControl(parent: parent))
    }
}
