import Foundation

/// A crossover/level preset. Built-ins come from BassJump Sound System 3.0.1 (SettingsDB.plist).
struct BassPreset: Identifiable, Hashable, Codable {
    let name: String
    let crossover: Double
    let level: Double
    var isCustom = false
    var id: String { name }

    static let builtIn: [BassPreset] = [
        BassPreset(name: "Default", crossover: 150, level: 0.6),
        BassPreset(name: "Pop", crossover: 200, level: 0.75),
        BassPreset(name: "Rock", crossover: 175, level: 0.8),
        BassPreset(name: "R&B", crossover: 150, level: 1.0),
        BassPreset(name: "Classical", crossover: 175, level: 0.5),
    ]
}

/// Sound settings remembered separately for each output device (MacBook speakers, displays…).
struct OutputProfile: Codable, Equatable {
    var aligned = false
    var crossover = 150.0
    var level = 0.6
    var highPassMain = false
    var alignmentMs = 0.0
}

/// Small JSON-in-UserDefaults helper.
extension UserDefaults {
    func decoded<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func encode<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) { set(data, forKey: key) }
    }
}
