import SwiftUI

/// The popover. On macOS 26+ it's built from Liquid Glass cards and glass buttons, like
/// Control Center; earlier systems fall back to material cards.
struct MenuView: View {
    @EnvironmentObject var c: BassJumpController
    @ObservedObject var meter: MeterModel
    @State private var savingPreset = false
    @State private var newPresetName = ""

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        GlassGroup {
            VStack(spacing: 10) {
                statusCard
                if c.permissionProblem { permissionCard }
                soundCard
                optionsCard
                footer
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { meter.isVisible = true }
        .onDisappear { meter.isVisible = false; savingPreset = false }
    }

    // MARK: Status

    private var statusCard: some View {
        GlassCard {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("BassJump").font(.headline)
                        Text(c.status.text)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button { c.enabled.toggle() } label: {
                        Image(systemName: "power")
                            .font(.system(size: 16, weight: .semibold))
                            .glassCircle(selected: c.enabled)
                    }
                    .buttonStyle(.plain)
                    .help(c.enabled ? "Turn BassJump off" : "Turn BassJump on")
                }
                LevelMeter(level: meter.level, active: c.status.isPlaying)
            }
        }
    }

    private var permissionCard: some View {
        GlassCard(tint: .orange) {
            VStack(alignment: .leading, spacing: 6) {
                Label("BassJump can't hear your Mac's audio", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold()).foregroundStyle(.orange)
                Text("Allow it under Screen & System Audio Recording → System Audio Recording Only, then quit and reopen BassJump.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings") { c.openPrivacySettings() }
                    .glassCapsuleButton().controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Sound

    private var soundCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Sound", detail: c.profileOutputName.map { "for \($0)" })

                HStack(alignment: .top, spacing: 0) {
                    ForEach(BassPreset.builtIn) { preset in
                        PresetButton(symbol: preset.symbol, title: preset.name,
                                     selected: c.presetName == preset.name) { c.apply(preset) }
                    }
                    moreButton
                }

                if savingPreset {
                    HStack(spacing: 6) {
                        TextField("Preset name", text: $newPresetName)
                            .textFieldStyle(.roundedBorder).controlSize(.small)
                            .onSubmit(savePreset)
                        Button("Save", action: savePreset).glassCapsuleButton(prominent: true).controlSize(.small)
                            .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { savingPreset = false }.glassCapsuleButton().controlSize(.small)
                    }
                }

                ValueSlider(icon: "waveform.path", title: "Crossover", value: $c.crossover,
                            range: 60...250, step: 5) { "\(Int($0)) Hz" }
                ValueSlider(icon: "speaker.wave.3", title: "Bass level", value: $c.level,
                            range: 0...1.5, step: 0.05) { "\(Int($0 * 100))%" }

                VStack(alignment: .leading, spacing: 4) {
                    SwitchRow(icon: "metronome", title: "Time-aligned mode", isOn: $c.alignedMode)
                    Text("Plays your speakers through BassJump too, so both stay in sync. Best with MacBook speakers.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 26)
                }
                if c.alignedMode {
                    SwitchRow(icon: "line.3.horizontal.decrease", title: "Send bass only to the sub", isOn: $c.highPassMain)
                    ValueSlider(icon: "clock.arrow.2.circlepath", title: "Alignment", value: $c.alignmentMs,
                                range: -30...30, step: 0.5, format: alignmentText)
                }
            }
        }
    }

    /// Custom presets live behind a "More" button: choose, save current, delete.
    private var moreButton: some View {
        let customSelected = c.customPresets.contains { $0.name == c.presetName }
        let unsaved = c.presetName == "Custom"
        return VStack(spacing: 5) {
            Menu {
                ForEach(c.customPresets) { p in
                    Button { c.apply(p) } label: { Label(p.name, systemImage: c.presetName == p.name ? "checkmark" : "star") }
                }
                if !c.customPresets.isEmpty { Divider() }
                Button { newPresetName = ""; savingPreset = true } label: {
                    Label("Save Current Settings…", systemImage: "plus")
                }
                .disabled(!unsaved)
                if customSelected {
                    Button(role: .destructive) { c.deleteCustomPreset(named: c.presetName) } label: {
                        Label("Delete “\(c.presetName)”", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: customSelected ? "star.fill" : (unsaved ? "slider.horizontal.3" : "ellipsis"))
                    .font(.system(size: 15, weight: .medium))
                    .glassCircle(selected: customSelected || unsaved)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            Text(customSelected ? c.presetName : (unsaved ? "Custom" : "More"))
                .font(.caption2)
                .foregroundStyle(customSelected || unsaved ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Options

    private var optionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 11) {
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
    }

    private var footer: some View {
        HStack {
            Text("BassJump Revived \(version)").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .glassCapsuleButton().controlSize(.small)
        }
        .padding(.horizontal, 6)
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

// MARK: - Glass building blocks

/// Groups glass shapes so they blend and share sampling (GlassEffectContainer on macOS 26+).
private struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 10) { content }
        } else {
            content
        }
    }
}

/// A rounded Liquid Glass card.
private struct GlassCard<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(tint.map { Glass.regular.tint($0.opacity(0.25)) } ?? .regular, in: shape)
        } else {
            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.15)))
        }
    }
}

private extension View {
    /// A 38 pt glass circle; selected circles are tinted blue with a white glyph.
    @ViewBuilder
    func glassCircle(selected: Bool) -> some View {
        let base = self
            .frame(width: 38, height: 38)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .contentShape(Circle())
        if #available(macOS 26.0, *) {
            base.glassEffect(selected ? Glass.regular.tint(.blue).interactive() : Glass.regular.interactive(), in: Circle())
        } else {
            base.background(Circle().fill(selected ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.quaternary)))
        }
    }

    /// Capsule glass button for text actions.
    @ViewBuilder
    func glassCapsuleButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

// MARK: - Components

private struct PresetButton: View {
    let symbol: String
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .glassCircle(selected: selected)
            }
            .buttonStyle(.plain)
            .help(title)
            Text(title)
                .font(.caption2)
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

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
