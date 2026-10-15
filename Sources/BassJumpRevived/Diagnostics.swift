import AppKit
import CoreAudio
import OSLog

/// Builds a plain-text report for bug reports: app and system versions, audio devices,
/// BassJump's state and settings, and the last 30 minutes of BassJump's own log.
/// Nothing leaves the Mac unless the user copies or saves it.
enum Diagnostics {
    @MainActor
    static func report(controller: BassJumpController) async -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
        var lines = [
            "BassJump Revived diagnostics — \(Date().formatted(date: .abbreviated, time: .standard))",
            "",
            "## App & system",
            "Version: \(version)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Mac: \(sysctlString("hw.model") ?? "?"), \(architecture())",
            "",
            "## Audio devices",
        ]
        let defaultOut = AudioSystem.defaultOutputDevice()
        for d in AudioSystem.outputDevices() {
            let rate = (try? CA.get(d.id, address(kAudioDevicePropertyNominalSampleRate), Float64(0))) ?? 0
            var flags: [String] = []
            if d.id == defaultOut { flags.append("default output") }
            if d.looksLikeBassJump { flags.append("BassJump") }
            if d.isBuiltIn { flags.append("built-in") }
            lines.append("- \(d.name): \(d.outputChannels) ch, \(Int(rate)) Hz, transport '\(CA.fourCC(d.transport))'\(flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]")")
            lines.append("  \(d.uid)")
        }
        if let v = AudioSystem.volume(defaultOut) {
            lines.append("Output volume: \(Int(v * 100))%\(AudioSystem.isMuted(defaultOut) ? " (muted)" : "")")
        }
        lines += ["", "## BassJump"] + controller.diagnosticState()
        lines += ["", "## Log (last 30 minutes)"]
        lines += await Task.detached(priority: .userInitiated) { recentLog() }.value
        return lines.joined(separator: "\n")
    }

    private static func recentLog() -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(date: Date().addingTimeInterval(-30 * 60))
            let predicate = NSPredicate(format: "subsystem == 'local.bassjump.revived' OR subsystem == 'org.sparkle-project.Sparkle'")
            let entries = try store.getEntries(at: since, matching: predicate)
            let fmt = Date.FormatStyle(date: .omitted, time: .standard)
            let lines = entries.compactMap { $0 as? OSLogEntryLog }.map {
                "\($0.date.formatted(fmt)) [\($0.category)] \($0.composedMessage)"
            }
            return lines.isEmpty ? ["(no entries)"] : Array(lines.suffix(400))
        } catch {
            return ["(log unavailable: \(error.localizedDescription))"]
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func architecture() -> String {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rosetta = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
        #if arch(arm64)
        return "Apple Silicon"
        #else
        return rosetta ? "Intel build under Rosetta" : "Intel"
        #endif
    }

    // MARK: Actions

    @MainActor
    static func copy(controller: BassJumpController) async {
        let text = await report(controller: controller)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor
    static func save(controller: BassJumpController) async {
        let text = await report(controller: controller)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "BassJump Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static let issuesURL = URL(string: "https://github.com/09kleinkd/BassJumpRevived/issues/new")!
}
