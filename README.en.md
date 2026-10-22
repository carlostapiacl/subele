# Subele

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

It is free and open source. If it helps you, [a donation is appreciated](https://paypal.me/carlostapiacl);
if not, use it anyway. *(It used to be called audio-booster.)*

<p align="center"><img src="docs/screenshot-ecualizador.png" width="640" alt="Subele's menu with the graphical equalizer open"></p>

---

## Why this exists

For a decade, volume boosters on macOS all worked the same way. Boom 3D,
eqMac and the rest install an `AudioServerPlugIn` into
`/Library/Audio/Plug-Ins/HAL`, make themselves the system's default output
device, and pass audio through to the real hardware. That means a driver to sign,
an installer, `sudo`, your output device quietly hijacked, and something that
breaks every time Apple ships an OS update.

**macOS 14.2 made all of that unnecessary.** `AudioHardwareCreateProcessTap` is a
public API that captures what other processes are playing — no driver involved.
This project is built on it, and it is not the only one:
[FineTune](https://github.com/ronitsingh10/FineTune) also uses taps and does far
more (per-app volume, routing, AutoEQ). What sets Subele apart is how it boosts.

|  | driver-based boosters | Subele |
| --- | --- | --- |
| Installs a driver | yes, with `sudo` | no |
| Takes over default output | yes | **no** |
| Uninstall | driver removal | delete the app |

Multiplying a signal by three means everything above a third of full scale goes
over, and something has to be done about it. Clipping or rounding off every
sample that goes over, which is what a *soft clipper* does, bends the waveform, and
that is where the thin, tinny "boosted" sound comes from. A limiter that sees the peak before it arrives turns
the whole gain down and bends nothing. With a 1 kHz sine at 400%, the soft
limiter FineTune publishes gives 23% harmonic distortion going in at −6 dBFS
(`Tools/thd-softclip.py`); Subele gives 0.0004% with the same signal (test
`boostingDoesNotDistort`). It is a test signal, and recording each
app's actual output is still to be done (to be confirmed).

## How it works

```
system processes ──┐
                   ├──→ [ process tap ] ──→ IOProc ──→ gain
                   │      muted when                     ↓
                   │       tapped                    equalizer
                   │                                     ↓
                   │                     compressor + makeup   (Voice mode)
                   │                                     ↓
                   │                    brickwall limiter, 3 ms lookahead
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

Two details the diagram doesn't show:

- **The aggregate also carries the hardware's inputs.** If the output is a USB
  interface or a headset with a microphone, the callback's input is "microphone
  + tap", microphone first. The engine locates which buffers belong to the tap
  (`IORenderer.tapBufferRange`) and reads only those: taking the first one played
  the microphone through the speakers.
- **Everything that can be rejected is rejected before the tap exists.** The
  output format (native float32, up to 32 channels) is validated first; while
  there is no tap the system sounds as usual. If anything fails later, the whole
  chain is torn down and the tap destroyed, which is what gives the audio back.

`start` and `stop` run on their own queue (`EngineController`), never on the UI
one: CoreAudio can block, and the menu has to keep responding to say so. A
watchdog checks that the IOProc keeps turning and rebuilds the chain if it stops:
a tap muting everyone with a stalled IOProc is a silent Mac.

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

**The ceiling is true peak, not just sample peak.** Between two samples under the
ceiling, the waveform the converter reconstructs can exceed it: a sine at a
quarter of the sample rate with a 45° phase has every sample at −3 dBFS and
really reaches 0 dBFS. Step 2 looks at the sample and three interpolated points
up to the next one (×4 oversampling, as in ITU-R BS.1770) and computes the gain
against the largest. It is an estimate made with a 12-tap interpolator, and the
test for that sine requires the output to land within 0.1 dB of
the ceiling.

The slider's gain doesn't jump either: it chases the new value over about 10 ms,
so going from 100% to 400% doesn't click.

## Modes

- **Music** — gain and limiting only. Dynamics untouched; what was loud relative
  to what was quiet still is. **At 100% gain it barely does anything, on purpose**:
  it only touches peaks already above the −0.3 dBFS ceiling, which in
  well-mastered material are few or none. You hear it once you go higher and the
  limiter starts working. The panel says so
  under the switch, because it was the first thing someone asked after trying it.
- **Voice** — adds compression with automatic makeup gain, lifting quiet parts
  instead of flattening loud ones. For speech, calls, and video with weak audio.
  This one is audible at 100%.

(Earlier versions called them *Transparent* and *Loudness*.)

Makeup gain is not a refinement, it is the whole point of putting a compressor
there. A compressor without makeup makes audio *quieter*. The first version of
this DSP shipped that mistake and measured quieter at 300% gain than at 100%.
There is a test pinning that down too.

## Equalizer

Five bands, ±12 dB: a low shelf at 60 Hz, peaks at 250 Hz, 1 kHz and 4 kHz, and a
high shelf at 12 kHz. They are Robert Bristow-Johnson cookbook biquads with
double-precision state, and they sit **before** the compressor and limiter:
boosting bass adds energy, and placed there the limiter sees that peak like any
other instead of letting it clip.

It is driven as a graph: the real response curve — computed from the same
biquads that process the audio, so what you see is what you hear — with one
draggable point per band, double-click to reset it and the scroll wheel for fine
adjustment. Behind it runs a spectrum of what is playing (4096-point FFT with
Accelerate, on the UI thread and only while the equalizer is open). Presets give a
starting point: Flat, More bass, Clear voice, Brighter, Night and Laptop speakers.

With every band at 0 dB the output is bit-identical to the input. There is a test
for that, one checking each band boosts by what it says, and one that pushes
everything to +12 dB at five sample rates to make sure nothing goes unstable.

## Sample rate

The **Sample Rate** menu switches the output between the rates the device accepts
(44.1, 48, 96 kHz…), the same as doing it in Audio MIDI Setup, without having to
know that app exists. The change is system-wide (other apps using that device switch rate too, and
the menu says so), and the chain rebuilds itself
once the device has applied it, including when it is changed from elsewhere.

What it does and does not buy you: going from 44.1 to 96 kHz adds no detail to a
44.1 kHz recording. What can change is that macOS stops resampling and that the
interface sounds different at its preferred rate. Some people hear it clearly, and
it used to live in a hidden app.

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

> Free. If it helps: [donate via PayPal](https://paypal.me/carlostapiacl).

Grab the `.dmg` from the [latest release](https://github.com/carlostapiacl/subele/releases/latest),
open it and drag **Subele** to Applications.

**macOS will block it the first time.** The app is ad-hoc signed but **not
notarised** — notarisation requires a paid Apple Developer account (USD 99/year).
You will see *"Apple could not verify this app is free of malware"*. To get past
it, either:

- **System Settings → Privacy & Security**, scroll to the notice about Subele
  and click **Open Anyway**.
- Or in Terminal:
  ```bash
  xattr -d com.apple.quarantine "/Applications/Subele.app"
  ```

On macOS 15 the old Control-click → Open trick is no longer enough; you have to go
through System Settings.

### Build it yourself

If you would rather not trust an un-notarised binary — fair — it takes seconds:

```bash
git clone https://github.com/carlostapiacl/subele
cd subele
./build-app.sh
open "Subele.app"
```

`build-app.sh` builds release, runs the tests, generates the icon, assembles the
`.app` by hand (SwiftPM does not produce bundles) and signs it ad-hoc. Ad-hoc
signing is enough to run it on the machine that built it; distributing it would
need a Developer ID certificate and notarisation.

`Tools/make-dmg.sh` builds the downloadable `.dmg`, and the `release.yml`
workflow publishes it on its own when a `v*` tag is pushed: it builds on GitHub,
not on a personal machine, and publishes each `.dmg`'s SHA-256 plus a provenance
attestation tying the file to this repository and this workflow. To verify a
download:

```bash
shasum -a 256 -c SHA256SUMS.txt
gh attestation verify subele-*.dmg --repo carlostapiacl/subele
```

It does not replace Apple's notarisation, but it lets you check the `.dmg` came
from this code. The workflow's Actions are pinned by SHA and each job has only
the permissions it uses.

The icon is generated by code in `Tools/make-icon.swift`, so it reviews in a diff
like any other file instead of being an opaque binary. It draws a dial turned past
its maximum — white up to the limit, amber continuing beyond it — with a speaker at
the centre. The amber is the same colour the meter uses while the limiter is
working. The menu bar icon repeats the idea in monochrome: **the arc continues past the
limit only when gain is above 100%**, so you can tell at a glance whether it is
boosting. The percentage sits next to it.

## Usage

<p align="center"><img src="docs/screenshot-menu.png" width="300" alt="Subele's menu"></p>

A speaker icon appears in the menu bar. Opening it gives you the output device and
format, a level meter that turns orange while the limiter is working, a 50–400%
slider, the mode switch with what each one does, and menus for latency, sample
rate, equalizer and language.

Gain, mode, equalizer, latency and language persist between launches. The sample
rate is not stored by the app: it belongs to the device, and macOS remembers it.

Everything that crosses between the UI and the audio thread — gain, mode,
equalizer bands and meters — goes through atomics (`Sources/CAtomics`, because
Swift's `Atomic` needs macOS 15).

One binary, two faces — the `.app` bundle just wraps it:

```bash
subele              # menu bar app
subele --cli        # interactive console
subele --cli --buffer 128
subele --help
```

`SUBELE_TRACE=1` traces every startup step to stderr. CoreAudio calls can block
indefinitely without returning an error, and when stdout is buffered such a hang
leaves no trace at all.

## Tests

```bash
swift test
```

No test touches hardware: the DSP is pure signal processing, and the engine runs
on a simulated HAL (`Tests/BoosterKitTests/FakeAudioHAL.swift`). No audio device,
no tap, no permissions, so they run on CI exactly as they do on a laptop. That is
deliberate: measuring through the speakers is useless, because anything else
playing on the machine mixes into the tap and contaminates the meter. Two rounds
of measurements were lost to background music before the tests moved off the
hardware.

What they pin down: exact gain while there is headroom, the limiter reaching the
ceiling but never passing it, transients from silence to full scale, bit-identical
output across block sizes from 32 to 1024, a flat equalizer leaving every bit
alone and each band boosting by what it says, channel counts from
mono to 32, the drawn curve matching a really filtered sine,
the spectrum analyser locating a tone,
NaN or infinity arriving in the input without killing the chain, inter-sample
peaks being limited, and gain changes ramping.

And for the engine, on the simulated HAL: a duplex interface that never plays the
microphone, a null buffer that doesn't silence the others, callbacks longer than
the work buffer, incompatible formats (16-bit, float64, big-endian, more than 32
channels) rejected before the tap exists, an aggregate that takes a while to get
ready, an `AudioDeviceStop` that fails without leaving freed memory under a live
callback, a hundred starts and stops without leaking, and the watchdog rebuilding
the chain when the IOProc stalls, or giving up when that doesn't help.

What they do **not** cover, left for real hardware (to be confirmed): specific
duplex USB interfaces, unplugging Bluetooth mid-playback, and starting without
capture permission.

## Known limitations

- **Another driver-based booster will deadlock it.** If eqMac or Boom 3D is
  running it owns the default output device, so we tap *its* virtual device,
  which is itself passing audio through. `AudioDeviceCreateIOProcIDWithBlock`
  then blocks forever with no error. Quit it first.
- **AirPlay, unconfirmed.** AirPlay speakers keep their own buffer of about two
  seconds and it has not been tested whether the aggregate device accepts them as
  an output (to be confirmed). Bluetooth works.
- **Voice mode raises the noise floor**, since makeup applies when there is no
  signal too. Inherent to the mode, not a defect.
- **It does not start at login.** Deliberate: no login item is installed without
  being asked for.

## Layout

```
Sources/CAtomics/            atomic loads and stores for the parameters
Sources/BoosterKit/          the reusable part, no AppKit
  Booster.swift              the version, single source of truth
  Atomics.swift              atomic Float and UInt32 over CAtomics
  CoreAudio/
    AudioObject.swift        typed wrapper over the property API, errors, tracing
    AudioDevices.swift       device and stream queries, observers
    AudioHAL.swift           what the engine asks of CoreAudio, as a protocol
    ProcessTap.swift         create the tap, read its format
    AggregateDevice.swift    create the aggregate device
  DSP/
    Decibels.swift           dB conversions and smoothing coefficients
    Compressor.swift         soft-knee curve and automatic makeup
    Equalizer.swift          5 RBJ biquads, coefficients recomputed on the audio thread
    Limiter.swift            delay line, sliding-window minimum and true peak
    BoostProcessor.swift     the chain
  Analysis/
    SpectrumTap.swift        latest output samples, lock-free
    SpectrumAnalyzer.swift   FFT into logarithmic bands
  Engine/
    BoostEngine.swift        builds and tears down tap + aggregate + IOProc, in order
    EngineController.swift   own queue, states and watchdog
    IORenderer.swift         the callback: locates the tap, processes, distributes
    StreamFormat.swift       which formats are accepted
Sources/subele/              the executable
  main.swift                 picks a mode from the arguments
  EqualizerView.swift        the graphical equalizer
  MenuBarApp.swift           AppKit front end: builds the menu, shows the state
  StatusPanel.swift          the top panel: meter, slider, mode
  StayOpenMenuRow.swift      a menu row that doesn't close the menu (presets)
  EqualizerPreset.swift      the equalizer presets
  AppSettings.swift          what is kept between sessions
  MenuBarIcon.swift          menu bar icon, drawn in code
  LevelMeterView.swift
  ConsoleMode.swift
  Strings.swift              every visible string, typed, in two languages
Tools/make-icon.swift        generates AppIcon.icns
Tools/make-og.swift          generates the site's share images
Tools/thd-softclip.py        distortion of a per-sample soft limiter, for comparison
docs/                        the site: / in Spanish, /en/ in English
Tests/BoosterKitTests/       DSP, renderer, engine and controller on FakeAudioHAL
```

`BoosterKit` has no AppKit dependency and no knowledge of the UI, so the engine
can be embedded in something else.

> Source comments are in Spanish — this is a Spanish-language project with a
> bilingual interface. The public API names and this document are in English.

## Site

[carlostapiacl.github.io/subele](https://carlostapiacl.github.io/subele/) — the project page, in `docs/`.

## License

MIT © Carlos Tapia
