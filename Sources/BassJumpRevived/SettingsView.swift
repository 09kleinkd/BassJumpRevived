import SwiftUI

/// The Settings window: everything you set once and forget. Everyday sound controls stay in
/// the menu bar popover.
struct SettingsView: View {
    enum Tab: String { case general, sound, apps, help }

    @EnvironmentObject var c: BassJumpController
    @EnvironmentObject var updater: Updater
    @AppStorage("settingsTab") private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            SoundSettings().tabItem { Label("Speakers", systemImage: "hifispeaker.2") }.tag(Tab.sound)
            AppsSettings().tabItem { Label("Apps", systemImage: "app.badge") }.tag(Tab.apps)
            HelpSettings().tabItem { Label("Help", systemImage: "questionmark.circle") }.tag(Tab.help)
        }
        .frame(width: 500, height: 470)
    }
}

// MARK: General

private struct GeneralSettings: View {
    @EnvironmentObject var c: BassJumpController
    @EnvironmentObject var updater: Updater

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $c.launchAtLogin)
                Toggle("Notify when a BassJump connects or disconnects", isOn: $c.notifyOnConnect)
                Toggle("Animate the menu bar icon with the bass", isOn: $c.liveIcon)
            }
            Section {
                Toggle("Turn BassJump on and off with a keyboard shortcut", isOn: $c.hotKeyEnabled)
                LabeledContent("Shortcut") {
                    ShortcutRecorder()
                }
                .disabled(!c.hotKeyEnabled)
                if c.hotKeyConflict && c.hotKeyEnabled {
                    Label("Another app is using \(c.shortcut.display). Pick a different shortcut.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
            } header: { Text("Keyboard") }
            Section {
                Toggle("Check for updates automatically", isOn: $updater.automaticChecks)
                LabeledContent("Version \(Bundle.main.shortVersion)") {
                    Button("Check Now") { updater.checkForUpdates() }.disabled(!updater.canCheck)
                }
            } header: { Text("Updates") }
            Section {
                LabeledContent("Walk through the setup steps again") {
                    Button("Run Setup…") { AppDelegate.shared?.showOnboarding() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, then press the new key combination. Esc cancels.
private struct ShortcutRecorder: View {
    @EnvironmentObject var c: BassJumpController
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Type a shortcut…" : c.shortcut.display)
                    .monospaced(!recording)
                    .frame(minWidth: 110)
            }
            .help(recording ? "Press the keys, or Esc to cancel" : "Click to record a new shortcut")
            if c.shortcut != .standard && !recording {
                Button("Reset") { c.shortcut = .standard }
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        c.hotKeySuspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }          // Esc
            if let s = Shortcut(event: event) { c.shortcut = s; stop() }
            else { NSSound.beep() }                                 // needs ⌘, ⌃ or ⌥
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { recording = false; c.hotKeySuspended = false }
    }
}

// MARK: Speakers

private struct SoundSettings: View {
    @EnvironmentObject var c: BassJumpController

    var body: some View {
        Form {
            Section {
                Picker("Subwoofer", selection: $c.subwooferUID) {
                    Text("Automatic (first BassJump)").tag("")
                    ForEach(c.outputDevices.filter { !$0.isBuiltIn }) { Text($0.name).tag($0.uid) }
                }
                Toggle(isOn: $c.stereoSubs) {
                    Text("Stereo with two BassJumps")
                    Text(c.stereoActive ? "Active — left bass to one, right bass to the other"
                                        : "With two BassJumps plugged in, left bass goes to one and right to the other")
                }
            } header: { Text("Subwoofer") }
            Section {
                Toggle(isOn: $c.followSystemVolume) {
                    Text("Follow the system volume")
                    Text("The bass rises and falls with your Mac's volume and mute")
                }
                Toggle(isOn: $c.pauseForHeadphones) {
                    Text("Pause for headphones and wireless speakers")
                    Text("Stops the sub when sound goes to headphones, Bluetooth or AirPlay")
                }
            } header: { Text("Playback") }
        }
        .formStyle(.grouped)
    }
}

// MARK: Apps

private struct AppsSettings: View {
    @EnvironmentObject var c: BassJumpController

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $c.skipCalls) {
                    Text("Skip calls")
                    Text("No bass for Zoom, Teams, FaceTime, Webex, Slack, Discord and other call apps")
                }
            }
            Section {
                if c.ignoredApps.isEmpty {
                    Text("Every app gets bass.").foregroundStyle(.secondary)
                }
                ForEach(c.ignoredApps, id: \.self) { bundle in
                    HStack {
                        Label(c.appName(for: bundle), systemImage: "speaker.slash")
                        Spacer()
                        Button("Give Bass Back") { c.toggleIgnored(bundle) }
                    }
                }
                Menu("No Bass for an App…") {
                    let candidates = c.audioApps.filter { !c.ignoredApps.contains($0.bundleID) && !$0.isCallApp }
                    if candidates.isEmpty { Text("Play something in the app first") }
                    ForEach(candidates) { app in
                        Button { c.toggleIgnored(app.bundleID) } label: {
                            Label(app.name, systemImage: app.isPlaying ? "speaker.wave.2.fill" : "app")
                        }
                    }
                }
                .fixedSize()
            } header: { Text("Apps without bass") }
        }
        .formStyle(.grouped)
    }
}

// MARK: Help

private struct HelpSettings: View {
    @EnvironmentObject var c: BassJumpController
    @State private var copied = false
    @State private var working = false

    var body: some View {
        Form {
            Section {
                Text("If something isn't working, copy the diagnostic report and paste it into a GitHub issue. It lists your Mac's audio devices, BassJump's settings and its recent log — no audio and no personal files.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(copied ? "Copied" : "Copy Diagnostic Info") {
                        working = true
                        Task { await Diagnostics.copy(controller: c); working = false; copied = true
                               try? await Task.sleep(for: .seconds(2)); copied = false }
                    }
                    Button("Save as File…") { Task { await Diagnostics.save(controller: c) } }
                    if working { ProgressView().controlSize(.small) }
                }
                Link("Report a problem on GitHub…", destination: Diagnostics.issuesURL)
            } header: { Text("Troubleshooting") }
            Section {
                LabeledContent("BassJump Revived", value: Bundle.main.shortVersion)
                Link("Project page and documentation", destination: URL(string: "https://github.com/09kleinkd/BassJumpRevived")!)
                Text("Not affiliated with Twelve South. “BassJump” is a trademark of Twelve South LLC.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("About") }
        }
        .formStyle(.grouped)
    }
}

extension Bundle {
    var shortVersion: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
}
