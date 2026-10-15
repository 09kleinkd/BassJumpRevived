import SwiftUI

@main
struct BassJumpApp: App {
    @StateObject private var controller = BassJumpController()

    var body: some Scene {
        MenuBarExtra {
            MenuView(meter: controller.meterModel).environmentObject(controller)
        } label: {
            Image(systemName: controller.status.isPlaying ? "hifispeaker.fill" : "hifispeaker")
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuView: View {
    @EnvironmentObject var c: BassJumpController
    @ObservedObject var meter: MeterModel
    @State private var savingPreset = false
    @State private var newPresetName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("BassJump").font(.headline)
                Spacer()
                Toggle("", isOn: $c.enabled).toggleStyle(.switch).labelsHidden()
            }
            HStack(spacing: 6) {
                Circle().fill(c.status.isPlaying ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                Text(c.status.text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ProgressView(value: Double(min(meter.level, 1))).progressViewStyle(.linear).opacity(c.status.isPlaying ? 1 : 0.3)

            if c.permissionProblem {
                VStack(alignment: .leading, spacing: 6) {
                    Label("BassJump can't hear your Mac's audio", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.bold()).foregroundStyle(.orange)
                    Text("Allow it under Screen & System Audio Recording → System Audio Recording Only, then quit and reopen BassJump.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open Privacy Settings") { c.openPrivacySettings() }.controlSize(.small)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
            }

            Divider()

            if let name = c.profileOutputName {
                Text("Settings for \(name)").font(.caption2).foregroundStyle(.secondary)
            }

            HStack {
                Picker("Preset", selection: Binding(
                    get: { c.presetName },
                    set: { name in if let p = c.allPresets.first(where: { $0.name == name }) { c.apply(p) } }
                )) {
                    ForEach(BassPreset.builtIn) { Text($0.name).tag($0.name) }
                    if !c.customPresets.isEmpty {
                        Divider()
                        ForEach(c.customPresets) { Text($0.name).tag($0.name) }
                    }
                    if c.presetName == "Custom" { Text("Custom").tag("Custom") }
                }
                if c.customPresets.contains(where: { $0.name == c.presetName }) {
                    Button { c.deleteCustomPreset(named: c.presetName) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete this preset")
                } else if c.presetName == "Custom" {
                    Button { newPresetName = ""; savingPreset = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("Save these settings as a preset")
                }
            }
            if savingPreset {
                HStack {
                    TextField("Preset name", text: $newPresetName)
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                        .onSubmit(save)
                    Button("Save", action: save).controlSize(.small)
                        .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { savingPreset = false }.controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Crossover: \(Int(c.crossover)) Hz").font(.caption)
                Slider(value: $c.crossover, in: 60...250, step: 5)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Bass level: \(Int(c.level * 100))%").font(.caption)
                Slider(value: $c.level, in: 0...1.5, step: 0.05)
            }

            Toggle("Time-aligned mode", isOn: $c.alignedMode)
            Text("Plays your speakers through BassJump too, so both stay in sync. Best with MacBook speakers.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if c.alignedMode {
                Toggle("Send bass only to the sub", isOn: $c.highPassMain)
                VStack(alignment: .leading, spacing: 2) {
                    Text(alignmentLabel).font(.caption)
                    Slider(value: $c.alignmentMs, in: -30...30, step: 0.5)
                }
            }

            Divider()

            Toggle("Follow system volume", isOn: $c.followSystemVolume)
            Toggle("Pause for headphones & Bluetooth", isOn: $c.pauseForHeadphones)
            Toggle("Shortcut \(c.hotKeyDisplay) turns BassJump on/off", isOn: $c.hotKeyEnabled)
            Picker("Subwoofer", selection: $c.subwooferUID) {
                Text("Automatic").tag("")
                ForEach(c.outputDevices.filter { !$0.isBuiltIn }) { Text($0.name).tag($0.uid) }
            }
            Toggle("Launch at login", isOn: $c.launchAtLogin)

            Divider()
            Button("Quit BassJump") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 310)
        .onAppear { meter.isVisible = true }
        .onDisappear { meter.isVisible = false }
    }

    private func save() {
        c.saveCustomPreset(named: newPresetName)
        savingPreset = false
    }

    private var alignmentLabel: String {
        let ms = c.alignmentMs
        if abs(ms) < 0.25 { return "Alignment: in sync" }
        return ms > 0 ? String(format: "Alignment: speakers delayed %.1f ms", ms)
                      : String(format: "Alignment: sub delayed %.1f ms", -ms)
    }
}
