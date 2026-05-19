# SwiftS3M

A pure-Swift decoder and software mixer for Scream Tracker 3 (`.s3m`) module files. No external dependencies. Foundation only. The mixer renders interleaved stereo `Float32` PCM into a caller-provided buffer, so it drops straight into `AVAudioEngine`, `AVAudioSourceNode`, or any other audio host you can hand a pointer to.

```swift
let file = try S3MFile(data: data)
let mixer = S3MMixer(file: file, sampleRate: 44_100)
```

That's the whole API surface, roughly.

---

## Contents

- [What this is](#what-this-is)
- [A short history of Scream Tracker](#a-short-history-of-scream-tracker)
- [The S3M file format](#the-s3m-file-format)
- [Timing model](#timing-model)
- [Installation](#installation)
- [Quick start](#quick-start)
- [AVAudioEngine bridge](#avaudioengine-bridge)
- [Status](#status)
- [Requirements](#requirements)
- [License](#license)

---

## What this is

`SwiftS3M` is a from-scratch reader for the Scream Tracker 3 module format plus a software mixer that turns the parsed data into PCM. It targets modern Swift (6.0, strict concurrency on) and ships as a single library product. There is no UI, no playback engine, no file-format autodetection. Just `S3MFile` (the parser) and `S3MMixer` (the renderer). Hook the mixer up to whatever audio host you like.

The design constraint is "give me frames when I ask, don't allocate on the audio thread, don't pretend to be a player." Everything that isn't strictly necessary to produce samples lives outside the library.

## A short history of Scream Tracker

[Scream Tracker 3](https://en.wikipedia.org/wiki/Scream_Tracker) was released in 1994 by [Future Crew](https://en.wikipedia.org/wiki/Future_Crew), the Finnish demoscene group that dominated PC demos in the early '90s. The tracker was primarily written by Sami Tammilehto (handle: **PSI**), who had previously written `STM` (Scream Tracker 2) and effectively invented the modern multichannel PC tracker. ST3 grew out of the lineage that started with Karsten Obarski's `Ultimate Soundtracker` on the Amiga in 1987 and continued through the Amiga `.mod` ecosystem.

ST3's claim to fame was running 32 channels on commodity DOS hardware: 16 channels of PCM through a Sound Blaster (or compatible), plus 16 channels of FM synthesis through the Adlib/OPL2 chip. The pattern editor was a 64-row by 32-channel grid with note, instrument, volume column, and effect+info per cell. That's the same step-sequencer paradigm modern DAWs still expose under their "step" or "matrix" views.

The format and tracker became one of the dominant module standards of the DOS demoscene alongside Triton's [FastTracker II](https://en.wikipedia.org/wiki/FastTracker_2) (`.xm`, 1994) and Jeffrey Lim's [Impulse Tracker](https://en.wikipedia.org/wiki/Impulse_Tracker) (`.it`, 1995). If you watched a demo at [Assembly](https://en.wikipedia.org/wiki/Assembly_(demoparty)), The Party, or any of the smaller European parties between roughly 1993 and 1997, there's a real chance the soundtrack was an S3M. Future Crew's own *Second Reality* (1993) used a predecessor format, but the tracker that produced it directly influenced the S3M spec.

The canonical reference is `S3M.TXT`, a plain-text technical doc Sami shipped with ST3 (mirrored under [`Reference/S3M.TXT`](Reference/S3M.TXT) in this repo). The community has since added clarifications and edge-case notes (notably in OpenMPT's documentation), but `S3M.TXT` is still the authoritative source. This library follows it.

## The S3M file format

S3M is a binary container: a fixed 96-byte header, then a series of variable-length sections addressed by **parapointers**. A parapointer is a 16-bit little-endian value that you multiply by 16 to get a file offset (a hangover from DOS segment:offset addressing).

### Header (offsets 0x00 to 0x5F)

| Offset | Size | Field |
|-------:|-----:|-------|
| `0x00` | 28   | Song title, ASCII, padded with `0x00` or `0x1A` |
| `0x1C` | 1    | `0x1A` DOS EOF marker |
| `0x1D` | 1    | File type (`0x10` = ST3 module) |
| `0x20` | 2    | OrderCount |
| `0x22` | 2    | InsCount (instruments) |
| `0x24` | 2    | PatCount (patterns) |
| `0x26` | 2    | Flags |
| `0x28` | 2    | Created-with tracker version |
| `0x2A` | 2    | Sample format (1 = signed, 2 = unsigned 8-bit) |
| `0x2C` | 4    | `"SCRM"` signature |
| `0x30` | 1    | Global volume (0..64) |
| `0x31` | 1    | Initial speed (ticks per row) |
| `0x32` | 1    | Initial tempo |
| `0x33` | 1    | Master volume (bit 7 = stereo) |
| `0x35` | 1    | Default panning flag (`0xFC` = 32 pan bytes appended) |
| `0x40` | 32   | Channel settings (`< 0x10` = enabled) |

### Body

Immediately after the header, in order:

1. **Order list**: `OrderCount` bytes, one pattern index per slot. `0xFE` is a marker (skip), `0xFF` is end-of-song.
2. **Instrument parapointers**: `InsCount × UInt16 LE`.
3. **Pattern parapointers**: `PatCount × UInt16 LE`.
4. **Default panning table**: 32 bytes, only if the panning flag is `0xFC`.

Each instrument parapointer points at an 80-byte instrument header. Instruments come in three flavors:

- **Type 0**: empty slot.
- **Type 1**: PCM sample. Loop points, default volume, and `C2SPD` (the playback rate at which the sample sounds at C-4) live here. The actual sample bytes live at another offset stored in the instrument header. Supported sample bit depths: unsigned 8-bit, signed 8-bit, signed 16-bit little-endian.
- **Type 2**: Adlib FM instrument (parsed but silent in this library).

Each pattern parapointer points at a 16-bit length-prefixed run of **packed cell data**. Each row is a series of `(what, ...payload)` tuples terminated by a `0x00` byte:

- `what & 0x1F`: channel number (0..31).
- `what & 0x20`: note + instrument bytes follow.
- `what & 0x40`: volume column byte follows.
- `what & 0x80`: command + info bytes follow.

Notes are encoded as `(octave << 4) | halfStep`. `0xFF` means "no note," `0xFE` means key-off. Effects are encoded as command bytes 1..26 mapping to letters A..Z.

For the exhaustive layout (including subtleties like Adlib instruments, the surround flag, MIDI parapointers, and edge cases around 16-bit samples), refer to [`Reference/S3M.TXT`](Reference/S3M.TXT).

## Timing model

ST3 has two timing knobs that together determine playback rate:

- **`speed`**: number of ticks per row. Default 6. Set with effect `Axx`.
- **`tempo`**: tick rate in a specific unit. Default 125. Set with effect `Txx`.

The conversion is:

```
tickRateHz     = tempo * 2 / 5
samplesPerTick = sampleRate / tickRateHz
samplesPerRow  = samplesPerTick * speed
```

So at the defaults (`speed = 6`, `tempo = 125`, `sampleRate = 44100`), you get a 50 Hz tick and 882 samples per tick, which is the canonical ST3 timing.

Effects evaluate **once per tick**. Note triggers and tick-0-only effects fire on tick 0; continuous slides and modulation apply on every tick. This library implements the full S3M effect set:

- **A** Set speed
- **B** Position jump
- **C** Pattern break
- **D** Volume slide, including fine variants `DFx` / `DxF`
- **E** Portamento down, including fine `EFx` and extra-fine `EEx`
- **F** Portamento up, including fine `FFx` and extra-fine `FEx`
- **G** Tone portamento (with S1x glissando snap)
- **H** Vibrato (4 waveforms via S3x)
- **I** Tremor
- **J** Arpeggio
- **K** Vibrato + volume slide (H + D)
- **L** Tone portamento + volume slide (G + D)
- **O** Sample offset
- **Q** Retrigger (all 16 volume-change modes)
- **R** Tremolo (4 waveforms via S4x)
- **S** Special group `S0`..`SF` (filter, glissando, finetune, waveform select, pan, surround, pattern loop, note cut, note delay, pattern delay, MIDI macro)
- **T** Set tempo
- **U** Fine vibrato (1/4 depth)
- **V** Global volume
- **X** Set pan (0x00..0x80, surround at 0xA4)

Type-2 (Adlib / OPL2 FM) instruments render through an in-tree YM3812 emulator with four waveforms, rhythm mode, AM/VIB LFOs, and KSR envelope scaling. See [Status](#status) for the full feature breakdown.

## Installation

Swift Package Manager. Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/antisynthesis/SwiftS3M", from: "0.1.0")
]
```

Then depend on the `SwiftS3M` product from your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "SwiftS3M", package: "SwiftS3M")
    ]
)
```

For local development:

```swift
dependencies: [
    .package(path: "../SwiftS3M")
]
```

## Quick start

```swift
import SwiftS3M

let data = try Data(contentsOf: url)
let file = try S3MFile(data: data)

print(file.title)               // e.g. "PANIC.S3M"
print(file.activeChannelCount)  // e.g. 8

let mixer = S3MMixer(file: file, sampleRate: 44_100)

let frames = 1024
var buffer = [Float](repeating: 0, count: frames * 2) // interleaved L R
buffer.withUnsafeMutableBufferPointer { ptr in
    _ = mixer.render(into: ptr.baseAddress!, frames: frames)
}

if mixer.finished {
    // Order list exhausted. Song has ended.
}
```

`render(into:frames:)` returns the number of frames actually written. A short return means the song ended mid-buffer; the tail is zero-filled.

## AVAudioEngine bridge

Drop the mixer into an `AVAudioSourceNode` to play back on any Apple platform:

```swift
import AVFoundation
import SwiftS3M

final class S3MPlayer {
    private let engine = AVAudioEngine()
    private let mixer: S3MMixer
    private var sourceNode: AVAudioSourceNode!

    init(file: S3MFile) throws {
        let output = engine.outputNode
        let sampleRate = output.inputFormat(forBus: 0).sampleRate
        self.mixer = S3MMixer(file: file, sampleRate: sampleRate)

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: true
        )!

        self.sourceNode = AVAudioSourceNode(format: format) {
            [mixer] _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let raw = ablPointer[0].mData else { return noErr }
            let ptr = raw.assumingMemoryBound(to: Float.self)
            _ = mixer.render(into: ptr, frames: Int(frameCount))
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
    }

    func start() throws {
        try engine.start()
    }

    func stop() {
        engine.stop()
    }
}
```

The render callback runs on the audio thread. `S3MMixer` is `@unchecked Sendable` precisely because the host is expected to park it on one thread and never touch it elsewhere. There is no internal locking and concurrent renders will corrupt voice state.

## Status

v1 is feature-complete against `S3M.TXT` for the playback path. The parser handles the full S3M header, instrument table (8-bit signed/unsigned and 16-bit signed PCM, plus type-2 Adlib register bytes), and packed pattern data. The mixer implements the full effect set listed in [Timing model](#timing-model).

Type-2 (Adlib) instruments route through `OPL2Synth`, a 9-channel 2-operator FM emulator modeled on the Yamaha YM3812:

- **Four OPL2 waveforms** sourced from the instrument's `E0` / `E1` register bytes: pure sine, half sine, absolute (rectified) sine, and quarter sine.
- **Yamaha-style envelope timing** clocked off the documented 49716 Hz envelope-generator reference; per-operator KSR scaling adds the key-scale-number offset to the rate so higher notes envelope faster.
- **Operator-level AM and VIB** routed from two global LFOs (≈3.7 Hz / ≈6.4 Hz). The AM and VIB bits on the operator's character byte gate participation; depth defaults to Yamaha "deep" settings (4.8 dB / ±14 cents).
- **Rhythm mode** for channels 25..29 (bass drum / snare / tom / cymbal / hi-hat). A shared 16-bit LFSR noise generator drives the SD / HH / CY voices; rhythm mode auto-engages when the channel map admits any of those slots.

Pure PCM modules play back fully and match the spec. The FM path is voice-accurate and rhythm-aware; sample-accurate cycle parity with hardware OPL2 still has a few percent of timing drift at extreme envelope rates, which is the only intentional shortcut left.

Contributions welcome; see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Requirements

- Swift **6.0** or later
- Xcode **16** or later
- Platforms: **iOS 17+**, **macOS 14+**, **tvOS 17+**, **watchOS 10+**, **visionOS 1+**

No third-party dependencies. Foundation only.

## License

MIT. See [`LICENSE`](LICENSE).
