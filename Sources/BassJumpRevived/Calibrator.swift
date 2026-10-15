import AVFoundation
import Foundation
import os

private let log = Logger(subsystem: "local.bassjump.revived", category: "calibration")

/// Measures the room with the Mac's microphone and suggests crossover, level and phase.
///
/// 1. Pink noise with the sub muted → the speakers' own bass roll-off sets the crossover.
/// 2. Noise with the sub on, normal and inverted polarity → keep whichever sums louder
///    around the crossover.
/// 3. Solve for the sub gain that brings the bass bands up to the speakers' midrange level.
/// 4. Predict the bass response at that gain; if one band booms well above the rest (a room
///    mode), suggest a sub EQ cut there.
///
/// Test noise is played by a separate `afplay` process, because BassJump's own audio is
/// excluded from its tap.
@MainActor
final class Calibrator: ObservableObject {
    struct Result: Equatable {
        var crossover: Double
        var level: Double
        var invert: Bool
        var rolloff: Double
        var note: String?
        /// Suggested sub EQ cut for a room boom, if any.
        var eqCut: EQCut?
    }

    struct EQCut: Equatable { var hz: Double; var db: Double }

    enum Phase: Equatable {
        case idle, ready
        case running(step: String, progress: Double)
        case done(Result)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var inputName = ""
    private weak var controller: BassJumpController?
    private var task: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private let recorder = SampleRecorder()
    private var noiseURL: URL?
    private var player: Process?

    init(controller: BassJumpController) {
        self.controller = controller
    }

    func prepare() {
        inputName = AudioSystem.defaultInputName() ?? "default microphone"
        phase = .ready
    }

    func cancel() {
        task?.cancel()
        task = nil
        cleanup()
        phase = .idle
    }

    func start() {
        task = Task { await run() }
    }

    func apply(_ r: Result) {
        controller?.applyCalibration(crossover: r.crossover, level: r.level, invert: r.invert,
                                     eqCut: (r.eqCut?.hz ?? 60, r.eqCut?.db ?? 0))   // no boom → flat
        phase = .idle
    }

    // MARK: Run

    private func run() async {
        guard let controller else { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            phase = .failed("BassJump needs microphone access to calibrate. Allow it in Privacy & Security → Microphone.")
            return
        }
        guard controller.status.isPlaying else {
            phase = .failed("Turn BassJump on and make sure it's playing through your BassJump first.")
            return
        }
        do {
            try startCapture()
            noiseURL = try writePinkNoise(seconds: 3.5)
            let startVolume = AudioSystem.volume(AudioSystem.defaultOutputDevice()) ?? 0.5

            // 1. Speakers alone.
            phase = .running(step: "Measuring your speakers…", progress: 0.1)
            controller.setCalibrationOverride(gain: 0, invert: false, crossover: nil)
            let speakers = try await measure()

            let mid = mean(speakers, in: 315...2000)
            var rolloff = 250.0
            for (f, db) in speakers.reversed() where f <= 250 && f >= 50 {
                if db >= mid - 6 { rolloff = f } else { break }
            }
            let crossover = (min(max(rolloff, 60), 250) / 5).rounded() * 5
            log.info("Speakers: mid \(mid) dB, roll-off \(rolloff) Hz → crossover \(crossover) Hz")

            // 2. Sub on, normal and flipped polarity, at a reference gain.
            let refGain: Float = 1.0
            phase = .running(step: "Measuring the sub…", progress: 0.4)
            controller.setCalibrationOverride(gain: refGain, invert: false, crossover: crossover)
            let normal = try await measure()
            phase = .running(step: "Checking phase…", progress: 0.7)
            controller.setCalibrationOverride(gain: refGain, invert: true, crossover: crossover)
            let flipped = try await measure()

            let band = (crossover / 2)...(crossover * 2)
            let invert = power(flipped, in: band) > power(normal, in: band) * 1.12   // need a clear (>0.5 dB) win
            let withSub = invert ? flipped : normal

            // 3. Level: make the bands below the crossover reach the speakers' midrange level.
            let target = pow(10, mid / 10)
            var ratios: [Double] = []
            for ((f, s), (_, t)) in zip(speakers, withSub) where f >= 40 && f <= crossover {
                let ps = pow(10, s / 10), pt = pow(10, t / 10)
                let added = pt - ps
                if added > ps * 0.05 { ratios.append(max(0, target - ps) / added) }
            }
            var note: String?
            var gainFactor = 1.0
            if ratios.isEmpty {
                note = "The microphone barely heard the BassJump — try placing it closer or check its volume."
            } else {
                gainFactor = sqrt(ratios.sorted()[ratios.count / 2])
            }
            // 4. Room boom: predicted level of each bass band at the chosen gain.
            var eqCut: EQCut?
            if !ratios.isEmpty {
                let g2 = gainFactor * gainFactor
                var worst: (f: Double, excess: Double)?
                for ((f, s), (_, t)) in zip(speakers, withSub) where f >= 40 && f <= min(crossover, 160) {
                    let ps = pow(10, s / 10), added = max(0, pow(10, t / 10) - ps)
                    let predicted = 10 * log10(ps + added * g2)
                    let excess = predicted - mid
                    if excess > (worst?.excess ?? 3) { worst = (f, excess) }
                }
                if let worst {
                    let db = -min((worst.excess / 0.5).rounded() * 0.5, 10)
                    eqCut = EQCut(hz: worst.f, db: db)
                    log.info("Room boom at \(worst.f) Hz (+\(worst.excess) dB) → EQ \(db) dB")
                }
            }

            let effectiveGain = Double(refGain) * gainFactor
            // Convert to the "Bass level" setting: gain = level × 2 × volume (when following volume).
            let follow = controller.followSystemVolume
            var level = effectiveGain / (2 * (follow ? Double(max(startVolume, 0.05)) : 1))
            if level > 1.5 { note = note ?? "Your speakers out-bass the BassJump at this volume, so it's set to maximum." }
            level = (min(max(level, 0.1), 1.5) / 0.05).rounded() * 0.05

            controller.clearCalibrationOverride()
            cleanup()
            log.info("Calibration: crossover \(crossover) Hz, level \(level), invert \(invert)")
            phase = .done(Result(crossover: crossover, level: level, invert: invert, rolloff: rolloff,
                                 note: note, eqCut: eqCut))
        } catch is CancellationError {
            controller.clearCalibrationOverride()
            cleanup()
        } catch {
            controller.clearCalibrationOverride()
            cleanup()
            phase = .failed("Calibration failed: \(error.localizedDescription)")
        }
    }

    /// Plays the noise and returns third-octave band levels (dB) from the microphone.
    private func measure() async throws -> [(Double, Double)] {
        try Task.checkCancellation()
        guard let noiseURL else { throw CocoaError(.fileNoSuchFile) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = [noiseURL.path]
        try p.run()
        player = p
        try await Task.sleep(for: .milliseconds(900))        // let the sub path settle
        recorder.begin()
        try await Task.sleep(for: .milliseconds(2300))
        let samples = recorder.end()
        p.terminate()
        player = nil
        try await Task.sleep(for: .milliseconds(400))
        guard samples.count > 1000 else { throw CocoaError(.fileReadCorruptFile) }
        return BandAnalyzer.thirdOctaveLevels(samples, sampleRate: recorder.sampleRate)
    }

    // MARK: Audio plumbing

    private func startCapture() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw CocoaError(.featureUnsupported) }
        recorder.sampleRate = format.sampleRate
        let recorder = self.recorder
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            recorder.append(data, count: Int(buffer.frameLength))
        }
        try engine.start()
        self.engine = engine
    }

    private func cleanup() {
        player?.terminate(); player = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop(); engine = nil
        if let noiseURL { try? FileManager.default.removeItem(at: noiseURL) }
        noiseURL = nil
        controller?.clearCalibrationOverride()
    }

    /// Stereo pink noise (Paul Kellet's filter), -18 dBFS RMS, 16-bit WAV in the temp folder.
    private func writePinkNoise(seconds: Double) throws -> URL {
        let rate = 48_000, n = Int(Double(rate) * seconds)
        var pcm = Data(capacity: n * 4)
        var rng = SystemRandomNumberGenerator()
        var b = [[Double]](repeating: [Double](repeating: 0, count: 7), count: 2)
        var samples = [[Double]](repeating: [Double](repeating: 0, count: n), count: 2)
        for ch in 0..<2 {
            for i in 0..<n {
                let w = Double.random(in: -1...1, using: &rng)
                b[ch][0] = 0.99886 * b[ch][0] + w * 0.0555179
                b[ch][1] = 0.99332 * b[ch][1] + w * 0.0750759
                b[ch][2] = 0.96900 * b[ch][2] + w * 0.1538520
                b[ch][3] = 0.86650 * b[ch][3] + w * 0.3104856
                b[ch][4] = 0.55000 * b[ch][4] + w * 0.5329522
                b[ch][5] = -0.7616 * b[ch][5] - w * 0.0168980
                samples[ch][i] = b[ch][0] + b[ch][1] + b[ch][2] + b[ch][3] + b[ch][4] + b[ch][5] + b[ch][6] + w * 0.5362
                b[ch][6] = w * 0.115926
            }
            let rms = sqrt(samples[ch].reduce(0) { $0 + $1 * $1 } / Double(n))
            let scale = pow(10, -18.0 / 20) / rms
            let fade = rate / 20
            for i in 0..<n {
                let env = min(1, Double(min(i, n - 1 - i)) / Double(fade))
                samples[ch][i] *= scale * env
            }
        }
        for i in 0..<n {
            for ch in 0..<2 {
                var v = Int16(max(-1, min(1, samples[ch][i])) * 32767).littleEndian
                withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
            }
        }
        var header = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(2)
        u32(UInt32(rate)); u32(UInt32(rate * 4)); u16(4); u16(16)
        header.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bassjump-calibration.wav")
        try (header + pcm).write(to: url)
        return url
    }

    private func mean(_ bands: [(Double, Double)], in range: ClosedRange<Double>) -> Double {
        let v = bands.filter { range.contains($0.0) }.map(\.1)
        return v.isEmpty ? -100 : v.reduce(0, +) / Double(v.count)
    }

    private func power(_ bands: [(Double, Double)], in range: ClosedRange<Double>) -> Double {
        bands.filter { range.contains($0.0) }.reduce(0) { $0 + pow(10, $1.1 / 10) }
    }
}

/// Thread-safe sample accumulator fed from the input tap.
final class SampleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var recording = false
    var sampleRate: Double = 48_000

    func begin() { lock.lock(); samples.removeAll(keepingCapacity: true); recording = true; lock.unlock() }
    func end() -> [Float] { lock.lock(); recording = false; let s = samples; lock.unlock(); return s }
    func append(_ p: UnsafePointer<Float>, count: Int) {
        lock.lock(); defer { lock.unlock() }
        guard recording else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: p, count: count))
    }
}

/// Third-octave band levels via band-pass filtering (LR4 high-pass + LR4 low-pass per band).
enum BandAnalyzer {
    static let centers: [Double] = [40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000]

    static func thirdOctaveLevels(_ x: [Float], sampleRate: Double) -> [(Double, Double)] {
        let edge = pow(2.0, 1.0 / 6)
        let skip = min(x.count / 4, Int(sampleRate * 0.2))   // filter settling
        return centers.map { fc in
            var hp = LR4(), lp = LR4()
            hp.setHighPass(fc / edge, sampleRate)
            lp.setLowPass(fc * edge, sampleRate)
            var sum = 0.0
            for (i, v) in x.enumerated() {
                let y = lp.process(hp.process(v))
                if i >= skip { sum += Double(y * y) }
            }
            let ms = sum / Double(max(1, x.count - skip))
            return (fc, 10 * log10(ms + 1e-20))
        }
    }
}
