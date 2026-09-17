# audio-booster

[![test](https://github.com/carlostapiacl/subele/actions/workflows/test.yml/badge.svg)](https://github.com/carlostapiacl/subele/actions/workflows/test.yml)
[![license](https://img.shields.io/badge/license-MIT-222)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-14.2%2B-222)](#requirements)
[![no dependencies](https://img.shields.io/badge/dependencies-0-222)](Package.swift)

[Español](README.md) · **English**

**Turn macOS past 100% without installing a driver, and without it sounding like a
blown speaker.**

A menu bar app. Move the slider, the system gets louder. What is unusual is
underneath: no kernel extension, no audio driver, and your default output device
is never taken over.

---

## Why this exists

Every volume booster on macOS has worked the same way for a decade. Boom 3D,
eqMac and the rest install an `AudioServerPlugIn` into
`/Library/Audio/Plug-Ins/HAL`, make themselves the system's default output
device, and pass audio through to the real hardware. That means a driver to sign,
an installer, `sudo`, your output device quietly hijacked, and something that
breaks every time Apple ships an OS update.

**macOS 14.2 made all of that unnecessary.** `AudioHardwareCreateProcessTap` is a
public API that captures what other processes are playing — no driver involved.
This project is built on it.

|  | driver-based boosters | audio-booster |
| --- | --- | --- |
| Installs a driver | yes, with `sudo` | no |
| Takes over default output | yes | **no** |
| Turning it up | raw gain, then clipping | lookahead limiter, no clipping |
| Per-app control | no | possible (the tap takes a process list) |
| Uninstall | driver removal | delete the app |

The second row is the one people feel. Multiplying a signal by three means
everything above a third of full scale gets its tops shorn off, and sheared
waveforms are that thin, tinny "boosted" sound. A limiter that sees the peak
before it arrives does not have to shear anything.

## How it works

```
system processes ──┐
                   ├──→ [ process tap ] ──→ IOProc ──→ gain
                   │      muted when                     ↓
                   │       tapped              compressor + makeup   (loudness mode)
                   │                                     ↓
                   │                      brickwall limiter, 3 ms lookahead
                   │                                     ↓
this process ──────┴──── excluded from the tap ────→ output device
```

1. A **process tap** captures everything heading for the default output device,
   with our own process excluded — otherwise what we write would be captured and
   fed straight back in. `muteBehavior = .mutedWhenTapped` silences the original
   path, so the audio is heard once, through us.
2. A **private aggregate device** pairs the tap (input) with the real hardware
   (output), so one IOProc callback holds both ends.
3. The callback processes and writes back.

The system's default output device never changes. The volume menu still says
"MacBook Pro Speakers", because it still *is* the MacBook Pro speakers.

## The limiter

This is the part worth reading the source for.

1. The signal is delayed by 3 ms.
2. For every incoming frame, the gain that frame would need in order to stay
   under the ceiling is computed.
3. A **monotonic queue** keeps the running minimum of those gains across the
   whole lookahead window, amortised O(1) per sample.
4. The frame leaving the delay line is multiplied by the lowest gain any frame
   between it and the present will require.

Step 3 is the one that is easy to get wrong, and this project got it wrong first.
Smoothing the gain with an attack and a release instead of taking the window
minimum lets the release creep the gain back up during those 3 ms. The limiter
then overshoots by about 0.3 dB — enough to hit full scale and clip, quietly, on
exactly the loud transients you were trying to protect. With the window minimum,
overshoot is impossible by construction rather than by tuning constants until it
looks fine.

There is a test for it: a signal that jumps from silence to full scale at 400%
gain lands on the ceiling, not through it.

## Modes

- **Transparent** — gain and limiting only. Dynamics untouched; what was loud
  relative to what was quiet still is. For music.
- **Loudness** — adds compression with automatic makeup gain, lifting quiet parts
  instead of flattening loud ones. For speech, calls, and video with weak audio.

Makeup gain is not a refinement, it is the whole point of putting a compressor
there. A compressor without makeup makes audio *quieter*. The first version of
this DSP shipped that mistake and measured quieter at 300% gain than at 100%.
There is a test pinning that down too.

## Latency

The chain costs about **two buffer periods plus the 3 ms lookahead**. That ratio
held across every buffer size measured, so buffer size is the one lever that
actually moves it. Measured on the IOProc's own timestamps, not estimated:

| buffer | added latency |
| --- | --- |
| 128 frames | 8.8 ms |
| **256 frames (default)** | **14.6 ms** |
| 512 frames (what CoreAudio picks) | 26.2 ms |

Music will not care at any of these. Video might: 26 ms is around where lip sync
starts being noticeable, which is why the default is 256 rather than whatever
CoreAudio hands you. The setting lives under **Latency** in the menu.

## Language

The interface ships in English and Spanish, with a picker in the menu
(**Language**). It follows the system language by default. The console uses the
same setting.

## Requirements

macOS 14.2 or later, Intel or Apple Silicon (the `.dmg` ships a universal
binary), and the Swift toolchain to build it. Xcode Command Line Tools are enough —
this project is built without Xcode.

## Install

### Download

Grab the `.dmg` from the [latest release](https://github.com/carlostapiacl/subele/releases/latest),
open it and drag **Audio Booster** to Applications.

**macOS will block it the first time.** The app is ad-hoc signed but **not
notarised** — notarisation requires a paid Apple Developer account (USD 99/year).
You will see *"Apple could not verify this app is free of malware"*. To get past
it, either:

- **System Settings → Privacy & Security**, scroll to the notice about Audio
  Booster and click **Open Anyway**.
- Or in Terminal:
  ```bash
  xattr -d com.apple.quarantine "/Applications/Audio Booster.app"
  ```

On macOS 15 the old Control-click → Open trick is no longer enough; you have to go
through System Settings.

### Build it yourself

If you would rather not trust an un-notarised binary — fair — it takes seconds:

```bash
git clone https://github.com/carlostapiacl/subele
cd audio-booster
./build-app.sh
open "Audio Booster.app"
```

`build-app.sh` builds release, runs the tests, generates the icon, assembles the
`.app` by hand (SwiftPM does not produce bundles) and signs it ad-hoc. Ad-hoc
signing is enough to run it on the machine that built it; distributing it would
need a Developer ID certificate and notarisation.

`Tools/make-dmg.sh` builds the downloadable `.dmg`, and the `release.yml`
workflow publishes it on its own when a `v*` tag is pushed.

The icon is generated by code in `Tools/make-icon.swift`, so it reviews in a diff
like any other file instead of being an opaque binary. It draws a dial turned past
its maximum — white up to the limit, amber continuing beyond it — with a speaker at
the centre. The amber is the same colour the meter uses while the limiter is
working. The menu bar icon repeats the idea in monochrome, and **its arc grows with
the gain**: it says how much is being boosted without having to read the
percentage.

## Usage

A speaker icon appears in the menu bar. Opening it gives you the output device and
format, a level meter that turns orange while the limiter is working, a 50–400%
slider, the mode switch, a latency setting and a language picker.

Gain, mode, latency and language persist between launches.

One binary, two faces — the `.app` bundle just wraps it:

```bash
booster              # menu bar app
booster --cli        # interactive console
booster --cli --buffer 128
booster --help
```

`BOOSTER_TRACE=1` traces every startup step to stderr. CoreAudio calls can block
indefinitely without returning an error, and when stdout is buffered such a hang
leaves no trace at all.

## Tests

```bash
swift test
```

The DSP tests are pure signal processing — no audio device, no tap, no
permissions — so they run on CI exactly as they do on a laptop. That is
deliberate: measuring through the speakers is useless, because anything else
playing on the machine mixes into the tap and contaminates the meter. Two rounds
of measurements were lost to background music before the tests moved off the
hardware.

What they pin down: exact gain while there is headroom, the limiter reaching the
ceiling but never passing it, transients from silence to full scale, bit-identical
output across block sizes from 32 to 1024, every channel count from mono to 7.1,
and NaN or infinity arriving in the input without killing the chain.

## Known limitations

- **Another driver-based booster will deadlock it.** If eqMac or Boom 3D is
  running it owns the default output device, so we tap *its* virtual device,
  which is itself passing audio through. `AudioDeviceCreateIOProcIDWithBlock`
  then blocks forever with no error. Quit it first.
- **Parameters are written without synchronisation.** `gain` and `mode` are
  written by the UI thread and read by the audio thread. On x86-64 and arm64 an
  aligned 4-byte load or store is atomic in hardware, so nothing goes wrong in
  practice, but it is formally a data race. Fixing it properly needs atomics.
- **Loudness mode raises the noise floor**, since makeup applies when there is no
  signal too. Inherent to the mode, not a defect.
- **It does not start at login.** Deliberate: no login item is installed without
  being asked for.

## Layout

```
Sources/BoosterKit/          the reusable part, no AppKit
  CoreAudio/
    AudioObject.swift        typed wrapper over the property API, errors, tracing
    AudioDevices.swift       device queries and default-output observation
    ProcessTap.swift         tap lifetime
    AggregateDevice.swift    aggregate device lifetime, buffer size
  DSP/
    Decibels.swift           dB conversions and smoothing coefficients
    Compressor.swift         soft-knee curve and automatic makeup
    Limiter.swift            delay line and sliding-window minimum
    BoostProcessor.swift     the chain
  Engine/
    BoostEngine.swift        tap + aggregate + IOProc + latency measurement
Sources/booster/             the executable
  main.swift                 picks a mode from the arguments
  MenuBarApp.swift           AppKit front end
  LevelMeterView.swift
  ConsoleMode.swift
  Strings.swift              every visible string, typed, in two languages
Tools/make-icon.swift        generates AppIcon.icns
Tests/BoosterKitTests/
```

`BoosterKit` has no AppKit dependency and no knowledge of the UI, so the engine
can be embedded in something else.

> Source comments are in Spanish — this is a Spanish-language project with a
> bilingual interface. The public API names and this document are in English.

## Site

[carlostapiacl.github.io/audio-booster](https://carlostapiacl.github.io/audio-booster/) — the project page, in `docs/`.

## License

MIT © Carlos Tapia
