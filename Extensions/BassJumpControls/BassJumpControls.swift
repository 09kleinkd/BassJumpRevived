import AppIntents
import SwiftUI
import WidgetKit

/// Control Center / menu bar control that turns BassJump on and off.
@main
struct BassJumpControlsBundle: WidgetBundle {
    var body: some Widget {
        BassJumpPowerControl()
    }
}

struct BassJumpPowerControl: ControlWidget {
    static let kind = "local.bassjump.revived.power"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: PowerProvider()) { isOn in
            ControlWidgetToggle("BassJump", isOn: isOn, action: SetPowerFromControlIntent()) { on in
                Label(on ? "On" : "Off", systemImage: on ? "hifispeaker.fill" : "hifispeaker")
            }
            .tint(.blue)
        }
        .displayName("BassJump")
        .description("Turn the BassJump subwoofer on or off.")
    }
}

struct PowerProvider: ControlValueProvider {
    var previewValue: Bool { true }

    func currentValue() async throws -> Bool {
        // Read-only access to the app's preferences (see entitlements).
        UserDefaults(suiteName: "local.bassjump.revived")?.object(forKey: "enabled") as? Bool ?? true
    }
}

struct SetPowerFromControlIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set BassJump"

    @Parameter(title: "On") var value: Bool

    func perform() async throws -> some IntentResult {
        let name = value ? "local.bassjump.revived.control.on" : "local.bassjump.revived.control.off"
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
        return .result()
    }
}
