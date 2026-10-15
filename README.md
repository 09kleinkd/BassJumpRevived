# BassJump Revived

A native Apple Silicon replacement for Twelve South's BassJump Sound System software
(last release 3.0.1, 2015, Intel-only). No driver, no kernel extension.

## How it works
- The BassJump is a standard USB audio device (C-Media, VID 0x0D8C / PID 0x013A); macOS
  drives it natively as "BassJump Core".
- The app creates a **Core Audio process tap** (macOS 14.2+) on the system mix, leaving your
  normal speakers untouched, and a **private aggregate device** (BassJump + tap, with drift
  compensation) — the same job 3.0.1's virtual driver + player daemon did.
- Each audio block: stereo → mono → 40 Hz high-pass (protects the small driver; 3.0.1 used a
  band-pass) → 4th-order Linkwitz-Riley low-pass at the crossover → gain → soft limiter.
- Bass gain follows the system volume and mute of your current output (the tap is pre-volume).
- Pauses automatically for headphones, Bluetooth and AirPlay; works with built-in, Studio
  Display and other wired speakers.
- Presets from 3.0.1: Default 150 Hz / 60 %, Pop 200/75, Rock 175/80, R&B 150/100, Classical 175/50.

## App icon
`Resources/AppIcon.icon` is an Icon Composer file (Liquid Glass). Edit it in Icon Composer, save,
and rebuild; `build.sh` compiles it with `actool` into `Assets.car` plus an `.icns` fallback.

## Build & install
Requires Xcode (or Command Line Tools) and macOS 14.2+.

```
./build.sh                        # → build/BassJump.app
cp -R build/BassJump.app /Applications/
open /Applications/BassJump.app
```
On first run macOS asks for permission to record system audio — allow it
(System Settings → Privacy & Security → Screen & System Audio Recording → "System Audio Recording Only").
Because the app is ad-hoc signed, rebuilding may re-trigger that prompt.

## Troubleshooting
```
log stream --predicate 'subsystem == "local.bassjump.revived"'
```
Every 5 s while running it logs `tap in` (system audio level), `sub out` and `gain`.
- `tap in` stays 0 while music plays → audio-recording permission is off.
- `gain 0` → your output is muted or at zero volume.

See [docs/TEARDOWN.md](docs/TEARDOWN.md) for how the original software worked.

## Known limitations / ideas
- The sub plays slightly later (~10–20 ms) than the main speakers. Inaudible for most bass;
  a future "aligned" mode could mute the tap and route both outputs through the aggregate.
- No graphic EQ yet (3.0.1 had a 10-band one).
- The raw "BassJump Core" device still appears in Sound settings (3.0.1 hid it with a kext).
