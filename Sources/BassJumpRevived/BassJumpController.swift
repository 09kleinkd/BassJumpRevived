import AppKit
import CoreAudio
import Foundation
import ServiceManagement
import SwiftUI
import os

private let log = Logger(subsystem: "local.bassjump.revived", category: "controller")

@MainActor
final class BassJumpController: ObservableObject {
    enum Status: Equatable {
        case off, playing(sub: String, main: String?), noDevice, notSpeakers, error(String)

        var text: String {
            switch self {
            case .off: return "Off"
            case .playing(let sub, nil): return "Playing through \(sub)"
            case .playing(let sub, let main?): return "Time-aligned: \(main) + \(sub)"
            case .noDevice: return "BassJump not connected"
            case .notSpeakers: return "Paused — sound is going to headphones or a wireless device"
            case .error(let msg): return msg
            }
        }
        var isPlaying: Bool { if case .playing = self { return true } else { return false } }
    }

    // MARK: Global settings (persisted)
    @Published var enabled: Bool { didSet { saveGlobal(); reconcile() } }
    @Published var followSystemVolume: Bool { didSet { saveGlobal(); applyParameters() } }
    @Published var pauseForHeadphones: Bool { didSet { saveGlobal(); reconcile() } }
    @Published var subwooferUID: String { didSet { saveGlobal(); reconcile() } }   // "" = automatic
    @Published var hotKeyEnabled: Bool { didSet { saveGlobal(); updateHotKey() } }

    // MARK: Per-output settings (remembered for each speaker/output device)
    @Published var crossover: Double { didSet { profileChanged(applyOnly: true); updatePresetName() } }
    @Published var level: Double { didSet { profileChanged(applyOnly: true); updatePresetName() } }
    @Published var alignedMode: Bool { didSet { profileChanged(applyOnly: false) } }
    @Published var highPassMain: Bool { didSet { profileChanged(applyOnly: true) } }
    @Published var alignmentMs: Double { didSet { profileChanged(applyOnly: true) } }

    // MARK: State
    @Published private(set) var status: Status = .off
    @Published private(set) var presetName = "Custom"
    @Published private(set) var customPresets: [BassPreset] = []
    @Published private(set) var outputDevices: [AudioDeviceInfo] = []
    @Published private(set) var profileOutputName: String?
    @Published private(set) var permissionProblem = false
    /// Separate model so 20 Hz meter updates don't redraw the menu bar icon.
    let meterModel = MeterModel()
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { log.error("Launch at login: \(String(describing: error), privacy: .public)") }
        }
    }

    var allPresets: [BassPreset] { BassPreset.builtIn + customPresets }
    var hotKeyDisplay: String { HotKey.defaultDisplay }

    private let engine = BassEngine()
    private let defaults = UserDefaults.standard
    private var debugLogging: Bool { defaults.bool(forKey: "debugLogging") }
    private var profiles: [String: OutputProfile] = [:]
    private var profileUID: String?
    private var loadingProfile = false
    private var systemListeners: [PropertyListener] = []
    private var outputListeners: [PropertyListener] = []
    private var deviceHealthListeners: [PropertyListener] = []
    private var listenedOutput = AudioObjectID(kAudioObjectUnknown)
    private var meterTimer: Timer?
    private var reconcilePending = false
    private var isAsleep = false
    private var restartAttempts = 0
    private var workspaceObservers: [NSObjectProtocol] = []
    private var hotKey: HotKey?

    init() {
        defaults.register(defaults: [
            "enabled": true, "followSystemVolume": true, "pauseForHeadphones": true,
            "subwooferUID": "", "hotKeyEnabled": true,
            "crossover": 150.0, "level": 0.6, "alignedMode": false, "highPassMain": false, "alignmentMs": 0.0,
        ])
        enabled = defaults.bool(forKey: "enabled")
        followSystemVolume = defaults.bool(forKey: "followSystemVolume")
        pauseForHeadphones = defaults.bool(forKey: "pauseForHeadphones")
        subwooferUID = defaults.string(forKey: "subwooferUID") ?? ""
        hotKeyEnabled = defaults.bool(forKey: "hotKeyEnabled")
        // Last-used sound settings seed any output that has no profile yet.
        crossover = defaults.double(forKey: "crossover")
        level = defaults.double(forKey: "level")
        alignedMode = defaults.bool(forKey: "alignedMode")
        highPassMain = defaults.bool(forKey: "highPassMain")
        alignmentMs = defaults.double(forKey: "alignmentMs")
        profiles = defaults.decoded([String: OutputProfile].self, forKey: "profiles") ?? [:]
        customPresets = defaults.decoded([BassPreset].self, forKey: "customPresets") ?? []
        updatePresetName()

        let system = AudioObjectID(kAudioObjectSystemObject)
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            if let l = PropertyListener(system, address(sel), { [weak self] in self?.scheduleReconcile() }) {
                systemListeners.append(l)
            }
        }

        // Sleep/wake: tear down before sleep, rebuild a moment after wake.
        let ws = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAsleep = true
                self?.engine.stop()
                log.info("Sleeping — engine stopped")
            }
        })
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAsleep = false
                log.info("Woke — restarting")
                self?.scheduleReconcile(after: 2)
            }
        })

        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        updateHotKey()
        reconcile()
    }

    // MARK: Keyboard shortcut

    private func updateHotKey() {
        hotKey = nil
        guard hotKeyEnabled else { return }
        hotKey = HotKey { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.enabled.toggle()
                log.info("Shortcut: BassJump \(self.enabled ? "on" : "off", privacy: .public)")
            }
        }
        if hotKey == nil { log.error("Couldn't register \(HotKey.defaultDisplay, privacy: .public) — another app may be using it") }
    }

    // MARK: Meter, watchdog, permission check, diagnostics

    private var ticks = 0
    private var lastRenderCount: UInt64 = 0
    private var maxPeak: Float = 0, maxInput: Float = 0
    private var silentWhileOthersPlay = 0

    private func tick() {
        let running = engine.isRunning
        let value = running ? engine.dsp.peak : 0
        if meterModel.isVisible || meterModel.level != 0 { meterModel.level = meterModel.isVisible ? value : 0 }
        if running { maxPeak = max(maxPeak, value); maxInput = max(maxInput, engine.dsp.inputPeak) }
        ticks += 1

        if ticks % 40 == 0 {   // every 2 s
            // Watchdog: if the audio callback stopped running, rebuild the engine.
            let count = engine.dsp.renderCount
            if running && !isAsleep && count == lastRenderCount {
                log.error("Watchdog: audio callback stalled — restarting")
                restart()
            } else if running {
                restartAttempts = 0
            }
            lastRenderCount = count

            // Permission check: another app is playing, yet the tap delivers digital silence.
            if running && engine.dsp.inputPeak == 0 && AudioSystem.otherProcessIsPlaying() {
                silentWhileOthersPlay += 1
            } else if engine.dsp.inputPeak > 0 {
                silentWhileOthersPlay = 0
            }
            let problem = silentWhileOthersPlay >= 5   // ~10 s
            if problem != permissionProblem {
                permissionProblem = problem
                if problem { log.error("Tap is silent while other apps play — system audio permission is probably off") }
            }
        }
        if ticks % 100 == 0 {
            if running && debugLogging {
                log.notice("Last 5 s — tap in: \(self.maxInput, privacy: .public), sub out: \(self.maxPeak, privacy: .public), gain \(self.engine.dsp.subGain, privacy: .public)")
            }
            maxPeak = 0; maxInput = 0
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Tear down and rebuild, backing off if it keeps failing.
    private func restart() {
        engine.stop()
        restartAttempts += 1
        let delay = min(Double(restartAttempts) * 1.5, 15)
        scheduleReconcile(after: delay)
    }

    // MARK: Presets

    func apply(_ preset: BassPreset) {
        crossover = preset.crossover
        level = preset.level
    }

    func saveCustomPreset(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !BassPreset.builtIn.contains(where: { $0.name == name }) else { return }
        customPresets.removeAll { $0.name == name }
        customPresets.append(BassPreset(name: name, crossover: crossover, level: level, isCustom: true))
        defaults.encode(customPresets, forKey: "customPresets")
        updatePresetName()
    }

    func deleteCustomPreset(named name: String) {
        customPresets.removeAll { $0.name == name }
        defaults.encode(customPresets, forKey: "customPresets")
        updatePresetName()
    }

    private func updatePresetName() {
        presetName = allPresets.first { abs($0.crossover - crossover) < 0.5 && abs($0.level - level) < 0.005 }?.name ?? "Custom"
    }

    // MARK: Per-output profiles

    private var currentProfile: OutputProfile {
        OutputProfile(aligned: alignedMode, crossover: crossover, level: level,
                      highPassMain: highPassMain, alignmentMs: alignmentMs)
    }

    private func profileChanged(applyOnly: Bool) {
        guard !loadingProfile else { return }
        let p = currentProfile
        if let uid = profileUID { profiles[uid] = p; defaults.encode(profiles, forKey: "profiles") }
        // Also remember as "last used", which seeds new outputs.
        defaults.set(p.crossover, forKey: "crossover")
        defaults.set(p.level, forKey: "level")
        defaults.set(p.aligned, forKey: "alignedMode")
        defaults.set(p.highPassMain, forKey: "highPassMain")
        defaults.set(p.alignmentMs, forKey: "alignmentMs")
        if applyOnly { applyParameters() } else { reconcile() }
    }

    /// Switch to the profile for the current output, creating it from the last-used settings.
    private func selectProfile(for output: AudioDeviceInfo?) {
        guard let output, output.uid != profileUID else { return }
        profileUID = output.uid
        profileOutputName = output.name
        let p = profiles[output.uid] ?? currentProfile
        profiles[output.uid] = p
        defaults.encode(profiles, forKey: "profiles")
        loadingProfile = true
        crossover = p.crossover; level = p.level; alignedMode = p.aligned
        highPassMain = p.highPassMain; alignmentMs = p.alignmentMs
        loadingProfile = false
        updatePresetName()
        log.info("Using settings for \(output.name, privacy: .public)")
    }

    // MARK: Core logic

    /// Device-change notifications arrive in bursts; coalesce them.
    private func scheduleReconcile(after delay: Double = 0.3) {
        guard !reconcilePending else { return }
        reconcilePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.reconcilePending = false
            self?.reconcile()
        }
    }

    func reconcile() {
        guard !isAsleep else { return }
        outputDevices = AudioSystem.outputDevices()
        watchDefaultOutput()

        let sub: AudioDeviceInfo? = subwooferUID.isEmpty
            ? outputDevices.first(where: \.looksLikeBassJump)
            : outputDevices.first(where: { $0.uid == subwooferUID })
        let defaultOut = AudioSystem.defaultOutputDevice()
        let main = AudioSystem.info(for: defaultOut)
        if let main, main.id != sub?.id { selectProfile(for: main) }

        let desired: Status
        if !enabled { desired = .off }
        else if sub == nil { desired = .noDevice }
        else if defaultOut == sub!.id { desired = .notSpeakers }   // the BassJump itself is the output
        else if pauseForHeadphones && !AudioSystem.isSpeakers(defaultOut) { desired = .notSpeakers }
        else { desired = .playing(sub: sub!.name, main: alignedMode ? main?.name : nil) }

        if case .playing = desired, let sub {
            let config = EngineConfig(aligned: alignedMode && main != nil, subUID: sub.uid,
                                      mainUID: alignedMode ? main?.uid : nil,
                                      fillAllChannels: defaults.bool(forKey: "fillAllChannels"),
                                      fillCenter: defaults.bool(forKey: "fillCenter"))
            if engine.config != config {
                do {
                    try engine.start(config)
                } catch {
                    status = .error("Couldn't start: \(error)")
                    watchDeviceHealth(sub: nil, main: nil)
                    return
                }
            }
            watchDeviceHealth(sub: sub.id, main: config.aligned ? main?.id : nil)
            applyParameters()
        } else {
            engine.stop()
            watchDeviceHealth(sub: nil, main: nil)
            silentWhileOthersPlay = 0
            permissionProblem = false
        }
        status = desired
    }

    /// Restart if a device in use dies (unplugged) or changes sample rate.
    private var watchedHealth: [AudioObjectID] = []
    private func watchDeviceHealth(sub: AudioObjectID?, main: AudioObjectID?) {
        let ids = [sub, main].compactMap { $0 }
        guard ids != watchedHealth else { return }
        watchedHealth = ids
        deviceHealthListeners.removeAll()
        for id in ids {
            for sel in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate] {
                if let l = PropertyListener(id, address(sel), { [weak self] in
                    log.info("Device \(id) changed ('\(CA.fourCC(sel), privacy: .public)') — restarting")
                    self?.restart()
                }) { deviceHealthListeners.append(l) }
            }
        }
    }

    private func watchDefaultOutput() {
        let out = AudioSystem.defaultOutputDevice()
        guard out != listenedOutput else { return }
        listenedOutput = out
        outputListeners.removeAll()
        guard out != kAudioObjectUnknown else { return }
        let volumeAddresses = [
            address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain),
            address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, 1),
            address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, 2),
            address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain),
        ].filter { CA.has(out, $0) }
        for a in volumeAddresses {
            if let l = PropertyListener(out, a, { [weak self] in self?.applyParameters() }) { outputListeners.append(l) }
        }
        let ds = address(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput)
        if CA.has(out, ds), let l = PropertyListener(out, ds, { [weak self] in self?.scheduleReconcile() }) {
            outputListeners.append(l)
        }
    }

    private func applyParameters() {
        var gain = Float(level) * 2.0          // level 1.0 = +6 dB into the limiter
        if followSystemVolume {
            let out = AudioSystem.defaultOutputDevice()
            if AudioSystem.isMuted(out) { gain = 0 }
            else if let v = AudioSystem.volume(out) { gain *= v }
        }
        let dsp = engine.dsp
        dsp.crossoverHz = crossover
        dsp.subGain = gain
        dsp.highPassMain = highPassMain
        dsp.alignmentMs = alignmentMs
    }

    private func saveGlobal() {
        defaults.set(enabled, forKey: "enabled")
        defaults.set(followSystemVolume, forKey: "followSystemVolume")
        defaults.set(pauseForHeadphones, forKey: "pauseForHeadphones")
        defaults.set(subwooferUID, forKey: "subwooferUID")
        defaults.set(hotKeyEnabled, forKey: "hotKeyEnabled")
    }
}

@MainActor
final class MeterModel: ObservableObject {
    @Published var level: Float = 0
    var isVisible = false
}
