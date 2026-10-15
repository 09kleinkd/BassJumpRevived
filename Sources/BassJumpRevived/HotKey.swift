import Carbon.HIToolbox

/// A system-wide keyboard shortcut via Carbon's RegisterEventHotKey, which (unlike event taps)
/// needs no Accessibility permission.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// ⌃⌥⌘B
    static let defaultKeyCode = UInt32(kVK_ANSI_B)
    static let defaultModifiers = UInt32(controlKey | optionKey | cmdKey)
    static let defaultDisplay = "⌃⌥⌘B"

    init?(keyCode: UInt32 = defaultKeyCode, modifiers: UInt32 = defaultModifiers, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, context, &handlerRef)
        guard status == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x424A_4D50), id: 1)   // 'BJMP'
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
