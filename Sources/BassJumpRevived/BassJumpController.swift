import AppKit
import CoreAudio
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications
import os

private let log = Logger(subsystem: "local.bassjump.revived", category: "controller")

@MainActor
final class BassJumpController: ObservableObject {
    /// The live controller, for Shortcuts actions.
    private(set) static weak var shared: BassJumpController?

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
    @Published var enabled: Bool { didSet { saveGlobal(); reconcile(); ControlBridge.stateChanged() } }
    @Published var followSystemVolume: Bool { didSet { saveGlobal(); applyParameters() } }
    @Published var pauseForHeadphones: Bool { didSet { saveGlobal(); reconcile() } }
    @Published var subwooferUID: String { didSet { saveGlobal(); reconcile() } }   // "" = automatic
    @Published var hotKeyEnabled: Bool { didSet { saveGlobal(); updateHotKey() } }
    @Published var skipCalls: Bool { didSet { saveGlobal(); reconcile() } }
    @Published var ignoredApps: [String] { didSet { saveGlobal(); reconcile() } }   // bundle IDs
    @Published var loudness: Bool { didSet { saveGlobal(); applyParameters() } }
    @Published var stereoSubs: Bool { didSet { saveGlobal(); reconcile() } }
    @Published var notifyOnConnect: Bool { didSet { saveGlobal() } }
    @Published var liveIcon: Bool { didSet { saveGlobal() } }
    /// Quieter bass with peaks held well down, for late at night.
    @Published var nightMode: Bool { didSet { saveGlobal(); applyParameters(); ControlBridge.stateChanged() } }

    // MARK: Per-output settings (remembered for each speaker/output device)
    @Published var crossover: Double { didSet { profileChanged(applyOnly: true); updatePresetName() } }
    @Published var level: Double { didSet { profileChanged(applyOnly: true); updatePresetName() } }
    @Published var alignedMode: Bool { didSet { profileChanged(applyOnly: false) } }
    @Published var highPassMain: Bool { didSet { profileChanged(applyOnly: true) } }
    @Published var alignmentMs: Double { didSet { profileChanged(applyOnly: true) } }
    @Published var invertSub: Bool { didSet { profileChanged(applyOnly: true) } }
    @Published var eqEnabled: Bool { didSet { profileChanged(applyOnly: true) } }
    @Published var eq1Hz: Double { didSet { profileChanged(applyOnly: true) } }
    @Published var eq1DB: Double { didSet { profileChanged(applyOnly: true) } }
    @Published var eq2Hz: Double { didSet { profileChanged(applyOnly: true) } }
    @Published var eq2DB: Double { didSet { profileChanged(applyOnly: true) } }

    // MARK: State
    @Published private(set) var status: Status = .off
    @Published private(set) var presetName = "Custom"
    @Published private(set) var customPresets: [BassPreset] = []
    @Published private(set) var outputDevices: [AudioDeviceInfo] = []
    @Published private(set) var profileOutputName: String?
    @Published private(set) var permissionProblem = false
    /// True while the limiter is turning the bass down (shown next to the level meter).
    @Published private(set) var limiting = false
    /// Apps currently using audio (for the "ignore an app" menu), excluding ourselves.
    @Published private(set) var audioApps: [AudioAppInfo] = []
    /// 0–3, drives the animated menu bar icon.
    @Published private(set) var iconLevel = 0
    @Published private(set) var stereoActive = false
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
            "subwooferUID": "", "hotKeyEnabled": true, "skipCalls": true, "loudness": false,
            "stereoSubs": true, "notifyOnConnect": true, "liveIcon": true, "nightMode": false,
            "crossover": 150.0, "level": 0.6, "alignedMode": false, "highPassMain": false, "alignmentMs": 0.0,
        ])
        enabled = defaults.bool(forKey: "enabled")
        followSystemVolume = defaults.bool(forKey: "followSystemVolume")
        pauseForHeadphones = defaults.bool(forKey: "pauseForHeadphones")
        subwooferUID = defaults.string(forKey: "subwooferUID") ?? ""
        hotKeyEnabled = defaults.bool(forKey: "hotKeyEnabled")
        skipCalls = defaults.bool(forKey: "skipCalls")
        ignoredApps = defaults.stringArray(forKey: "ignoredApps") ?? []
        loudness = defaults.bool(forKey: "loudness")
        stereoSubs = defaults.bool(forKey: "stereoSubs")
        notifyOnConnect = defaults.bool(forKey: "notifyOnConnect")
        liveIcon = defaults.bool(forKey: "liveIcon")
        nightMode = defaults.bool(forKey: "nightMode")
        // Last-used sound settings seed any output that has no profile yet.
        crossover = defaults.double(forKey: "crossover")
        level = defaults.double(forKey: "level")
        alignedMode = defaults.bool(forKey: "alignedMode")
        highPassMain = defaults.bool(forKey: "highPassMain")
        alignmentMs = defaults.double(forKey: "alignmentMs")
        invertSub = defaults.bool(forKey: "invertSub")
        eqEnabled = true; eq1Hz = 60; eq1DB = 0; eq2Hz = 100; eq2DB = 0   // per-output only
        profiles = defaults.decoded([String: OutputProfile].self, forKey: "profiles") ?? [:]
        customPresets = defaults.decoded([BassPreset].self, forKey: "customPresets") ?? []
        updatePresetName()

        let system = AudioObjectID(kAudioObjectSystemObject)
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                    kAudioHardwarePropertyProcessObjectList] {
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
        Self.shared = self
        ControlBridge.listen { [weak self] on in self?.enabled = on }
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
    private var suspectApp = ""
    private lazy var tapVerified = defaults.bool(forKey: "tapVerified")

    /// An app (not us, not one we exclude from the tap) that currently has audio output running.
    private func playingIncludedApp() -> String? {
        AudioSystem.audioProcesses().first { $0.isPlaying && !isExcluded($0.bundleID) }
            .map { $0.bundleID.isEmpty ? "pid \($0.pid)" : $0.bundleID }
    }

    private func tick() {
        let running = engine.isRunning
        let value = running ? engine.dsp.peak : 0
        if meterModel.isVisible || meterModel.level != 0 { meterModel.level = meterModel.isVisible ? value : 0 }
        if running { maxPeak = max(maxPeak, value); maxInput = max(maxInput, engine.dsp.inputPeak) }
        ticks += 1
        if ticks % 3 == 0 {   // ~7 Hz is plenty for the menu bar icon
            let peak = running ? engine.dsp.peak : 0
            let bucket = !liveIcon || peak < 0.02 ? 0 : (peak < 0.15 ? 1 : (peak < 0.4 ? 2 : 3))
            if bucket != iconLevel { iconLevel = bucket }
            let isLimiting = running && engine.dsp.limiterGainNow < 0.8   // > ~2 dB of limiting
            if isLimiting != limiting { limiting = isLimiting }
        }

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

            // Permission check: an app we're *not* excluding is playing, yet the tap delivers
            // digital silence. Apps often keep a silent output stream open (paused players,
            // browsers), so once the tap has ever delivered sound with this build's permission,
            // require a full minute of silence instead of 10 s before warning.
            if running && engine.dsp.inputPeak == 0, let app = playingIncludedApp() {
                silentWhileOthersPlay += 1
                suspectApp = app
            } else if engine.dsp.inputPeak > 0 {
                silentWhileOthersPlay = 0
                if !tapVerified { tapVerified = true; defaults.set(true, forKey: "tapVerified") }
            }
            let problem = silentWhileOthersPlay >= (tapVerified ? 30 : 5)
            if problem != permissionProblem {
                permissionProblem = problem
                if problem { log.error("Tap is silent while \(self.suspectApp, privacy: .public) plays — system audio permission is probably off") }
            }
            if running && debugLogging {
                let g = engine.dsp.limiterGainNow
                if g < 0.99 { log.notice("Limiter: \(20 * log10(g), privacy: .public) dB") }
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
                      highPassMain: highPassMain, alignmentMs: alignmentMs, invertSub: invertSub,
                      eqEnabled: eqEnabled, eq1Hz: eq1Hz, eq1DB: eq1DB, eq2Hz: eq2Hz, eq2DB: eq2DB)
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
        defaults.set(p.invertSub, forKey: "invertSub")
        if applyOnly { applyParameters() } else { reconcile() }
    }

    /// Switch to the profile for the current output, creating it from the last-used settings.
    private func selectProfile(for output: AudioDeviceInfo?) {
        guard let output, output.uid != profileUID else { return }
        profileUID = output.uid
        profileOutputName = output.name
        let p: OutputProfile
        if let saved = profiles[output.uid] {
            p = saved
        } else {
            // New output: keep the last-used level/crossover/phase, but pick the mode that suits
            // this kind of speaker, and start with a flat EQ (EQ cuts are room/speaker-specific).
            var fresh = currentProfile
            fresh.aligned = OutputProfile.suggestsAlignedMode(for: output)
            fresh.highPassMain = false; fresh.alignmentMs = 0
            fresh.eq1DB = 0; fresh.eq2DB = 0
            p = fresh
            log.info("New output \(output.name, privacy: .public): \(fresh.aligned ? "time-aligned" : "sub-only", privacy: .public) mode")
        }
        profiles[output.uid] = p
        defaults.encode(profiles, forKey: "profiles")
        loadingProfile = true
        crossover = p.crossover; level = p.level; alignedMode = p.aligned
        highPassMain = p.highPassMain; alignmentMs = p.alignmentMs; invertSub = p.invertSub
        eqEnabled = p.eqEnabled; eq1Hz = p.eq1Hz; eq1DB = p.eq1DB; eq2Hz = p.eq2Hz; eq2DB = p.eq2DB
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

        let bassJumps = outputDevices.filter(\.looksLikeBassJump)
        let sub: AudioDeviceInfo? = subwooferUID.isEmpty
            ? bassJumps.first
            : outputDevices.first(where: { $0.uid == subwooferUID })
        let sub2: AudioDeviceInfo? = stereoSubs ? bassJumps.first(where: { $0.id != sub?.id }) : nil
        stereoActive = sub != nil && sub2 != nil
        notifyConnectionChange(present: sub != nil, name: sub?.name)
        let defaultOut = AudioSystem.defaultOutputDevice()
        let main = AudioSystem.info(for: defaultOut)
        if let main, main.id != sub?.id { selectProfile(for: main) }
        refreshAudioApps()

        let desired: Status
        if !enabled { desired = .off }
        else if sub == nil { desired = .noDevice }
        else if defaultOut == sub!.id { desired = .notSpeakers }   // the BassJump itself is the output
        else if pauseForHeadphones && !AudioSystem.isSpeakers(defaultOut) { desired = .notSpeakers }
        else { desired = .playing(sub: stereoActive ? "two BassJumps" : sub!.name, main: alignedMode ? main?.name : nil) }

        if case .playing = desired, let sub {
            let config = EngineConfig(aligned: alignedMode && main != nil, subUID: sub.uid,
                                      mainUID: alignedMode ? main?.uid : nil,
                                      fillAllChannels: defaults.bool(forKey: "fillAllChannels"),
                                      fillCenter: defaults.bool(forKey: "fillCenter"),
                                      subUID2: sub2?.uid,
                                      excludedProcesses: excludedProcessObjects())
            if engine.config != config {
                do {
                    try engine.start(config)
                } catch {
                    status = .error("Couldn't start: \(error)")
                    watchDeviceHealth(sub: nil, main: nil)
                    return
                }
            }
            watchDeviceHealth(sub: sub.id, main: config.aligned ? main?.id : sub2?.id)
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

    // MARK: Calibration hooks

    private var calibrationOverride: (gain: Float, invert: Bool, crossover: Double?)?

    func setCalibrationOverride(gain: Float, invert: Bool, crossover: Double?) {
        calibrationOverride = (gain, invert, crossover)
        applyParameters()
    }

    func clearCalibrationOverride() {
        guard calibrationOverride != nil else { return }
        calibrationOverride = nil
        applyParameters()
    }

    func applyCalibration(crossover: Double, level: Double, invert: Bool, eqCut: (hz: Double, db: Double)) {
        self.crossover = crossover
        self.level = level
        self.invertSub = invert
        // Band 1 is the room band: calibration sets it (or flattens it if no boom was found).
        eq1Hz = eqCut.hz; eq1DB = eqCut.db
        if eqCut.db != 0 { eqEnabled = true }
        log.info("Applied calibration: \(crossover) Hz, level \(level), invert \(invert), EQ \(eqCut.db) dB @ \(eqCut.hz) Hz")
    }


    private func applyParameters() {
        let dsp = engine.dsp
        let eqOn = eqEnabled && calibrationOverride == nil   // calibration measures with EQ off
        dsp.eq1Hz = eq1Hz; dsp.eq1DB = eqOn ? eq1DB : 0
        dsp.eq2Hz = eq2Hz; dsp.eq2DB = eqOn ? eq2DB : 0
        if let o = calibrationOverride {
            dsp.subGain = o.gain
            dsp.invertSub = o.invert
            dsp.limiterThreshold = 0.89; dsp.limiterReleaseMs = 150
            if let x = o.crossover { dsp.crossoverHz = x }
            return
        }
        var gain = Float(level) * 2.0          // level 1.0 = +6 dB into the limiter
        if followSystemVolume {
            let out = AudioSystem.defaultOutputDevice()
            if AudioSystem.isMuted(out) { gain = 0 }
            else if let v = AudioSystem.volume(out) {
                gain *= v
                // Loudness: ears lose bass at low volume, so add up to +9 dB as volume falls.
                if loudness && !nightMode { gain *= Float(pow(10, 9 * Double(1 - v) / 20)) }
            }
        }
        // Night mode: −6 dB, and the limiter holds peaks ~10 dB lower with a slow, smooth release
        // so explosions and drops don't boom through the house.
        if nightMode { gain *= 0.5 }
        dsp.limiterThreshold = nightMode ? 0.3 : 0.89
        dsp.limiterReleaseMs = nightMode ? 400 : 150
        dsp.crossoverHz = crossover
        dsp.subGain = gain
        dsp.highPassMain = highPassMain
        dsp.alignmentMs = alignmentMs
        dsp.invertSub = invertSub
    }

    // MARK: Per-app rules

    private func isExcluded(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        if skipCalls && CallApps.bundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) { return true }
        return ignoredApps.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    private func excludedProcessObjects() -> [AudioObjectID] {
        AudioSystem.audioProcesses().filter { isExcluded($0.bundleID) }.map(\.object).sorted()
    }

    private func refreshAudioApps() {
        var seen = Set<String>()
        audioApps = AudioSystem.audioProcesses().compactMap { p -> AudioAppInfo? in
            let app = NSRunningApplication(processIdentifier: p.pid)
            let bundle = app?.bundleIdentifier ?? p.bundleID
            guard !bundle.isEmpty, seen.insert(bundle).inserted else { return nil }
            return AudioAppInfo(bundleID: bundle, name: app?.localizedName ?? bundle, isPlaying: p.isPlaying,
                                isCallApp: CallApps.bundlePrefixes.contains { bundle.hasPrefix($0) })
        }
        .sorted { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
    }

    func toggleIgnored(_ bundleID: String) {
        if ignoredApps.contains(bundleID) { ignoredApps.removeAll { $0 == bundleID } }
        else { ignoredApps.append(bundleID) }
    }

    func appName(for bundleID: String) -> String {
        audioApps.first { $0.bundleID == bundleID }?.name
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? bundleID
    }

    // MARK: Notifications

    private var lastSubPresent: Bool?
    private func notifyConnectionChange(present: Bool, name: String?) {
        defer { lastSubPresent = present }
        guard let last = lastSubPresent, last != present, notifyOnConnect else { return }
        let title = present ? "BassJump connected" : "BassJump disconnected"
        let body = present ? "Bass is playing through \(name ?? "your BassJump")." : "Plug it back in to bring the bass back."
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func saveGlobal() {
        defaults.set(enabled, forKey: "enabled")
        defaults.set(followSystemVolume, forKey: "followSystemVolume")
        defaults.set(pauseForHeadphones, forKey: "pauseForHeadphones")
        defaults.set(subwooferUID, forKey: "subwooferUID")
        defaults.set(hotKeyEnabled, forKey: "hotKeyEnabled")
        defaults.set(skipCalls, forKey: "skipCalls")
        defaults.set(ignoredApps, forKey: "ignoredApps")
        defaults.set(loudness, forKey: "loudness")
        defaults.set(stereoSubs, forKey: "stereoSubs")
        defaults.set(notifyOnConnect, forKey: "notifyOnConnect")
        defaults.set(liveIcon, forKey: "liveIcon")
        defaults.set(nightMode, forKey: "nightMode")
    }
}

@MainActor
final class MeterModel: ObservableObject {
    @Published var level: Float = 0
    var isVisible = false
}

struct AudioAppInfo: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let isPlaying: Bool
    let isCallApp: Bool
    var id: String { bundleID }
}
