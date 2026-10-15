/// Presets carried over from BassJump Sound System 3.0.1 (SettingsDB.plist).
struct BassPreset: Identifiable, Hashable {
    let name: String
    let crossover: Double
    let level: Double
    var id: String { name }

    static let all: [BassPreset] = [
        BassPreset(name: "Default", crossover: 150, level: 0.6),
        BassPreset(name: "Pop", crossover: 200, level: 0.75),
        BassPreset(name: "Rock", crossover: 175, level: 0.8),
        BassPreset(name: "R&B", crossover: 150, level: 1.0),
        BassPreset(name: "Classical", crossover: 175, level: 0.5),
    ]
}
