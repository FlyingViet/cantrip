import SwiftUI

/// A sheet's own navigation stack, or none when the same view is a page inside Settings (whose
/// navigation it then shares).
struct CantripSheetStack<Content: View>: View {
    let embedded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if embedded {
            content()
        } else {
            NavigationStack { content() }
        }
    }
}
