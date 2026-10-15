import AppKit
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

/// A user-chosen global shortcut: Carbon key code + Carbon modifier mask, plus how to show it.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    static let standard = Shortcut(keyCode: HotKey.defaultKeyCode, modifiers: HotKey.defaultModifiers,
                                   display: HotKey.defaultDisplay)

    /// Builds a shortcut from a key press. Needs ⌘, ⌃ or ⌥ (⇧ alone would hijack typing),
    /// except for function keys, which can stand alone.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        let code = Int(event.keyCode)
        let isFunctionKey = Self.functionKeys[code] != nil
        guard isFunctionKey || flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { return nil }
        guard let name = Self.keyName(code: code, event: event) else { return nil }
        self.init(keyCode: UInt32(code), modifiers: carbon, display: symbols + name)
    }

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.display = display
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19",
    ]
    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    private static func keyName(code: Int, event: NSEvent) -> String? {
        if let f = functionKeys[code] { return f }
        if let s = specialKeys[code] { return s }
        guard code != kVK_Escape,
              let chars = event.charactersIgnoringModifiers?.uppercased(), !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return chars
    }
}
