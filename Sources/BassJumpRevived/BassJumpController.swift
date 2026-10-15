import CoreAudio
import Foundation
import ServiceManagement
import SwiftUI
import os

private let engineLog = Logger(subsystem: "local.bassjump.revived", category: "meter")

@MainActor
final class BassJumpController: ObservableObject {
    enum Status: Equatable {
        case off, playing(String), noDevice, notSpeakers, error(String)

        var text: String {
            switch self {
            case .off: return "Off"
            case .playing(let name): return "Playing through \(name)"
            case .noDevice: return "BassJump not connected"
            case .notSpeakers: return "Paused — sound is going to headphones or a wireless device"
            case .error(let msg): return msg
            }
        }
    }

    // MARK: Settings (persisted)
    @Published var enabled: Bool { didSet { save(); reconcile() } }
    @Published var crossover: Double { didSet { save(); applyParameters(); updatePresetName() } }
    @Published var level: Double { didSet { save(); applyParameters(); updatePresetName() } }
    @Published var followSystemVolume: Bool { didSet { save(); applyParameters() } }
    @Published var pauseForHeadphones: Bool { didSet { save(); reconcile() } }
    @Published var subwooferUID: String { didSet { save(); reconcile() } }   // "" = automatic

    // MARK: State
    @Published private(set) var status: Status = .off
    @Published private(set) var presetName = "Custom"
    @Published private(set) var outputDevices: [AudioDeviceInfo] = []
    /// Separate model so 20 Hz meter updates don't redraw the menu bar icon.
    let meterModel = MeterModel()
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { NSLog("Launch at login: \(error)") }
        }
    }

    private let engine = BassEngine()
    private let defaults = UserDefaults.standard
    private var systemListeners: [PropertyListener] = []
    private var outputListeners: [PropertyListener] = []
    private var listenedOutput = AudioObjectID(kAudioObjectUnknown)
    private var meterTimer: Timer?
    private var reconcilePending = false

    init() {
        defaults.register(defaults: [
            "enabled": true, "crossover": 150.0, "level": 0.6,
            "followSystemVolume": true, "pauseForHeadphones": true, "subwooferUID": "",
        ])
        enabled = defaults.bool(forKey: "enabled")
        crossover = defaults.double(forKey: "crossover")
        level = defaults.double(forKey: "level")
        followSystemVolume = defaults.bool(forKey: "followSystemVolume")
        pauseForHeadphones = defaults.bool(forKey: "pauseForHeadphones")
        subwooferUID = defaults.string(forKey: "subwooferUID") ?? ""
        updatePresetName()

        let system = AudioObjectID(kAudioObjectSystemObject)
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            if let l = PropertyListener(system, address(sel), { [weak self] in self?.scheduleReconcile() }) {
                systemListeners.append(l)
            }
        }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickMeter() }
        }
        reconcile()
    }

    private var meterTicks = 0
    private var maxPeakSinceLog: Float = 0
    private var maxInputSinceLog: Float = 0
    private func tickMeter() {
        let value = engine.isRunning ? engine.dsp.peak : 0
        if meterModel.isVisible || meterModel.level != 0 { meterModel.level = meterModel.isVisible ? value : 0 }
        maxPeakSinceLog = max(maxPeakSinceLog, value)
        if engine.isRunning { maxInputSinceLog = max(maxInputSinceLog, engine.dsp.inputPeak) }
        meterTicks += 1
        if meterTicks % 100 == 0, engine.isRunning {   // every 5 s
            engineLog.notice("Last 5 s — tap in: \(self.maxInputSinceLog, privacy: .public), sub out: \(self.maxPeakSinceLog, privacy: .public), gain \(self.engine.dsp.targetGain, privacy: .public)")
            maxPeakSinceLog = 0
            maxInputSinceLog = 0
        }
    }

    // MARK: Presets

    func apply(_ preset: BassPreset) {
        crossover = preset.crossover
        level = preset.level
    }

    private func updatePresetName() {
        presetName = BassPreset.all.first { abs($0.crossover - crossover) < 0.5 && abs($0.level - level) < 0.005 }?.name ?? "Custom"
    }

    // MARK: Core logic

    /// Device-change notifications arrive in bursts; coalesce them.
    private func scheduleReconcile() {
        guard !reconcilePending else { return }
        reconcilePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.reconcilePending = false
            self?.reconcile()
        }
    }

    func reconcile() {
        outputDevices = AudioSystem.outputDevices()
        watchDefaultOutput()

        let sub: AudioDeviceInfo? = subwooferUID.isEmpty
            ? outputDevices.first(where: \.looksLikeBassJump)
            : outputDevices.first(where: { $0.uid == subwooferUID })
        let defaultOut = AudioSystem.defaultOutputDevice()

        let desired: Status
        if !enabled { desired = .off }
        else if sub == nil { desired = .noDevice }
        else if defaultOut == sub!.id { desired = .notSpeakers }   // user picked the BassJump itself as output
        else if pauseForHeadphones && !AudioSystem.isSpeakers(defaultOut) { desired = .notSpeakers }
        else { desired = .playing(sub!.name) }

        if case .playing = desired, let sub {
            if !engine.isRunning || engine.deviceUID != sub.uid {
                do {
                    try engine.start(subwooferUID: sub.uid)
                } catch {
                    status = .error("Couldn't start: \(error)")
                    return
                }
            }
            applyParameters()
        } else {
            engine.stop()
        }
        status = desired
    }

    private func watchDefaultOutput() {
        let out = AudioSystem.defaultOutputDevice()
        guard out != listenedOutput else { return }
        listenedOutput = out
        outputListeners.removeAll()
        guard out != kAudioObjectUnknown else { return }
        var addrs = [
            address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain),
            address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, 1),
            address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, 2),
            address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain),
        ]
        addrs = addrs.filter { CA.has(out, $0) }
        for a in addrs {
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
        engine.dsp.crossoverHz = crossover
        engine.dsp.targetGain = gain
    }

    private func save() {
        defaults.set(enabled, forKey: "enabled")
        defaults.set(crossover, forKey: "crossover")
        defaults.set(level, forKey: "level")
        defaults.set(followSystemVolume, forKey: "followSystemVolume")
        defaults.set(pauseForHeadphones, forKey: "pauseForHeadphones")
        defaults.set(subwooferUID, forKey: "subwooferUID")
    }
}

@MainActor
final class MeterModel: ObservableObject {
    @Published var level: Float = 0
    var isVisible = false
}
