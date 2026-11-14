import AppKit

extension SessionTabTests {
    /// Mac text-editing keys reach the composer: no main menu item takes them, and the panel's
    /// ⌘-arrows move like any Mac text field (to the ends of the line, then of the message) or,
    /// in an empty field, switch tabs.
    @MainActor
    static func testComposerKeys() throws {
        var items: [NSMenuItem] = []
        func collect(_ menu: NSMenu) {
            for item in menu.items {
                items.append(item)
                if let submenu = item.submenu { collect(submenu) }
            }
        }
        collect(AppDelegate.mainMenu(settingsTarget: NSObject()))
        let taken = items.filter { AppDelegate.textNavigationKeys.contains($0.keyEquivalent) }.map(\.title)
        precondition(taken.isEmpty, "menu items take text-editing keys: \(taken)")
        precondition(items.contains { $0.title == "Previous Tab" } && items.contains { $0.title == "Next Tab" }
                     && items.contains { $0.keyEquivalent == "a" && $0.title == "Select All" }, "the menu keeps its items")

        let command = NSEvent.ModifierFlags.command
        func arrow(_ key: UInt16, _ flags: NSEvent.ModifierFlags = .command, text: String? = "hi", composing: Bool = false)
            -> AppDelegate.CommandArrow {
            AppDelegate.commandArrow(keyCode: key, modifiers: flags, text: text, composing: composing)
        }
        precondition([123, 124, 125, 126].allSatisfy { arrow($0) == .edit } && arrow(123, [.command, .shift]) == .edit,
                     "with text, ⌘-arrows edit")
        precondition(arrow(123, text: "") == .previousTab && arrow(124, text: nil) == .nextTab
                     && arrow(125, text: "") == .pass && arrow(126, text: "") == .pass, "an empty field switches tabs")
        precondition(arrow(123, [.command, .option]) == .pass && arrow(124, [.command, .control]) == .pass
                     && arrow(123, .option) == .pass && arrow(0, command) == .pass && arrow(123, composing: true) == .pass,
                     "other modifiers, keys and input-method text pass through")

        // The standard key bindings move a field editor to the ends of the line, then the message.
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        editor.isFieldEditor = true
        editor.string = "alpha beta\ngamma\ndelta"
        func press(_ key: UInt16, _ scalar: Int, _ flags: NSEvent.ModifierFlags) -> NSRange {
            let chars = String(UnicodeScalar(scalar)!)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags.union([.numericPad, .function]),
                                         timestamp: 0, windowNumber: 0, context: nil, characters: chars,
                                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: key)!
            precondition(AppDelegate.commandArrow(keyCode: key, modifiers: flags, text: editor.string, composing: false) == .edit)
            editor.interpretKeyEvents([event])
            return editor.selectedRange()
        }
        editor.setSelectedRange(NSRange(location: 22, length: 0))
        precondition(press(123, 0xF702, command) == NSRange(location: 17, length: 0), "⌘← to the line's start: \(editor.selectedRange())")
        precondition(press(124, 0xF703, command) == NSRange(location: 22, length: 0), "⌘→ to the line's end")
        precondition(press(123, 0xF702, [.command, .shift]) == NSRange(location: 17, length: 5), "⇧⌘← selects to the line's start")
        precondition(press(126, 0xF700, command) == NSRange(location: 0, length: 0), "⌘↑ to the message's start")
        precondition(press(124, 0xF703, command) == NSRange(location: 10, length: 0), "⌘→ to the first line's end")
        precondition(press(125, 0xF701, command) == NSRange(location: 22, length: 0), "⌘↓ to the message's end")
        print("Composer keys: menu leaves text keys alone, ⌘-arrows move by line and message, empty field switches tabs")
    }
}
