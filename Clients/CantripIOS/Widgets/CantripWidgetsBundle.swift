import SwiftUI
import WidgetKit

@main
struct CantripWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CantripTabsWidget()
        CantripTabsLiveActivity()
    }
}
