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
- **Time-aligned mode** (optional): the tap mutes normal playback and the app plays *both* your
  speakers and the BassJump from one aggregate device (speakers as clock, BassJump
  drift-compensated), so they share a timeline. Optionally high-passes the speakers at the same
  crossover (LR4 low + high sum flat), and an alignment slider delays either side by up to 30 ms.
- **Auto-recovery:** stops before sleep and rebuilds after wake; restarts if a device is
  unplugged or changes sample rate; a watchdog rebuilds the engine if audio stops flowing.
- Bass gain follows the system volume and mute of your current output (the tap is pre-volume).
- Pauses automatically for headphones, Bluetooth and AirPlay; works with built-in, Studio
  Display and other wired speakers.
- **Per-output settings:** crossover, level and mode are remembered separately for each output
  (e.g. MacBook speakers vs. a Studio Display) and switch automatically with the output.
- **Custom presets:** set crossover/level, press **+** next to the preset menu and name it.
- **Shortcut ⌃⌥⌘B** turns BassJump on/off from anywhere (no Accessibility permission needed).
- **Permission check:** if other apps are playing but the tap hears only silence for ~10 s,
  the menu shows a warning with a button to the Privacy settings.
- Presets from 3.0.1: Default 150 Hz / 60 %, Pop 200/75, Rock 175/80, R&B 150/100, Classical 175/50.

## App icon
`Resources/AppIcon.icon` is an Icon Composer file (Liquid Glass). Edit it in Icon Composer, save,
and rebuild; `build.sh` compiles it with `actool` into `Assets.car` plus an `.icns` fallback.

## Build & install
Requires Xcode (or Command Line Tools) and macOS 14.2+.

```
./build.sh             # → build/BassJump.app
./build.sh --install   # also copies to /Applications and relaunches
```
`build.sh` signs with your first valid "Apple Development" certificate (override with
`SIGN_IDENTITY=…`), falling back to ad-hoc. A stable signature keeps the audio-recording
permission across rebuilds; ad-hoc builds ask again each time.
On first run macOS asks for permission to record system audio — allow it
(System Settings → Privacy & Security → Screen & System Audio Recording → "System Audio Recording Only").
Because the app is ad-hoc signed, rebuilding may re-trigger that prompt.

## Tests
```
swift test
```
Checks the crossover math: LR4 −6 dB at the crossover, flat passband, 24 dB/oct roll-off,
low + high summing flat, exact delay-line timing, and the limiter never exceeding full scale.

## Troubleshooting
```
defaults write local.bassjump.revived debugLogging -bool YES   # then relaunch
log stream --predicate 'subsystem == "local.bassjump.revived"'
```
Engine start/stop/restarts are always logged. With `debugLogging` on, it also logs `tap in`
(system audio level), `sub out` and `gain` every 5 s.
- `tap in` stays 0 while music plays → audio-recording permission is off.
- `gain 0` → your output is muted or at zero volume.

See [docs/TEARDOWN.md](docs/TEARDOWN.md) for how the original software worked.

## Known limitations / ideas
- In sub-only mode the sub plays slightly later (~10–20 ms) than the speakers; use
  time-aligned mode if that bothers you.
- **Time-aligned mode on Apple Studio Displays plays ~10 dB quieter.** Measured with the
  display's mic (`tools/measure`): writing directly to the display's 8-channel stream is a
  flat 9.6 dB quieter than normal macOS stereo playback at every volume, with identical tone.
  Spreading stereo across all channels (`defaults write local.bassjump.revived fillAllChannels
  -bool YES`) matches loudness but colours the sound by ±7 dB, so it's off by default. Use
  sub-only mode with the Studio Display; time-aligned mode is meant for MacBook speakers.
- No graphic EQ (3.0.1 had a 10-band one). In sub-only mode the speakers bypass the app, so
  an EQ could only shape the sub.
- The raw "BassJump Core" device still appears in Sound settings (3.0.1 hid it with a kext).
