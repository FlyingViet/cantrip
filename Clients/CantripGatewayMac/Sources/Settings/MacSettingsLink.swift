import SwiftUI

/// What opens Settings when the window has no SwiftUI Settings scene: inside Cantrip.app (the Home
/// window plug-in) the plug-in sets it to its own Settings window. Nil in Cantrip Gateway Mac.
private struct MacOpenSettingsKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    var macOpenSettings: (@MainActor () -> Void)? {
        get { self[MacOpenSettingsKey.self] }
        set { self[MacOpenSettingsKey.self] = newValue }
    }
}

/// `SettingsLink`, or a button running `macOpenSettings` where the host app supplies one.
struct MacSettingsLink<Label: View>: View {
    @Environment(\.macOpenSettings) private var openSettings
    private let label: Label

    init(@ViewBuilder label: () -> Label) {
        self.label = label()
    }

    var body: some View {
        if let openSettings {
            Button { openSettings() } label: { label }
        } else {
            SettingsLink { label }
        }
    }
}
