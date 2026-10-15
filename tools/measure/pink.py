"""Writes a stereo pink-noise test file (uncorrelated L/R, 48 kHz, 16-bit, -18 dBFS RMS)."""
import sys, wave, numpy as np
sr, secs = 48_000, float(sys.argv[2]) if len(sys.argv) > 2 else 4.0
n = int(sr * secs)
rng = np.random.default_rng(1)
chans = []
for _ in range(2):
    spec = np.fft.rfft(rng.standard_normal(n))
    f = np.fft.rfftfreq(n, 1 / sr); f[0] = f[1]
    x = np.fft.irfft(spec / np.sqrt(f), n)
    x *= 10 ** (-18 / 20) / np.sqrt(np.mean(x ** 2))
    fade = int(0.05 * sr); ramp = np.linspace(0, 1, fade)
    x[:fade] *= ramp; x[-fade:] *= ramp[::-1]
    chans.append(x)
pcm = (np.clip(np.stack(chans, 1), -1, 1) * 32767).astype('<i2')
with wave.open(sys.argv[1], 'wb') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr); w.writeframes(pcm.tobytes())
