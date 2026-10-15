import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Link between the app and its Control Center control (a sandboxed widget extension).
/// The control reads the app's `enabled` preference (read-only exception) and asks the app to
/// change it with Darwin notifications; the app reloads the control when the state changes.
enum ControlBridge {
    static let controlKind = "local.bassjump.revived.power"
    static let turnOn = "local.bassjump.revived.control.on"
    static let turnOff = "local.bassjump.revived.control.off"

    private static var handler: ((Bool) -> Void)?

    static func listen(_ onRequest: @escaping (Bool) -> Void) {
        handler = onRequest
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in [turnOn, turnOff] {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                let on = (name?.rawValue as String?) == ControlBridge.turnOn
                DispatchQueue.main.async { ControlBridge.handler?(on) }
            }, name as CFString, nil, .deliverImmediately)
        }
    }

    static func stateChanged() {
        #if canImport(WidgetKit)
        if #available(macOS 26.0, *) {
            ControlCenter.shared.reloadControls(ofKind: controlKind)
        }
        #endif
    }
}
