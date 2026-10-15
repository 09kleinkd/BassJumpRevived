import CoreAudio
import Foundation
import os

/// What the engine should be doing.
struct EngineConfig: Equatable {
    /// Time-aligned mode: the tap mutes normal playback and the app drives both the main
    /// speakers and the BassJump from one aggregate device, so they share a clock and timeline.
    var aligned: Bool
    var subUID: String
    /// Main speakers (aligned mode only).
    var mainUID: String?
    /// Aligned mode: spread stereo across every speaker channel the device describes
    /// (L/R/C/LFE/surrounds/heights) instead of only its stereo pair.
    var fillAllChannels = false
    /// When filling, also feed centre/LFE channels with (L+R)/2.
    var fillCenter = false
}

/// Captures the system mix with a Core Audio process tap and plays it through a private
/// aggregate device. Replaces BassJump 3.0.1's virtual driver + "player" daemon.
///
/// Sub-only mode: unmuted tap; aggregate = BassJump. Speakers keep playing normally.
/// Aligned mode:  muted tap; aggregate = main speakers (clock) + BassJump (drift-compensated).
final class BassEngine {
    let dsp = CrossoverDSP()
    private(set) var config: EngineConfig?
    var isRunning: Bool { config != nil }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapUUID = UUID()
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let log = Logger(subsystem: "local.bassjump.revived", category: "engine")

    // Real-time buffers, allocated once.
    private static let maxFrames = 16_384
    private static let maxChannels = 128
    private let inL = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let inR = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let outSub = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let outL = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let outR = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    /// Role of each aggregate output channel: 0 silent, 1 main L, 2 main R, 3 sub, 4 main mid (L+R)/2.
    private let roles = UnsafeMutablePointer<UInt8>.allocate(capacity: maxChannels)
    private var roleCount = 0
    /// Number of aggregate input channels that belong to subdevices (the tap follows them).
    private var tapFirstChannel = 0

    init() {
        for p in [inL, inR, outSub, outL, outR] { p.initialize(repeating: 0, count: Self.maxFrames) }
        roles.initialize(repeating: 0, count: Self.maxChannels)
    }

    deinit {
        stop()
        for p in [inL, inR, outSub, outL, outR] { p.deallocate() }
        roles.deallocate()
    }

    func start(_ config: EngineConfig) throws {
        stop()
        do {
            guard let sub = AudioSystem.device(uid: config.subUID) else {
                throw CoreAudioError(status: kAudioHardwareBadDeviceError, what: "find subwoofer")
            }
            var main: AudioDeviceInfo?
            if config.aligned {
                guard let uid = config.mainUID, let m = AudioSystem.device(uid: uid) else {
                    throw CoreAudioError(status: kAudioHardwareBadDeviceError, what: "find main speakers")
                }
                main = m
            }
            try createTap(muted: config.aligned)
            try createAggregate(config)
            mapChannels(main: main, sub: sub, fillAll: config.fillAllChannels, fillCenter: config.fillCenter)
            try startIO()
            self.config = config
            log.info("Engine started: \(config.aligned ? "aligned" : "sub-only", privacy: .public), sub=\(sub.name, privacy: .public), main=\(main?.name ?? "-", privacy: .public), \(self.dsp.sampleRate) Hz, tap input at ch \(self.tapFirstChannel), roles \((0..<self.roleCount).map { String(self.roles[$0]) }.joined(), privacy: .public)")
        } catch {
            log.error("Engine start failed: \(String(describing: error), privacy: .public)")
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let proc = ioProcID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)   // also un-mutes normal playback
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        if config != nil { log.info("Engine stopped") }
        config = nil
        dsp.reset()
    }

    // MARK: - Setup

    private func createTap(muted: Bool) throws {
        // Exclude ourselves so our own output is never fed back into the tap.
        let me = AudioSystem.ownProcessObject()
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: me == kAudioObjectUnknown ? [] : [me])
        description.name = "BassJump Tap"
        description.isPrivate = true
        description.muteBehavior = muted ? .muted : .unmuted
        tapUUID = description.uuid
        var id = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &id), "AudioHardwareCreateProcessTap")
        tapID = id
    }

    private func createAggregate(_ config: EngineConfig) throws {
        var subdevices: [[String: Any]] = []
        let clockUID: String
        if config.aligned, let mainUID = config.mainUID {
            clockUID = mainUID
            subdevices.append([kAudioSubDeviceUIDKey: mainUID])
            subdevices.append([kAudioSubDeviceUIDKey: config.subUID, kAudioSubDeviceDriftCompensationKey: true])
        } else {
            clockUID = config.subUID
            subdevices.append([kAudioSubDeviceUIDKey: config.subUID])
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "BassJump Crossover",
            kAudioAggregateDeviceUIDKey: "local.bassjump.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subdevices,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUUID.uuidString, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id), "AudioHardwareCreateAggregateDevice")
        aggregateID = id

        dsp.sampleRate = (try? CA.get(id, address(kAudioDevicePropertyNominalSampleRate), Float64(48_000))) ?? 48_000
        try? CA.set(id, address(kAudioDevicePropertyBufferFrameSize), UInt32(256))
    }

    /// Aggregate output channels are the subdevices' channels in list order (main first).
    /// Aggregate inputs are the subdevices' inputs, followed by the tap's stereo pair.
    private func mapChannels(main: AudioDeviceInfo?, sub: AudioDeviceInfo, fillAll: Bool, fillCenter: Bool) {
        roles.update(repeating: 0, count: Self.maxChannels)
        var index = 0
        var subInputs = AudioSystem.inputChannelCount(sub.id)
        if let main {
            let pair = AudioSystem.preferredStereo(main.id)
            let labels = fillAll ? AudioSystem.outputChannelLabels(main.id) : []
            for c in 0..<main.outputChannels where index + c < Self.maxChannels {
                var role: UInt8 = c == pair.left ? 1 : (c == pair.right ? 2 : 0)
                if role == 0, c < labels.count { role = Self.role(forLabel: labels[c]) }
                if role == 4 && !fillCenter { role = 0 }
                roles[index + c] = role
            }
            index += main.outputChannels
            subInputs += AudioSystem.inputChannelCount(main.id)
        }
        for c in 0..<sub.outputChannels where index + c < Self.maxChannels { roles[index + c] = 3 }
        roleCount = min(index + sub.outputChannels, Self.maxChannels)
        tapFirstChannel = subInputs
    }

    /// Left-side labels get L, right-side get R, centre/LFE get the mid signal.
    private static func role(forLabel label: UInt32) -> UInt8 {
        switch label {
        case kAudioChannelLabel_Left, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftCenter,
             kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_LeftWide, kAudioChannelLabel_LeftSurroundDirect,
             kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_TopBackLeft, kAudioChannelLabel_LeftTopFront,
             kAudioChannelLabel_LeftTopMiddle, kAudioChannelLabel_LeftTopRear:
            return 1
        case kAudioChannelLabel_Right, kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightCenter,
             kAudioChannelLabel_RearSurroundRight, kAudioChannelLabel_RightWide, kAudioChannelLabel_RightSurroundDirect,
             kAudioChannelLabel_VerticalHeightRight, kAudioChannelLabel_TopBackRight, kAudioChannelLabel_RightTopFront,
             kAudioChannelLabel_RightTopMiddle, kAudioChannelLabel_RightTopRear:
            return 2
        case kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2,
             kAudioChannelLabel_CenterSurround, kAudioChannelLabel_VerticalHeightCenter, kAudioChannelLabel_TopCenterSurround:
            return 4
        default:
            return 0
        }
    }

    private func startIO() throws {
        let dsp = self.dsp
        let (inL, inR, outSub, outL, outR, roles) = (self.inL, self.inR, self.outSub, self.outL, self.outR, self.roles)
        let roleCount = self.roleCount
        let tapFirst = self.tapFirstChannel
        let aligned = roleCount > 0 && (0..<roleCount).contains { roles[$0] == 1 || roles[$0] == 2 || roles[$0] == 4 }
        let maxFrames = Self.maxFrames

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inInput, _, outOutput, _ in
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            let output = UnsafeMutableAudioBufferListPointer(outOutput)

            var frames = 0
            for buf in output where buf.mNumberChannels > 0 {
                frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * Int(buf.mNumberChannels))
                break
            }
            frames = min(frames, maxFrames)
            guard frames > 0 else { return }

            // 1. Pull the tap's stereo pair out of the aggregate's inputs.
            inL.update(repeating: 0, count: frames)
            inR.update(repeating: 0, count: frames)
            var channel = 0
            for buf in input {
                let ch = Int(buf.mNumberChannels)
                defer { channel += ch }
                guard ch > 0, let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = min(frames, Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch))
                for c in 0..<ch {
                    let g = channel + c
                    if g == tapFirst { for f in 0..<n { inL[f] = data[f * ch + c] } }
                    if g == tapFirst + 1 { for f in 0..<n { inR[f] = data[f * ch + c] } }
                }
                if ch == 1, channel == tapFirst { for f in 0..<n { inR[f] = inL[f] } }   // mono tap
            }

            // 2. Crossover.
            dsp.render(inL: inL, inR: inR, frames: frames, sub: outSub,
                       mainL: aligned ? outL : nil, mainR: aligned ? outR : nil)

            // 3. Write every aggregate output channel by role.
            channel = 0
            for buf in output {
                let ch = Int(buf.mNumberChannels)
                defer { channel += ch }
                guard ch > 0, let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = min(frames, Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch))
                for c in 0..<ch {
                    let g = channel + c
                    let role = g < roleCount ? roles[g] : 0
                    switch role {
                    case 1: for f in 0..<n { data[f * ch + c] = outL[f] }
                    case 2: for f in 0..<n { data[f * ch + c] = outR[f] }
                    case 3: for f in 0..<n { data[f * ch + c] = outSub[f] }
                    case 4: for f in 0..<n { data[f * ch + c] = (outL[f] + outR[f]) * 0.5 }
                    default: for f in 0..<n { data[f * ch + c] = 0 }
                    }
                }
            }
        }
        try check(status, "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = procID
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }
}
