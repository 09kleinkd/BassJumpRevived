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

    /// Peaking (bell) EQ: boosts or cuts `gainDB` around `freq`; 0 dB is a pass-through.
    mutating func setPeaking(freq: Double, q: Double, gainDB: Double, sampleRate: Double) {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * freq / sampleRate
        let c = cos(w0), alpha = sin(w0) / (2 * q), a0 = 1 + alpha / a
        b0 = Float((1 + alpha * a) / a0); b1 = Float(-2 * c / a0); b2 = Float((1 - alpha * a) / a0)
        a1 = Float(-2 * c / a0); a2 = Float((1 - alpha / a) / a0)
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() { z1 = 0; z2 = 0 }

    /// These coefficients with another filter's running state (so updates don't click).
    func withState(of other: Biquad) -> Biquad {
        var b = self; b.z1 = other.z1; b.z2 = other.z2; return b
    }
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

/// Look-ahead peak limiter (linked stereo). The signal is delayed by `latency` samples while
/// the gain needed for the loudest upcoming sample is computed, so the gain is already down
/// when a peak arrives: no overshoot and no clipping, unlike a soft clipper.
///
/// Gain path: required gain per sample → sliding minimum over the look-ahead window → moving
/// average over the same window (a smooth ramp that reaches the minimum exactly when the
/// peak is output) → instant attack / exponential release. Allocation-free.
final class LookaheadLimiter {
    static let maxWindow = 2_048
    var threshold: Float = 0.89          // −1 dBFS
    var releaseMs: Double = 150
    private(set) var latency = 0         // samples; equals window − 1
    /// Smallest gain applied since the last read (1 = not limiting).
    private(set) var minGain: Float = 1

    private var window = 1
    private var releaseCoef: Float = 0.001
    private let delayA = UnsafeMutablePointer<Float>.allocate(capacity: maxWindow)
    private let delayB = UnsafeMutablePointer<Float>.allocate(capacity: maxWindow)
    private let avgBuf = UnsafeMutablePointer<Float>.allocate(capacity: maxWindow)
    private let dqVal = UnsafeMutablePointer<Float>.allocate(capacity: maxWindow + 1)
    private let dqIdx = UnsafeMutablePointer<Int>.allocate(capacity: maxWindow + 1)
    private var dqHead = 0, dqCount = 0
    private var pos = 0, n = 0
    private var sum: Double = 0
    private var gain: Float = 1
    private var configuredRate = 0.0, configuredRelease = -1.0

    init(sampleRate: Double = 48_000, lookaheadMs: Double = 3) {
        configure(sampleRate: sampleRate, lookaheadMs: lookaheadMs)
    }

    deinit {
        delayA.deallocate(); delayB.deallocate(); avgBuf.deallocate(); dqVal.deallocate(); dqIdx.deallocate()
    }

    func configure(sampleRate: Double, lookaheadMs: Double = 3) {
        window = min(max(Int(sampleRate * lookaheadMs / 1000), 2), Self.maxWindow)
        latency = window - 1
        configuredRate = sampleRate
        updateRelease()
        reset()
    }

    /// Re-reads `releaseMs` (cheap; called once per block).
    @inline(__always)
    func updateRelease() {
        guard releaseMs != configuredRelease else { return }
        releaseCoef = Float(1 - exp(-1 / (max(releaseMs, 1) / 1000 * max(configuredRate, 1))))
        configuredRelease = releaseMs
    }

    func reset() {
        delayA.update(repeating: 0, count: window); delayB.update(repeating: 0, count: window)
        avgBuf.update(repeating: 1, count: window)
        sum = Double(window); dqHead = 0; dqCount = 0; pos = 0; n = 0; gain = 1; minGain = 1
    }

    func takeMinGain() -> Float { let g = minGain; minGain = 1; return g }

    @inline(__always)
    func process(_ a: Float, _ b: Float) -> (Float, Float) {
        let peak = max(abs(a), abs(b))
        let required = peak > threshold ? threshold / peak : 1
        let cap = Self.maxWindow + 1

        // Sliding minimum of `required` over the last `window` samples (monotonic deque).
        while dqCount > 0 && dqVal[(dqHead + dqCount - 1) % cap] >= required { dqCount -= 1 }
        let tail = (dqHead + dqCount) % cap
        dqVal[tail] = required; dqIdx[tail] = n; dqCount += 1
        while dqIdx[dqHead] <= n - window { dqHead = (dqHead + 1) % cap; dqCount -= 1 }
        let held = dqVal[dqHead]

        // Moving average → smooth attack ramp that lands on `held` in time.
        sum += Double(held - avgBuf[pos]); avgBuf[pos] = held
        let target = min(Float(sum / Double(window)), 1)
        if target < gain { gain = target } else { gain += (target - gain) * releaseCoef }
        minGain = min(minGain, gain)

        // Delay the audio by window − 1 samples.
        delayA[pos] = a; delayB[pos] = b
        pos += 1; if pos == window { pos = 0 }
        n &+= 1
        return (delayA[pos] * gain, delayB[pos] * gain)
    }
}

/// The crossover. Parameters are written from the main thread and read on the real-time
/// audio thread (aligned Float/Double/Bool stores are atomic on arm64); render never
/// allocates or locks.
///
/// Sub path:  L+R → mono → 2nd-order high-pass (driver protection) → LR4 low-pass
///            → up to two peaking EQ bands → smoothed gain → look-ahead limiter → optional delay.
/// Main path: L, R → optional LR4 high-pass at the crossover → optional delay.
/// (The main path is only used in time-aligned mode.)
final class CrossoverDSP {
    // Parameters (main thread writes)
    var crossoverHz: Double = 150
    var subsonicHz: Double = 40
    var subGain: Float = 0.6
    var highPassMain = false
    /// Positive delays the main speakers, negative delays the sub (milliseconds).
    var alignmentMs: Double = 0
    /// Flip the sub's polarity (can tighten bass depending on placement).
    var invertSub = false
    /// Sub EQ: two peaking bands (0 dB = off).
    var eq1Hz: Double = 60, eq1DB: Double = 0, eq1Q: Double = 4
    var eq2Hz: Double = 100, eq2DB: Double = 0, eq2Q: Double = 4
    /// Limiter ceiling and release (night mode lowers the ceiling and slows the release).
    var limiterThreshold: Float = 0.89
    var limiterReleaseMs: Double = 150
    var sampleRate: Double = 48_000

    // Diagnostics (audio thread writes)
    private(set) var peak: Float = 0
    private(set) var inputPeak: Float = 0
    private(set) var renderCount: UInt64 = 0
    /// Lowest limiter gain in the last block (1 = not limiting).
    private(set) var limiterGainNow: Float = 1

    // Render state
    private var subHP = Biquad(), subLP = LR4(), mainHPL = LR4(), mainHPR = LR4()
    private var subHP2 = Biquad(), subLP2 = LR4()          // right channel when driving two subs
    private let delaySub2 = DelayLine(capacity: 16_384)
    private var gain2: Float = 0
    private let delayL = DelayLine(capacity: 16_384)
    private let delayR = DelayLine(capacity: 16_384)
    private let delaySub = DelayLine(capacity: 16_384)
    private var appliedCrossover = -1.0, appliedSubsonic = -1.0, appliedRate = -1.0
    private var gain: Float = 0
    private var eq1 = Biquad(), eq2 = Biquad(), eq1R = Biquad(), eq2R = Biquad()
    private var appliedEQ: [Double] = []
    private let limiter = LookaheadLimiter()

    func reset() {
        subHP.reset(); subLP.reset(); mainHPL.reset(); mainHPR.reset(); subHP2.reset(); subLP2.reset()
        eq1.reset(); eq2.reset(); eq1R.reset(); eq2R.reset(); limiter.reset()
        delayL.reset(); delayR.reset(); delaySub.reset(); delaySub2.reset()
        gain = 0; gain2 = 0; peak = 0; inputPeak = 0
    }

    @inline(__always)
    private func updateCoefficientsIfNeeded() {
        let rate = sampleRate
        if crossoverHz != appliedCrossover || rate != appliedRate {
            let f = min(max(crossoverHz, 40), rate * 0.45)
            subLP.setLowPass(f, rate)
            subLP2.setLowPass(f, rate)
            mainHPL.setHighPass(f, rate)
            mainHPR.setHighPass(f, rate)
            appliedCrossover = crossoverHz
        }
        if subsonicHz != appliedSubsonic || rate != appliedRate {
            subHP.setHighPass(freq: max(subsonicHz, 10), q: 0.70710678, sampleRate: rate)
            subHP2.setHighPass(freq: max(subsonicHz, 10), q: 0.70710678, sampleRate: rate)
            appliedSubsonic = subsonicHz
        }
        if rate != appliedRate { limiter.configure(sampleRate: rate) }
        let eq = [eq1Hz, eq1DB, eq1Q, eq2Hz, eq2DB, eq2Q]
        if eq != appliedEQ || rate != appliedRate {
            let nyq = rate * 0.45
            eq1.setPeaking(freq: min(max(eq1Hz, 20), nyq), q: max(eq1Q, 0.3), gainDB: eq1DB, sampleRate: rate)
            eq2.setPeaking(freq: min(max(eq2Hz, 20), nyq), q: max(eq2Q, 0.3), gainDB: eq2DB, sampleRate: rate)
            eq1R = eq1.withState(of: eq1R); eq2R = eq2.withState(of: eq2R)
            appliedEQ = eq
        }
        limiter.threshold = min(max(limiterThreshold, 0.05), 1)
        limiter.releaseMs = limiterReleaseMs
        limiter.updateRelease()
        appliedRate = rate
    }

    /// `inL`/`inR`: tapped system audio. `sub` receives the bass (mono, or the left bass when
    /// `subR` is given for a stereo pair of subs). `mainL`/`mainR` (aligned mode only) receive
    /// the speaker signal; pass nil in sub-only mode.
    func render(inL: UnsafePointer<Float>, inR: UnsafePointer<Float>, frames: Int,
                sub: UnsafeMutablePointer<Float>,
                mainL: UnsafeMutablePointer<Float>?, mainR: UnsafeMutablePointer<Float>?,
                subR: UnsafeMutablePointer<Float>? = nil) {
        updateCoefficientsIfNeeded()
        renderCount &+= 1

        let target = subGain
        let smoothing: Float = 0.0015            // ~10 ms glide at 48 kHz
        let hpMain = highPassMain
        let maxDelay = delaySub.capacity - 1
        let delayFrames = min(Int(abs(alignmentMs) * sampleRate / 1000), maxDelay)
        // The limiter delays the sub by its look-ahead; delay the speakers to match.
        let mainDelay = min((alignmentMs > 0 ? delayFrames : 0) + limiter.latency, maxDelay)
        let subDelay = alignmentMs < 0 ? delayFrames : 0
        let useEQ1 = eq1DB != 0, useEQ2 = eq2DB != 0

        let polarity: Float = invertSub ? -1 : 1
        var blockPeak: Float = 0, blockIn: Float = 0
        for i in 0..<frames {
            let l = inL[i], r = inR[i]
            blockIn = max(blockIn, abs(l), abs(r))
            gain += (target - gain) * smoothing

            // Sub (mono, or left when driving a stereo pair)
            var x = subLP.process(subHP.process(subR == nil ? (l + r) * 0.5 : l))
            if useEQ1 { x = eq1.process(x) }
            if useEQ2 { x = eq2.process(x) }
            var y: Float = 0
            if subR != nil {
                y = subLP2.process(subHP2.process(r))
                if useEQ1 { y = eq1R.process(y) }
                if useEQ2 { y = eq2R.process(y) }
            }
            var (lx, ly) = limiter.process(x * gain * polarity, y * gain * polarity)
            lx = min(max(lx, -1), 1); ly = min(max(ly, -1), 1)     // final safety net
            lx = delaySub.process(lx, delay: subDelay)
            sub[i] = lx
            blockPeak = max(blockPeak, abs(lx))

            if let subR {
                ly = delaySub2.process(ly, delay: subDelay)
                subR[i] = ly
                blockPeak = max(blockPeak, abs(ly))
            }

            // Main speakers
            if let mainL, let mainR {
                let ml = hpMain ? mainHPL.process(l) : l
                let mr = hpMain ? mainHPR.process(r) : r
                mainL[i] = delayL.process(ml, delay: mainDelay)
                mainR[i] = delayR.process(mr, delay: mainDelay)
            }
        }
        limiterGainNow = limiter.takeMinGain()
        peak = max(blockPeak, peak * 0.9)
        inputPeak = max(blockIn, inputPeak * 0.9)
    }
}
