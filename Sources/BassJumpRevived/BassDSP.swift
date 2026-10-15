import Foundation

/// Second-order IIR section (RBJ cookbook), transposed direct form II.
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0

    mutating func setLowPass(freq: Double, q: Double, sampleRate: Double) {
        let w0 = 2 * Double.pi * freq / sampleRate
        let c = cos(w0), alpha = sin(w0) / (2 * q), a0 = 1 + alpha
        b0 = Float((1 - c) / 2 / a0); b1 = Float((1 - c) / a0); b2 = b0
        a1 = Float(-2 * c / a0); a2 = Float((1 - alpha) / a0)
    }

    mutating func setHighPass(freq: Double, q: Double, sampleRate: Double) {
        let w0 = 2 * Double.pi * freq / sampleRate
        let c = cos(w0), alpha = sin(w0) / (2 * q), a0 = 1 + alpha
        b0 = Float((1 + c) / 2 / a0); b1 = Float(-(1 + c) / a0); b2 = b0
        a1 = Float(-2 * c / a0); a2 = Float((1 - alpha) / a0)
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() { z1 = 0; z2 = 0 }
}

/// 4th-order Linkwitz-Riley filter (two cascaded Butterworth sections). LR4 low-pass and
/// high-pass at the same frequency sum flat, so the speakers and sub blend seamlessly.
struct LR4 {
    private var s1 = Biquad(), s2 = Biquad()
    private static let q = 0.70710678

    mutating func setLowPass(_ freq: Double, _ sampleRate: Double) {
        s1.setLowPass(freq: freq, q: Self.q, sampleRate: sampleRate)
        s2.setLowPass(freq: freq, q: Self.q, sampleRate: sampleRate)
    }

    mutating func setHighPass(_ freq: Double, _ sampleRate: Double) {
        s1.setHighPass(freq: freq, q: Self.q, sampleRate: sampleRate)
        s2.setHighPass(freq: freq, q: Self.q, sampleRate: sampleRate)
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float { s2.process(s1.process(x)) }

    mutating func reset() { s1.reset(); s2.reset() }
}

/// Fixed-capacity delay line; never allocates on the audio thread.
final class DelayLine {
    let capacity: Int
    private let buffer: UnsafeMutablePointer<Float>
    private var write = 0

    init(capacity: Int) {
        self.capacity = capacity
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit { buffer.deallocate() }

    @inline(__always)
    func process(_ x: Float, delay: Int) -> Float {
        buffer[write] = x
        var read = write - delay
        if read < 0 { read += capacity }
        let y = buffer[read]
        write += 1
        if write == capacity { write = 0 }
        return y
    }

    func reset() { buffer.update(repeating: 0, count: capacity); write = 0 }
}

/// The crossover. Parameters are written from the main thread and read on the real-time
/// audio thread (aligned Float/Double/Bool stores are atomic on arm64); render never
/// allocates or locks.
///
/// Sub path:  L+R → mono → 2nd-order high-pass (driver protection) → LR4 low-pass
///            → smoothed gain → soft limiter → optional delay.
/// Main path: L, R → optional LR4 high-pass at the crossover → optional delay.
/// (The main path is only used in time-aligned mode.)
final class CrossoverDSP {
    // Parameters (main thread writes)
    var crossoverHz: Double = 150
    var subsonicHz: Double = 40
    var subGain: Float = 0.6
    var highPassMain = true
    /// Positive delays the main speakers, negative delays the sub (milliseconds).
    var alignmentMs: Double = 0
    var sampleRate: Double = 48_000

    // Diagnostics (audio thread writes)
    private(set) var peak: Float = 0
    private(set) var inputPeak: Float = 0
    private(set) var renderCount: UInt64 = 0

    // Render state
    private var subHP = Biquad(), subLP = LR4(), mainHPL = LR4(), mainHPR = LR4()
    private let delayL = DelayLine(capacity: 16_384)
    private let delayR = DelayLine(capacity: 16_384)
    private let delaySub = DelayLine(capacity: 16_384)
    private var appliedCrossover = -1.0, appliedSubsonic = -1.0, appliedRate = -1.0
    private var gain: Float = 0

    func reset() {
        subHP.reset(); subLP.reset(); mainHPL.reset(); mainHPR.reset()
        delayL.reset(); delayR.reset(); delaySub.reset()
        gain = 0; peak = 0; inputPeak = 0
    }

    @inline(__always)
    private func updateCoefficientsIfNeeded() {
        let rate = sampleRate
        if crossoverHz != appliedCrossover || rate != appliedRate {
            let f = min(max(crossoverHz, 40), rate * 0.45)
            subLP.setLowPass(f, rate)
            mainHPL.setHighPass(f, rate)
            mainHPR.setHighPass(f, rate)
            appliedCrossover = crossoverHz
        }
        if subsonicHz != appliedSubsonic || rate != appliedRate {
            subHP.setHighPass(freq: max(subsonicHz, 10), q: 0.70710678, sampleRate: rate)
            appliedSubsonic = subsonicHz
        }
        appliedRate = rate
    }

    /// `inL`/`inR`: tapped system audio. `sub` receives the bass. `mainL`/`mainR` (aligned
    /// mode only) receive the speaker signal; pass nil in sub-only mode.
    func render(inL: UnsafePointer<Float>, inR: UnsafePointer<Float>, frames: Int,
                sub: UnsafeMutablePointer<Float>,
                mainL: UnsafeMutablePointer<Float>?, mainR: UnsafeMutablePointer<Float>?) {
        updateCoefficientsIfNeeded()
        renderCount &+= 1

        let target = subGain
        let smoothing: Float = 0.0015            // ~10 ms glide at 48 kHz
        let hpMain = highPassMain
        let maxDelay = delaySub.capacity - 1
        let delayFrames = min(Int(abs(alignmentMs) * sampleRate / 1000), maxDelay)
        let mainDelay = alignmentMs > 0 ? delayFrames : 0
        let subDelay = alignmentMs < 0 ? delayFrames : 0

        var blockPeak: Float = 0, blockIn: Float = 0
        for i in 0..<frames {
            let l = inL[i], r = inR[i]
            blockIn = max(blockIn, abs(l), abs(r))

            // Sub
            var x = subHP.process((l + r) * 0.5)
            x = subLP.process(x)
            gain += (target - gain) * smoothing
            x = tanhf(x * gain)                  // transparent below ~0.5, never exceeds 1
            x = delaySub.process(x, delay: subDelay)
            sub[i] = x
            blockPeak = max(blockPeak, abs(x))

            // Main speakers
            if let mainL, let mainR {
                let ml = hpMain ? mainHPL.process(l) : l
                let mr = hpMain ? mainHPR.process(r) : r
                mainL[i] = delayL.process(ml, delay: mainDelay)
                mainR[i] = delayR.process(mr, delay: mainDelay)
            }
        }
        peak = max(blockPeak, peak * 0.9)
        inputPeak = max(blockIn, inputPeak * 0.9)
    }
}
