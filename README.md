# BassJump Revived

A native Apple Silicon replacement for Twelve South's BassJump Sound System software
(last release 3.0.1, 2015, Intel-only). No driver, no kernel extension.

## For other BassJump owners
If your BassJump stopped working after macOS Catalina or on an Apple Silicon Mac, this app
replaces Twelve South's discontinued software. You don't need to install the old software,
its driver or its kernel extension; if they're still installed, run Twelve South's uninstaller
first. Download the latest release, move **BassJump.app** to Applications, open it, and allow
system audio recording when asked.

> BassJump Revived is an independent project. It is not affiliated with, endorsed by, or
> supported by Twelve South. "BassJump" is a trademark of Twelve South LLC.

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
- **Per-app rules:** calls (Zoom, Teams, FaceTime, Webex, Slack, Discord…) are skipped by
  default, and any app can be excluded from the Apps card. Excluded apps are simply left out
  of the tap.
- **Loudness:** adds up to +9 dB of sub as the system volume falls.
- **Flip sub phase** (per output), **two-BassJump stereo** (left/right bass to each).
- **Calibrate:** plays pink noise (via `afplay`, since BassJump excludes its own audio from the
  tap) and listens with the microphone: speakers alone → their bass roll-off sets the crossover;
  sub on, normal vs. flipped → phase; then solves the level that fills the bass up to the
  speakers' midrange.
- **Shortcuts:** Turn BassJump On or Off, Toggle BassJump, Set BassJump Preset, Set BassJump
  Level (App Intents, run in the menu bar app).
- **Control Center** (macOS 26+): add the BassJump control via Control Center → Edit Controls.
  It's a sandboxed widget extension that reads the app's `enabled` preference and asks the app
  to change it via Darwin notifications (`notifyutil -p local.bassjump.revived.control.on|off`).
- Connect/disconnect notifications; menu bar icon follows the bass level.
- **Permission check:** if other apps are playing but the tap hears only silence for ~10 s,
  the menu shows a warning with a button to the Privacy settings.
- Presets from 3.0.1: Default 150 Hz / 60 %, Pop 200/75, Rock 175/80, R&B 150/100, Classical 175/50.

## App icon
`Resources/AppIcon.icon` is an Icon Composer file (Liquid Glass). Edit it in Icon Composer, save,
and rebuild; `build.sh` compiles it with `actool` into `Assets.car` plus an `.icns` fallback.

## Build & install
Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`); runs on macOS 14.2+
(Control Center control needs macOS 26+). `project.yml` defines the Xcode project; `build.sh`
regenerates it, builds with `xcodebuild`, and embeds the Control Center extension.

```
./build.sh             # → build/BassJump.app
./build.sh --install   # also copies to /Applications and relaunches
```
`build.sh` signs with the KSQ Studios "Apple Development" certificate (override with
`SIGN_IDENTITY=…`). A stable signature keeps the audio-recording
permission across rebuilds; ad-hoc builds ask again each time.
On first run macOS asks for permission to record system audio — allow it
(System Settings → Privacy & Security → Screen & System Audio Recording → "System Audio Recording Only").
Because the app is ad-hoc signed, rebuilding may re-trigger that prompt.

## Releasing (notarized build)
`scripts/release.sh` builds with the hardened runtime, signs with the team's
**Developer ID Application** certificate, notarizes with Apple and staples the ticket. The
script's header lists the one-time setup (certificate + `notarytool` keychain profile).

## Tests
```
swift test
```
(The Swift package is kept for tests; the app itself builds from the Xcode project.)
Checks the crossover math: LR4 −6 dB at the crossover, flat passband, 24 dB/oct roll-off,
low + high summing flat, exact delay-line timing, and the limiter never exceeding full scale.

## Testing the menu
`open /Applications/BassJump.app --args --show-panel` opens the popover at launch.

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
