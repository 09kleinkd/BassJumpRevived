import XCTest
import CoreAudio
@testable import BassJumpRevived

/// Frequency-response checks for the crossover filters, measured by driving them with sine
/// waves and reading the steady-state amplitude.
final class DSPTests: XCTestCase {
    let rate = 48_000.0

    /// Steady-state gain (dB) of `process` for a sine at `freq`.
    private func gainDB(at freq: Double, _ process: (Float) -> Float) -> Double {
        let n = Int(rate)                           // 1 s; measure the last half
        var peak: Float = 0
        for i in 0..<n {
            let y = process(Float(sin(2 * .pi * freq * Double(i) / rate)))
            if i > n / 2 { peak = max(peak, abs(y)) }
        }
        return 20 * log10(Double(peak))
    }

    func testLR4LowPassIsMinus6dBAtCrossover() {
        var lp = LR4(); lp.setLowPass(150, rate)
        XCTAssertEqual(gainDB(at: 150) { lp.process($0) }, -6.02, accuracy: 0.1)
    }

    func testLR4HighPassIsMinus6dBAtCrossover() {
        var hp = LR4(); hp.setHighPass(150, rate)
        XCTAssertEqual(gainDB(at: 150) { hp.process($0) }, -6.02, accuracy: 0.1)
    }

    func testLR4PassbandIsFlat() {
        var lp = LR4(); lp.setLowPass(150, rate)
        XCTAssertEqual(gainDB(at: 30) { lp.process($0) }, 0, accuracy: 0.1)
        var hp = LR4(); hp.setHighPass(150, rate)
        XCTAssertEqual(gainDB(at: 2_000) { hp.process($0) }, 0, accuracy: 0.1)
    }

    func testLR4StopbandFallsAt24dBPerOctave() {
        var lp = LR4(); lp.setLowPass(150, rate)
        // Two octaves above the crossover: about -48 dB.
        XCTAssertLessThan(gainDB(at: 600) { lp.process($0) }, -44)
    }

    /// Linkwitz-Riley's defining property: low-pass + high-pass sum to a flat (all-pass) response.
    func testLowPlusHighSumsFlat() {
        for f in [40.0, 100, 150, 220, 800] {
            var lp = LR4(); lp.setLowPass(150, rate)
            var hp = LR4(); hp.setHighPass(150, rate)
            XCTAssertEqual(gainDB(at: f) { lp.process($0) + hp.process($0) }, 0, accuracy: 0.15, "at \(f) Hz")
        }
    }

    func testDelayLineDelaysByExactFrames() {
        let line = DelayLine(capacity: 64)
        var out: [Float] = []
        for i in 0..<20 { out.append(line.process(i == 0 ? 1 : 0, delay: 7)) }
        XCTAssertEqual(out.firstIndex(of: 1), 7)
    }

    func testSubOutputNeverExceedsFullScale() {
        let dsp = CrossoverDSP()
        dsp.sampleRate = rate; dsp.subGain = 3   // +9.5 dB into the limiter
        let n = 4_800
        let loud = [Float](unsafeUninitializedCapacity: n) { buf, count in
            for i in 0..<n { buf[i] = Float(sin(2 * .pi * 60 * Double(i) / 48_000)) }
            count = n
        }
        var sub = [Float](repeating: 0, count: n)
        loud.withUnsafeBufferPointer { inp in
            sub.withUnsafeMutableBufferPointer { out in
                dsp.render(inL: inp.baseAddress!, inR: inp.baseAddress!, frames: n,
                           sub: out.baseAddress!, mainL: nil, mainR: nil)
            }
        }
        XCTAssertLessThanOrEqual(sub.map(abs).max()!, 1)
        XCTAssertGreaterThan(sub.map(abs).max()!, 0.5)
    }

    func testSilentWhenGainIsZero() {
        let dsp = CrossoverDSP()
        dsp.sampleRate = rate; dsp.subGain = 0
        let n = 2_048
        let input = [Float](repeating: 0.8, count: n)
        var sub = [Float](repeating: 1, count: n)
        input.withUnsafeBufferPointer { inp in
            sub.withUnsafeMutableBufferPointer { out in
                dsp.render(inL: inp.baseAddress!, inR: inp.baseAddress!, frames: n,
                           sub: out.baseAddress!, mainL: nil, mainR: nil)
            }
        }
        XCTAssertEqual(sub.map(abs).max()!, 0)
    }
}

final class LimiterAndEQTests: XCTestCase {
    let rate = 48_000.0

    private func sine(_ f: Double, amp: Double, n: Int) -> [Float] {
        (0..<n).map { Float(amp * sin(2 * .pi * f * Double($0) / rate)) }
    }

    /// The look-ahead limiter must never let a sample past its ceiling, even on a sudden
    /// burst 12 dB over it.
    func testLimiterNeverExceedsThreshold() {
        let lim = LookaheadLimiter(sampleRate: rate)
        lim.threshold = 0.5
        var x = [Float](repeating: 0, count: 2_000) + sine(50, amp: 2, n: 20_000) + sine(80, amp: 0.1, n: 5_000)
        x[2_000] = 4   // single-sample spike at the start of the burst
        let out = x.map { lim.process($0, 0).0 }
        XCTAssertLessThanOrEqual(out.map(abs).max()!, 0.5 + 1e-5)
        XCTAssertGreaterThan(out.map(abs).max()!, 0.45)   // it limits, it doesn't just mute
    }

    /// Below the ceiling the limiter is a pure delay of `latency` samples.
    func testLimiterIsTransparentBelowThreshold() {
        let lim = LookaheadLimiter(sampleRate: rate)
        let x = sine(60, amp: 0.3, n: 4_000)
        let out = x.map { lim.process($0, 0).0 }
        for i in lim.latency..<x.count {
            XCTAssertEqual(out[i], x[i - lim.latency], accuracy: 1e-6)
        }
    }

    /// Linked stereo: a peak on one side turns both sides down equally.
    func testLimiterLinksChannels() {
        let lim = LookaheadLimiter(sampleRate: rate)
        lim.threshold = 0.5
        var lastA: Float = 0, lastB: Float = 0
        for _ in 0..<1_000 { (lastA, lastB) = lim.process(1.0, 0.2) }
        XCTAssertEqual(lastA, 0.5, accuracy: 1e-3)
        XCTAssertEqual(lastB, 0.1, accuracy: 1e-3)
    }

    func testPeakingEQCutsAtCenterAndLeavesOthersAlone() {
        var eq = Biquad(); eq.setPeaking(freq: 63, q: 4, gainDB: -6, sampleRate: rate)
        func gain(_ f: Double) -> Double {
            var b = eq; var peak: Float = 0
            for i in 0..<Int(rate) {
                let y = b.process(Float(sin(2 * .pi * f * Double(i) / rate)))
                if i > Int(rate) / 2 { peak = max(peak, abs(y)) }
            }
            return 20 * log10(Double(peak))
        }
        XCTAssertEqual(gain(63), -6, accuracy: 0.15)
        XCTAssertEqual(gain(250), 0, accuracy: 0.3)
        var flat = Biquad(); flat.setPeaking(freq: 63, q: 4, gainDB: 0, sampleRate: rate)
        XCTAssertEqual(flat.process(0.7), 0.7, accuracy: 1e-6)
    }

    /// Night mode settings: much lower ceiling at the sub output.
    func testNightModeCeiling() {
        let dsp = CrossoverDSP()
        dsp.sampleRate = rate; dsp.subGain = 3; dsp.limiterThreshold = 0.3
        let n = 9_600
        let loud = sine(60, amp: 1, n: n)
        var sub = [Float](repeating: 0, count: n)
        loud.withUnsafeBufferPointer { inp in
            sub.withUnsafeMutableBufferPointer { out in
                dsp.render(inL: inp.baseAddress!, inR: inp.baseAddress!, frames: n,
                           sub: out.baseAddress!, mainL: nil, mainR: nil)
            }
        }
        XCTAssertLessThanOrEqual(sub.map(abs).max()!, 0.3 + 1e-5)
        XCTAssertLessThan(dsp.limiterGainNow, 0.5)
    }
}

final class OutputProfileTests: XCTestCase {
    func testOldProfilesDecodeWithFlatEQ() throws {
        let old = #"{"aligned":true,"crossover":175,"level":0.8}"#.data(using: .utf8)!
        let p = try JSONDecoder().decode(OutputProfile.self, from: old)
        XCTAssertTrue(p.aligned)
        XCTAssertEqual(p.eq1DB, 0); XCTAssertEqual(p.eq2DB, 0); XCTAssertTrue(p.eqEnabled)
    }

    func testDefaultModeBySpeakerType() {
        func device(_ transport: UInt32, channels: Int) -> AudioDeviceInfo {
            AudioDeviceInfo(id: 1, uid: "x", name: "x", modelUID: "", transport: transport, outputChannels: channels)
        }
        XCTAssertTrue(OutputProfile.suggestsAlignedMode(for: device(kAudioDeviceTransportTypeBuiltIn, channels: 2)))
        XCTAssertFalse(OutputProfile.suggestsAlignedMode(for: device(kAudioDeviceTransportTypeUSB, channels: 8)))
        XCTAssertFalse(OutputProfile.suggestsAlignedMode(for: device(kAudioDeviceTransportTypeDisplayPort, channels: 2)))
    }
}

final class BandAnalyzerTests: XCTestCase {
    func testSineLandsInItsBand() {
        let rate = 48_000.0
        let x = (0..<48_000).map { Float(0.5 * sin(2 * .pi * 100 * Double($0) / rate)) }
        let bands = BandAnalyzer.thirdOctaveLevels(x, sampleRate: rate)
        let loudest = bands.max { $0.1 < $1.1 }!
        XCTAssertEqual(loudest.0, 100)
        // Two octaves away should be far down.
        let at400 = bands.first { $0.0 == 400 }!.1
        XCTAssertLessThan(at400, loudest.1 - 30)
    }
}
