import AppKit
import Carbon.HIToolbox

/// Registers a global hotkey (default: Option+Space) using Carbon's
/// RegisterEventHotKey — no Accessibility permission required.
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let callback: () -> Void

    private let hotKeyIDValue: UInt32

    init(keyCode: UInt32 = UInt32(kVK_Space),
         modifiers: UInt32 = UInt32(optionKey),
         id: UInt32 = 1,
         callback: @escaping () -> Void) {
        self.callback = callback
        self.hotKeyIDValue = id

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }
            var pressedID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressedID)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            if pressedID.id == manager.hotKeyIDValue {
                DispatchQueue.main.async { manager.callback() }
                return noErr
            }
            // Not ours — let Carbon pass it to the other hotkey's handler.
            return OSStatus(eventNotHandledErr)
        }, 1, &eventType, selfPtr, &eventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x53504354), id: id) // "SPCT"
        RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
