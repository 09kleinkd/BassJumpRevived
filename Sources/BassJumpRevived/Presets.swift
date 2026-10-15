import Foundation

/// A crossover/level preset. Built-ins come from BassJump Sound System 3.0.1 (SettingsDB.plist).
struct BassPreset: Identifiable, Hashable, Codable {
    let name: String
    let crossover: Double
    let level: Double
    var isCustom = false
    var id: String { name }

    /// SF Symbol shown next to the preset in menus.
    var symbol: String {
        if isCustom { return "star" }
        switch name {
        case "Default": return "slider.horizontal.3"
        case "Pop": return "music.mic"
        case "Rock": return "guitars"
        case "R&B": return "music.note"
        case "Classical": return "pianokeys"
        default: return "dial.medium"
        }
    }

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
    var invertSub = false
    /// Sub EQ: two peaking bands; gain 0 dB = band off. Room-specific, so new outputs start flat.
    var eqEnabled = true
    var eq1Hz = 60.0, eq1DB = 0.0
    var eq2Hz = 100.0, eq2DB = 0.0

    init(aligned: Bool = false, crossover: Double = 150, level: Double = 0.6,
         highPassMain: Bool = false, alignmentMs: Double = 0, invertSub: Bool = false,
         eqEnabled: Bool = true, eq1Hz: Double = 60, eq1DB: Double = 0, eq2Hz: Double = 100, eq2DB: Double = 0) {
        self.aligned = aligned; self.crossover = crossover; self.level = level
        self.highPassMain = highPassMain; self.alignmentMs = alignmentMs; self.invertSub = invertSub
        self.eqEnabled = eqEnabled; self.eq1Hz = eq1Hz; self.eq1DB = eq1DB; self.eq2Hz = eq2Hz; self.eq2DB = eq2DB
    }

    /// Mode for an output BassJump hasn't seen before: time-aligned for a Mac's own stereo
    /// speakers (keeps the sub in sync), sub-only for everything else — multichannel displays
    /// like the Studio Display play ~10 dB quieter when driven directly.
    static func suggestsAlignedMode(for output: AudioDeviceInfo) -> Bool {
        output.isBuiltIn && output.outputChannels <= 2
    }

    /// Tolerates profiles saved by older versions (missing keys fall back to defaults).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aligned = try c.decodeIfPresent(Bool.self, forKey: .aligned) ?? false
        crossover = try c.decodeIfPresent(Double.self, forKey: .crossover) ?? 150
        level = try c.decodeIfPresent(Double.self, forKey: .level) ?? 0.6
        highPassMain = try c.decodeIfPresent(Bool.self, forKey: .highPassMain) ?? false
        alignmentMs = try c.decodeIfPresent(Double.self, forKey: .alignmentMs) ?? 0
        invertSub = try c.decodeIfPresent(Bool.self, forKey: .invertSub) ?? false
        eqEnabled = try c.decodeIfPresent(Bool.self, forKey: .eqEnabled) ?? true
        eq1Hz = try c.decodeIfPresent(Double.self, forKey: .eq1Hz) ?? 60
        eq1DB = try c.decodeIfPresent(Double.self, forKey: .eq1DB) ?? 0
        eq2Hz = try c.decodeIfPresent(Double.self, forKey: .eq2Hz) ?? 100
        eq2DB = try c.decodeIfPresent(Double.self, forKey: .eq2DB) ?? 0
    }
}

/// Apps whose audio is usually a call — skipped by default so voices don't rumble the sub.
/// Matched as bundle-ID prefixes (helpers like `com.microsoft.teams2.helper` match too).
enum CallApps {
    static let bundlePrefixes = [
        "us.zoom.", "com.microsoft.teams", "com.apple.FaceTime", "com.apple.avconferenced",
        "com.apple.TelephonyUtilities", "com.apple.mobilephone", "com.cisco.webexmeetings",
        "Cisco-Systems.Spark", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.skype.",
        "com.webex.", "com.ringcentral.",
    ]
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
