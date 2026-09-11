import AppKit
import SwiftUI

private final class TabDragSpy: SessionTabDragView {
    var drags = 0
    override func beginTabDrag(with event: NSEvent) { drags += 1 }
}

extension SessionTabTests {
    @MainActor
    static func testNativeTabDragging() throws {
        _ = NSApplication.shared
        let panel = LauncherPanel()
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = TabDragSpy(frame: NSRect(x: 0, y: 0, width: 160, height: 28))
        panel.contentView = view
        precondition(panel.isMovableByWindowBackground && !view.mouseDownCanMoveWindow)
        precondition(view.acceptsFirstMouse(for: nil), "Dragging must work before activating the panel")
        let originalFrame = panel.frame
        var selections = 0
        view.onSelect = { selections += 1 }
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat = 14) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        view.mouseDown(with: event(.leftMouseDown, 20))
        view.mouseDragged(with: event(.leftMouseDragged, 22))
        view.mouseUp(with: event(.leftMouseUp, 22))
        precondition(selections == 1 && view.drags == 0, "Small pointer jitter must remain a click")

        for x: CGFloat in [30, 5, 150] {
            view.mouseDown(with: event(.leftMouseDown, 20))
            view.mouseDragged(with: event(.leftMouseDragged, x))
            let count = view.drags
            view.mouseDragged(with: event(.leftMouseDragged, x + 10))
            precondition(view.drags == count, "One mouse gesture must lift only one tab")
            view.mouseUp(with: event(.leftMouseUp, x))
        }
        precondition(view.drags == 3 && selections == 1, "Dropping must not select the tab")
        view.mouseDragged(with: event(.leftMouseDragged, 100))
        precondition(view.drags == 3, "A completed gesture must not leave a stuck drag")
        view.mouseDown(with: event(.leftMouseDown, 20))
        view.mouseUp(with: event(.leftMouseUp, 20))
        precondition(selections == 2, "Selection must work after a drag")
        view.mouseDown(with: event(.leftMouseDown, 20))
        view.mouseUp(with: event(.leftMouseUp, -10))
        precondition(selections == 2, "Releasing outside the tab must cancel selection")
        precondition(panel.frame == originalFrame && panel.isMovableByWindowBackground,
                     "Tab gestures must not move the panel or change background dragging")

        let id = UUID()
        view.tabID = id
        view.title = "Duplicate title"
        let payload = view.draggingItem().item as! NSPasteboardItem
        precondition(payload.string(forType: .string) == "cantrip-tab:\(id.uuidString)",
                     "Native dragging must preserve the SwiftUI drop destination's stable-ID format")

        panel.install(
            Text("Tab label").padding(10)
                .overlay { SessionTabDragHandle(id: id, title: "Tab label", onSelect: {}) }
                .frame(width: 180, height: 40)
        )
        let root = panel.contentView!
        root.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        func handles(in view: NSView) -> [SessionTabDragView] {
            if let handle = view as? SessionTabDragView { return [handle] }
            return view.subviews.flatMap { handles(in: $0) }
        }
        let handle = handles(in: root).first!
        for point in [NSPoint(x: 1, y: 1),
                      NSPoint(x: handle.bounds.midX, y: handle.bounds.midY),
                      NSPoint(x: handle.bounds.maxX - 1, y: handle.bounds.maxY - 1)] {
            let hit = root.hitTest(root.convert(point, from: handle))
            precondition(hit === handle, "The label and padding must route mouse events to the native drag view")
        }
    }
}
