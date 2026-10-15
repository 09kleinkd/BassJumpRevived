# Twelve South BassJump software — teardown notes

Research behind BassJump Revived: how the original software worked, and why it no longer runs.
Twelve South's installers and binaries are not included in this repo.

## Hardware
- USB Audio Class device on a C-Media chip: **VID 0x0D8C, PID 0x013A**, named "BassJump Core".
- 2 output channels, 48 kHz. Works with the macOS class driver; no vendor USB commands in any
  version of the software. Confirmed on an M5 MacBook Pro running macOS 27.2.

## Version 3.0.1 (2015, macOS 10.9+, last release)
Flat .pkg with five components, all **x86_64-only**, Developer ID signed (not notarized).

| Component | Install path | What it is |
|---|---|---|
| BassJump.app | /Applications | Menu bar/settings UI (Obj-C). Crossover, volume, presets, 10-band graphic EQ |
| BassJumpDriver.driver | /Library/Audio/Plug-Ins/HAL | AudioServerPlugIn virtual device built from Apple's SimpleAudio sample; contains the crossover DSP |
| com.twelvesouth.bassjump.player | LaunchDaemon | Plays the processed audio to the real hardware |
| com.twelvesouth.bassjump.observer | LaunchAgent | Watches for device plug/unplug |
| BassJumpOverrideDriver.kext | /Library/Extensions | Codeless kext that sets `IOAudioEngineIsHidden` on the VID/PID, hiding the raw device from Sound settings. Cosmetic only |

DSP: AUConverter + AUBandpass; the app adds AUGraphicEQ (10 bands).

Presets: Default 150 Hz / 0.6 · Pop 200 / 0.75 · Rock 175 / 0.8 · R&B 150 / 1.0 · Classical 175 / 0.5

## Version 2.0.3 (2012, macOS 10.7–10.8)
Legacy bundle-style .mpkg. Legacy AudioHardwarePlugIn (Apple SampleHardwarePlugIn code),
x86_64 + i386; System Preferences pane; 32-bit menu extra.
DSP per output: AUConverter → AUVarispeed → AULowpass → AUDynamicsProcessor → AUHAL, with delay
alignment. Default preset 175 Hz / 1.0. Cannot load on any modern macOS.

## Why it stopped working
- Every binary is Intel-only; 2.x also uses a removed driver model and 32-bit code.
- 3.0.1 might partly run under Rosetta on Apple Silicon, but its kext needs Reduced Security and
  Rosetta is being wound down after macOS 27.

## Community workaround
MacRumors thread "BassJump-Subwoofer: Workaround for OCLP Ventura…" (2023–2025): Audio MIDI Setup
Multi-Output Device (built-in speakers + BassJump) with the BassJump at ~30–40 % volume, plus
MultiSoundChanger or Loopback for volume keys. No crossover filtering.

## How BassJump Revived replaces it
| 3.0.1 | Revived |
|---|---|
| Virtual audio driver (HAL plug-in) | Core Audio process tap (macOS 14.2+) — no driver |
| Player daemon | Private aggregate device (BassJump + tap, drift-compensated) with an IOProc |
| AUBandpass crossover | 40 Hz high-pass + 4th-order Linkwitz-Riley low-pass + soft limiter |
| Kext to hide the device | Not needed |
| Presets | Same values |
