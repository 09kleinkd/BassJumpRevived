import CoreAudio
import Foundation
import os

/// Captures the system mix with a Core Audio process tap and plays the low-passed
/// signal on the BassJump through a private aggregate device (BassJump + tap).
/// This replaces 3.0.1's virtual device + "player" daemon with no driver at all.
final class BassEngine {
    let dsp = BassDSP()
    private(set) var isRunning = false
    private(set) var deviceUID: String?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity = 16_384
    private let log = Logger(subsystem: "local.bassjump.revived", category: "engine")

    init() {
        scratch = .allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
    }

    deinit {
        stop()
        scratch.deallocate()
    }

    func start(subwooferUID: String) throws {
        stop()
        do {
            try createTap()
            try createAggregate(subwooferUID: subwooferUID)
            try startIO()
            deviceUID = subwooferUID
            isRunning = true
            log.info("Engine started on \(subwooferUID, privacy: .public) at \(self.dsp.sampleRate) Hz")
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
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        if isRunning { log.info("Engine stopped") }
        isRunning = false
        deviceUID = nil
        dsp.reset()
    }

    // MARK: - Setup

    private var tapUUID = UUID()

    private func createTap() throws {
        // Exclude ourselves so the BassJump's own output is never fed back into the tap.
        let me = AudioSystem.ownProcessObject()
        let exclude = me == kAudioObjectUnknown ? [] : [me]
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        description.name = "BassJump Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted   // the Mac's speakers keep playing normally
        tapUUID = description.uuid
        var id = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &id), "AudioHardwareCreateProcessTap")
        tapID = id
    }

    private func createAggregate(subwooferUID: String) throws {
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "BassJump Crossover",
            kAudioAggregateDeviceUIDKey: "local.bassjump.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: subwooferUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: subwooferUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUUID.uuidString,
                 kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &id), "AudioHardwareCreateAggregateDevice")
        aggregateID = id

        dsp.sampleRate = (try? CA.get(id, address(kAudioDevicePropertyNominalSampleRate), Float64(48_000))) ?? 48_000
        // Smaller buffers keep the sub closer in time to the built-in speakers.
        try? CA.set(id, address(kAudioDevicePropertyBufferFrameSize), UInt32(256))
    }

    private func startIO() throws {
        let dsp = self.dsp
        let scratch = self.scratch
        let capacity = scratchCapacity

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inInput, _, outOutput, _ in
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            let output = UnsafeMutableAudioBufferListPointer(outOutput)

            // Frames requested by the output side.
            var frames = 0
            if let first = output.first, first.mNumberChannels > 0 {
                frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
            }
            frames = min(frames, capacity)
            guard frames > 0 else { return }

            // 1. Mix every input channel (the tap) down to mono.
            scratch.update(repeating: 0, count: frames)
            var inChannels = 0
            for buf in input {
                guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let ch = Int(buf.mNumberChannels)
                guard ch > 0 else { continue }
                let n = min(frames, Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch))
                for f in 0..<n {
                    var s: Float = 0
                    for c in 0..<ch { s += data[f * ch + c] }
                    scratch[f] += s
                }
                inChannels += ch
            }
            if inChannels > 1 {
                let k = 1 / Float(inChannels)
                for f in 0..<frames { scratch[f] *= k }
            }

            // 2. Crossover + gain + limiter.
            dsp.render(scratch, frames: frames)

            // 3. Same mono bass signal to every BassJump channel.
            for buf in output {
                guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let ch = Int(buf.mNumberChannels)
                guard ch > 0 else { continue }
                let n = min(frames, Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch))
                for f in 0..<n {
                    let s = scratch[f]
                    for c in 0..<ch { data[f * ch + c] = s }
                }
            }
        }
        try check(status, "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = procID
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }
}
