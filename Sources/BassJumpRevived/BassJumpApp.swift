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

extension BassJumpController.Status {
    var isPlaying: Bool { if case .playing = self { return true } else { return false } }
}

struct MenuView: View {
    @EnvironmentObject var c: BassJumpController
    @ObservedObject var meter: MeterModel

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

            Divider()

            Picker("Preset", selection: Binding(
                get: { c.presetName },
                set: { name in if let p = BassPreset.all.first(where: { $0.name == name }) { c.apply(p) } }
            )) {
                ForEach(BassPreset.all) { Text($0.name).tag($0.name) }
                if c.presetName == "Custom" { Text("Custom").tag("Custom") }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Crossover: \(Int(c.crossover)) Hz").font(.caption)
                Slider(value: $c.crossover, in: 60...250, step: 5)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Bass level: \(Int(c.level * 100))%").font(.caption)
                Slider(value: $c.level, in: 0...1.5, step: 0.05)
            }

            Divider()

            Toggle("Follow system volume", isOn: $c.followSystemVolume)
            Toggle("Pause for headphones & Bluetooth", isOn: $c.pauseForHeadphones)
            Picker("Subwoofer", selection: $c.subwooferUID) {
                Text("Automatic").tag("")
                ForEach(c.outputDevices.filter { !$0.isBuiltIn }) { Text($0.name).tag($0.uid) }
            }
            Toggle("Launch at login", isOn: $c.launchAtLogin)

            Divider()
            Button("Quit BassJump") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 290)
        .onAppear { meter.isVisible = true }
        .onDisappear { meter.isVisible = false }
    }
}
