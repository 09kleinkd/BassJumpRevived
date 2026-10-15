import XCTest
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
