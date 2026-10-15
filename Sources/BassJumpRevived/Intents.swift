import AppIntents

// Shortcuts actions. They run inside the menu bar app, so they act on the live controller.

enum PresetChoice: String, AppEnum {
    case standard = "Default", pop = "Pop", rock = "Rock", rnb = "R&B", classical = "Classical"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "BassJump Preset"
    static let caseDisplayRepresentations: [PresetChoice: DisplayRepresentation] = [
        .standard: "Default", .pop: "Pop", .rock: "Rock", .rnb: "R&B", .classical: "Classical",
    ]
}

struct SetBassJumpPowerIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn BassJump On or Off"
    static let description = IntentDescription("Turns the BassJump subwoofer on or off.")

    @Parameter(title: "On") var on: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Turn BassJump \(\.$on)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        BassJumpController.shared?.enabled = on
        return .result()
    }
}

struct ToggleBassJumpIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle BassJump"
    static let description = IntentDescription("Turns the BassJump subwoofer on if it's off, and off if it's on.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard let c = BassJumpController.shared else { return .result(value: false) }
        c.enabled.toggle()
        return .result(value: c.enabled)
    }
}

struct SetBassJumpPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Set BassJump Preset"
    static let description = IntentDescription("Applies one of the BassJump presets to the current speakers.")

    @Parameter(title: "Preset") var preset: PresetChoice

    static var parameterSummary: some ParameterSummary {
        Summary("Set BassJump preset to \(\.$preset)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let p = BassPreset.builtIn.first(where: { $0.name == preset.rawValue }) {
            BassJumpController.shared?.apply(p)
        }
        return .result()
    }
}

struct SetBassJumpLevelIntent: AppIntent {
    static let title: LocalizedStringResource = "Set BassJump Level"
    static let description = IntentDescription("Sets the bass level for the current speakers.")

    @Parameter(title: "Level (%)", inclusiveRange: (0, 150)) var percent: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set BassJump level to \(\.$percent)%")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        BassJumpController.shared?.level = Double(percent) / 100
        return .result()
    }
}

struct BassJumpShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleBassJumpIntent(),
                    phrases: ["Toggle \(.applicationName)", "Switch \(.applicationName) on or off"],
                    shortTitle: "Toggle BassJump", systemImageName: "hifispeaker")
        AppShortcut(intent: SetBassJumpPresetIntent(),
                    phrases: ["Set \(.applicationName) preset", "Change \(.applicationName) preset"],
                    shortTitle: "Set Preset", systemImageName: "slider.horizontal.3")
    }
}
