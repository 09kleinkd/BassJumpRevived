"""Compares octave-band levels of mic recordings: analyze.py ref.wav other.wav ...
Uses the loudest 3 s of each file (the noise burst)."""
import sys, wave, numpy as np
BANDS = [63, 125, 250, 500, 1000, 2000, 4000, 8000]

def load(p):
    with wave.open(p) as w:
        x = np.frombuffer(w.readframes(w.getnframes()), '<i2').astype(float) / 32768
        return x.reshape(-1, w.getnchannels()).mean(1), w.getframerate()

def bands(p):
    x, sr = load(p)
    win = int(0.1 * sr); e = np.convolve(x ** 2, np.ones(win), 'valid')
    c = int(np.argmax(np.convolve(e, np.ones(30 * win), 'same')))
    seg = x[max(0, c - int(1.5 * sr)): c + int(1.5 * sr)]
    spec = np.abs(np.fft.rfft(seg * np.hanning(len(seg)))) ** 2
    f = np.fft.rfftfreq(len(seg), 1 / sr)
    out = [10 * np.log10(spec[(f >= b / 1.414) & (f < b * 1.414)].sum() + 1e-20) for b in BANDS]
    total = 10 * np.log10(np.mean(seg ** 2) + 1e-20)
    return total, out

ref_t, ref_b = bands(sys.argv[1])
print(f"{'file':28} {'total':>7} " + ' '.join(f'{b:>6}' for b in BANDS))
for p in sys.argv[1:]:
    t, b = bands(p)
    print(f"{p.split('/')[-1]:28} {t - ref_t:+7.1f} " + ' '.join(f'{v - r:+6.1f}' for v, r in zip(b, ref_b)))
