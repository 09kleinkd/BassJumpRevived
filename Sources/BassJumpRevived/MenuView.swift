import SwiftUI

struct MenuView: View {
    @EnvironmentObject var c: BassJumpController
    @ObservedObject var meter: MeterModel
    @State private var savingPreset = false
    @State private var newPresetName = ""

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            LevelMeter(level: meter.level, active: c.status.isPlaying)

            if c.permissionProblem { permissionWarning }

            Divider()
            soundSection
            Divider()
            optionsSection
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { meter.isVisible = true }
        .onDisappear { meter.isVisible = false; savingPreset = false }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("BassJump").font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(c.status.isPlaying ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(c.status.text)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $c.enabled).toggleStyle(.switch).labelsHidden()
        }
    }

    private var permissionWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("BassJump can't hear your Mac's audio", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold()).foregroundStyle(.orange)
            Text("Allow it under Screen & System Audio Recording → System Audio Recording Only, then quit and reopen BassJump.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy Settings") { c.openPrivacySettings() }.controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    // MARK: Sound

    private var soundSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Sound", detail: c.profileOutputName.map { "for \($0)" })

            HStack(spacing: 6) {
                Picker("Preset", selection: Binding(
                    get: { c.presetName },
                    set: { name in if let p = c.allPresets.first(where: { $0.name == name }) { c.apply(p) } }
                )) {
                    ForEach(BassPreset.builtIn) { Label($0.name, systemImage: $0.symbol).tag($0.name) }
                    if !c.customPresets.isEmpty {
                        Divider()
                        ForEach(c.customPresets) { Label($0.name, systemImage: $0.symbol).tag($0.name) }
                    }
                    if c.presetName == "Custom" {
                        Divider()
                        Label("Custom", systemImage: "dial.medium").tag("Custom")
                    }
                }
                .labelsHidden()

                if c.customPresets.contains(where: { $0.name == c.presetName }) {
                    Button { c.deleteCustomPreset(named: c.presetName) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete this preset")
                } else if c.presetName == "Custom" {
                    Button { newPresetName = ""; savingPreset = true } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless).help("Save these settings as a preset")
                }
            }

            if savingPreset {
                HStack(spacing: 6) {
                    TextField("Preset name", text: $newPresetName)
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                        .onSubmit(savePreset)
                    Button("Save", action: savePreset).controlSize(.small)
                        .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { savingPreset = false }.controlSize(.small)
                }
            }

            ValueSlider(icon: "waveform.path", title: "Crossover", value: $c.crossover,
                        range: 60...250, step: 5) { "\(Int($0)) Hz" }
            ValueSlider(icon: "speaker.wave.3", title: "Bass level", value: $c.level,
                        range: 0...1.5, step: 0.05) { "\(Int($0 * 100))%" }

            SwitchRow(icon: "metronome", title: "Time-aligned mode", isOn: $c.alignedMode)
            Text("Plays your speakers through BassJump too, so both stay in sync. Best with MacBook speakers.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if c.alignedMode {
                SwitchRow(icon: "line.3.horizontal.decrease", title: "Send bass only to the sub", isOn: $c.highPassMain)
                ValueSlider(icon: "clock.arrow.2.circlepath", title: "Alignment", value: $c.alignmentMs,
                            range: -30...30, step: 0.5, format: alignmentText)
            }
        }
    }

    // MARK: Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Options", detail: nil)
            SwitchRow(icon: "speaker.wave.2", title: "Follow system volume", isOn: $c.followSystemVolume)
            SwitchRow(icon: "headphones", title: "Pause for headphones", isOn: $c.pauseForHeadphones)
                .help("Pauses the sub when sound goes to headphones, Bluetooth or AirPlay")
            SwitchRow(icon: "keyboard", title: "Shortcut \(c.hotKeyDisplay)", isOn: $c.hotKeyEnabled)
            SwitchRow(icon: "power", title: "Launch at login", isOn: $c.launchAtLogin)
            HStack(spacing: 8) {
                RowIcon(name: "hifispeaker")
                Text("Subwoofer").fixedSize()
                Spacer(minLength: 8)
                Picker("Subwoofer", selection: $c.subwooferUID) {
                    Text("Automatic").tag("")
                    ForEach(c.outputDevices.filter { !$0.isBuiltIn }) { Text($0.name).tag($0.uid) }
                }
                .labelsHidden()
                .frame(maxWidth: 150)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("BassJump Revived \(version)").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless).controlSize(.small)
        }
    }

    // MARK: Helpers

    private func savePreset() {
        c.saveCustomPreset(named: newPresetName)
        savingPreset = false
    }

    private func alignmentText(_ ms: Double) -> String {
        if abs(ms) < 0.25 { return "in sync" }
        return ms > 0 ? String(format: "speakers +%.1f ms", ms) : String(format: "sub +%.1f ms", -ms)
    }
}

// MARK: - Components

private struct RowIcon: View {
    let name: String
    var body: some View {
        Image(systemName: name)
            .foregroundStyle(.secondary)
            .frame(width: 18, alignment: .center)
    }
}

private struct SectionHeader: View {
    let title: String
    let detail: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

private struct SwitchRow: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 8) {
            RowIcon(name: icon)
            Text(title)
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.mini)
        }
    }
}

private struct ValueSlider: View {
    let icon: String
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                RowIcon(name: icon)
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

/// Capsule level meter for the sub output.
struct LevelMeter: View {
    let level: Float
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [.teal, .blue], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, geo.size.width * CGFloat(min(level, 1))))
                    .opacity(active ? 1 : 0)
            }
        }
        .frame(height: 5)
        .animation(.linear(duration: 0.05), value: level)
    }
}
