import Carbon.HIToolbox  // RegisterEventHotKey, InstallEventHandler, kVK_ANSI_L, controlKey...
import AppKit

/// System-wide hot key (⌃⌥⌘L) via Carbon. No Accessibility/TCC permission
/// required (registers with the WindowServer rather than tapping events).
final class GlobalHotKey: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPressed: @Sendable () -> Void

    init(onPressed: @escaping @Sendable () -> Void) {
        self.onPressed = onPressed

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C4D4D41) /* 'LMMA' */, id: 1)

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var firedID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &firedID)
                guard status == noErr else { return status }

                let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                if firedID.id == 1 {
                    let cb = me.onPressed
                    DispatchQueue.main.async { cb() }
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &handlerRef)

        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let err = RegisterEventHotKey(
            UInt32(kVK_ANSI_L), // 0x25
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0, // kEventHotKeyNoOptions
            &hotKeyRef)
        if err != noErr {
            NSLog("GlobalHotKey: RegisterEventHotKey failed: \(err)")
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
