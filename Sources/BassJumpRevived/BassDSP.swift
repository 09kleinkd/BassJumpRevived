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

/// The subwoofer signal chain. Parameters are written from the main thread and read on the
/// real-time audio thread; plain aligned Float/Bool stores are atomic on arm64, and the
/// render code never allocates or locks.
///
/// Chain: stereo → mono sum → 2nd-order high-pass (driver protection, like 3.0.1's band-pass)
///        → 4th-order Linkwitz-Riley low-pass at the crossover → smoothed gain → soft limiter.
final class BassDSP {
    // Parameters (main thread writes)
    var crossoverHz: Double = 150
    var subsonicHz: Double = 40
    var targetGain: Float = 0.6
    var sampleRate: Double = 48_000

    // Meter (audio thread writes, UI reads)
    private(set) var peak: Float = 0
    /// Peak of the tapped system audio before filtering/gain (diagnostics).
    private(set) var inputPeak: Float = 0

    // Render state
    private var lp1 = Biquad(), lp2 = Biquad(), hp = Biquad()
    private var appliedCrossover: Double = -1
    private var appliedSubsonic: Double = -1
    private var appliedRate: Double = -1
    private var gain: Float = 0

    func reset() {
        lp1.reset(); lp2.reset(); hp.reset(); gain = 0; peak = 0; inputPeak = 0
    }

    @inline(__always)
    private func updateCoefficientsIfNeeded() {
        if crossoverHz != appliedCrossover || sampleRate != appliedRate {
            let f = min(max(crossoverHz, 40), sampleRate * 0.45)
            lp1.setLowPass(freq: f, q: 0.70710678, sampleRate: sampleRate)
            lp2.setLowPass(freq: f, q: 0.70710678, sampleRate: sampleRate)
            appliedCrossover = crossoverHz
        }
        if subsonicHz != appliedSubsonic || sampleRate != appliedRate {
            hp.setHighPass(freq: max(subsonicHz, 10), q: 0.70710678, sampleRate: sampleRate)
            appliedSubsonic = subsonicHz
        }
        appliedRate = sampleRate
    }

    /// Process one block. `monoIn` holds the mono sum; result is written back in place.
    func render(_ buffer: UnsafeMutablePointer<Float>, frames: Int) {
        updateCoefficientsIfNeeded()
        let target = targetGain
        let smoothing: Float = 0.0015 // ~10 ms glide at 48 kHz
        var blockPeak: Float = 0
        var blockIn: Float = 0
        for i in 0..<frames {
            let raw = buffer[i]
            if abs(raw) > blockIn { blockIn = abs(raw) }
            var x = hp.process(raw)
            x = lp2.process(lp1.process(x))
            gain += (target - gain) * smoothing
            x *= gain
            x = tanhf(x)                // gentle limiter: transparent below ~0.5, never exceeds 1
            buffer[i] = x
            let a = abs(x)
            if a > blockPeak { blockPeak = a }
        }
        peak = max(blockPeak, peak * 0.9)
        inputPeak = max(blockIn, inputPeak * 0.9)
    }
}
