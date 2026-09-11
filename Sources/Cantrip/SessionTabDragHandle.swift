import AppKit
import SwiftUI

struct SessionTabDragHandle: NSViewRepresentable {
    let id: UUID
    let title: String
    let onSelect: () -> Void

    func makeNSView(context: Context) -> SessionTabDragView {
        let view = SessionTabDragView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SessionTabDragView, context: Context) {
        view.tabID = id
        view.title = title
        view.onSelect = onSelect
    }
}

class SessionTabDragView: NSView, NSDraggingSource {
    var tabID = UUID()
    var title = ""
    var onSelect: () -> Void = {}
    private var mouseDownEvent: NSEvent?
    private var isDraggingTab = false
    private weak var dragPanel: LauncherPanel?

    // A borderless panel otherwise steals SwiftUI's drag before it can lift the tab.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        isDraggingTab = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent, !isDraggingTab,
              hypot(event.locationInWindow.x - start.locationInWindow.x,
                    event.locationInWindow.y - start.locationInWindow.y) >= 4 else { return }
        mouseDownEvent = nil
        isDraggingTab = true
        beginTabDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldSelect = mouseDownEvent != nil && !isDraggingTab
            && bounds.contains(convert(event.locationInWindow, from: nil))
        mouseDownEvent = nil
        isDraggingTab = false
        if shouldSelect { onSelect() }
    }

    func draggingItem() -> NSDraggingItem {
        let payload = NSPasteboardItem()
        payload.setString("cantrip-tab:\(tabID.uuidString)", forType: .string)
        let item = NSDraggingItem(pasteboardWriter: payload)
        let image = NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (self.title as NSString).draw(
                in: rect.insetBy(dx: 10, dy: 4),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph
                ]
            )
            return true
        }
        item.setDraggingFrame(bounds, contents: image)
        return item
    }

    func beginTabDrag(with event: NSEvent) {
        dragPanel = window as? LauncherPanel
        dragPanel?.beginAttachedModalPresentation()
        beginDraggingSession(with: [draggingItem()], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move] : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        mouseDownEvent = nil
        isDraggingTab = false
        dragPanel?.endAttachedModalPresentation()
        dragPanel = nil
    }
}
