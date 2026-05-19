/// S3MMixer.swift
///
/// Software mixer for an `S3MFile`. Iterates through the order list
/// + patterns, applies effects, and renders interleaved stereo
/// `Float32` PCM frames on demand into a caller-provided buffer.
///
/// ## Timing model
/// S3M defines two timing knobs:
/// - `speed`  — ticks per row (default 6)
/// - `tempo`  — tick rate (default 125 → 50 Hz tick)
///
/// Concretely:
/// ```
/// tickRateHz       = tempo * 2 / 5
/// samplesPerTick   = sampleRate / tickRateHz
/// samplesPerRow    = samplesPerTick * speed
/// ```
///
/// Effects evaluate once per tick. Volume/pitch slides update on
/// ticks 1..speed-1; note triggers happen on tick 0.
///
/// ## Supported effects (Pass 1)
/// - **A** Set speed
/// - **B** Position jump
/// - **C** Pattern break
/// - **D** Volume slide (D0X/DX0/DFX/DXF fine)
/// - **E** Portamento down
/// - **F** Portamento up
/// - **O** Sample offset
/// - **T** Set tempo
/// - **V** Global volume
///
/// Other effects (vibrato, tremolo, arpeggio, tone porta, retrigger,
/// special S-effects, panning) parse cleanly but no-op until a
/// follow-up pass implements them.

import Foundation

/// Single-owner mutable state — the host parks the mixer on one
/// audio thread (typically AVAudioSourceNode's render thread) and
/// never touches it elsewhere. We assert `@unchecked Sendable` so
/// the render closure can capture it across the audio-thread hop
/// without Swift 6 complaining; concurrent rendering on more than
/// one thread is unsupported and would corrupt voice state.
public final class S3MMixer: @unchecked Sendable {

    // MARK: - Configuration

    /// Output sample rate, in Hz. Driven by the host audio engine's
    /// preferred rate.
    public let sampleRate: Double

    // MARK: - Module state

    private let file: S3MFile
    private var order: Int = 0
    private var row: Int = 0
    private var tick: Int = 0
    private var speed: Int
    private var tempo: Int
    private var globalVolume: Int

    /// Frames remaining in the current tick. When this hits zero
    /// we advance to the next tick (and to the next row when
    /// `tick` cycles back to 0).
    private var framesRemainingInTick: Int = 0

    private var voices: [Voice]
    private let channelPan: [Float]

    /// Set to `true` once the order list has been exhausted (no
    /// loop). Surface to the host so playback can be torn down.
    public private(set) var finished: Bool = false

    // MARK: - Voice state

    private struct Voice {
        var sample: [Int16] = []
        var samplePos: Double = 0
        /// Frequency multiplier per output frame.
        var step: Double = 0
        var volume: Int = 64
        var pan: Float = 0
        var instrumentIndex: Int = 0
        var loopBegin: Int = 0
        var loopEnd: Int = 0
        var loops: Bool = false
        var active: Bool = false

        var note: UInt8 = 0xFF
        var c2spd: UInt32 = 8363

        // Per-effect persistent state.
        var lastVolumeSlide: UInt8 = 0
        var lastPortaUp: UInt8 = 0
        var lastPortaDown: UInt8 = 0
        var lastOffset: UInt8 = 0
    }

    // MARK: - Init

    public init(file: S3MFile, sampleRate: Double) {
        self.file = file
        self.sampleRate = sampleRate
        self.speed = Int(file.initialSpeed == 0 ? 6 : file.initialSpeed)
        self.tempo = Int(file.initialTempo == 0 ? 125 : file.initialTempo)
        self.globalVolume = Int(file.globalVolume)
        self.voices = Array(repeating: Voice(), count: 32)
        // Convert S3M's 0..15 pan (0 = full left, 15 = full right)
        // into a Float in [-1, 1].
        self.channelPan = file.channelPanning.map { raw -> Float in
            let v = Float(min(raw, 15))
            return (v / 15.0) * 2.0 - 1.0
        }
        self.framesRemainingInTick = framesPerTick()
        triggerRow()
    }

    // MARK: - Render entry point

    /// Fill `frames` interleaved stereo float samples (`L R L R …`).
    /// Returns the number of frames actually written; less than
    /// `frames` means the song ended.
    @discardableResult
    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        var written = 0
        while written < frames {
            if finished { break }
            let available = framesRemainingInTick
            let toWrite = min(frames - written, available)
            renderChunk(into: buffer.advanced(by: written * 2), frames: toWrite)
            written += toWrite
            framesRemainingInTick -= toWrite
            if framesRemainingInTick == 0 {
                advanceTick()
                if finished { break }
                framesRemainingInTick = framesPerTick()
            }
        }
        // Silence any unwritten tail so the audio buffer doesn't
        // leak previous content.
        if written < frames {
            let tail = (frames - written) * 2
            buffer.advanced(by: written * 2).update(repeating: 0, count: tail)
        }
        return written
    }

    // MARK: - Chunk rendering

    private func renderChunk(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        // Zero the output region first — voices accumulate into it.
        buffer.update(repeating: 0, count: frames * 2)

        for v in 0..<voices.count where voices[v].active {
            mixVoice(into: buffer, frames: frames, voice: v)
        }
    }

    private func mixVoice(into buffer: UnsafeMutablePointer<Float>, frames: Int, voice: Int) {
        let g = Float(globalVolume) / 64.0 * Float(file.masterVolume & 0x7F) / 127.0
        let amp = Float(voices[voice].volume) / 64.0 * g / Float(max(1, min(32, file.activeChannelCount)))
        let pan = voices[voice].pan
        let panL = max(0, 1 - pan) * 0.5 + 0.5 * (pan > 0 ? 0 : 1)
        let panR = max(0, 1 + pan) * 0.5 + 0.5 * (pan < 0 ? 0 : 1)

        let sample = voices[voice].sample
        let loopBegin = voices[voice].loopBegin
        let loopEnd = voices[voice].loopEnd
        let loops = voices[voice].loops
        var pos = voices[voice].samplePos
        let step = voices[voice].step

        for i in 0..<frames {
            let intPos = Int(pos)
            if intPos >= sample.count {
                if loops && loopEnd > loopBegin {
                    pos = Double(loopBegin) + pos.truncatingRemainder(dividingBy: Double(loopEnd - loopBegin))
                } else {
                    voices[voice].active = false
                    break
                }
            }
            // Linear interpolation between intPos and intPos+1.
            let s0 = Float(sample[intPos]) / 32768.0
            let s1Idx = intPos + 1
            let s1 = (s1Idx < sample.count) ? Float(sample[s1Idx]) / 32768.0 : s0
            let frac = Float(pos - Double(intPos))
            let s = s0 + (s1 - s0) * frac

            buffer[i * 2]     += s * amp * panL
            buffer[i * 2 + 1] += s * amp * panR

            pos += step
            if loops && loopEnd > loopBegin && pos >= Double(loopEnd) {
                pos -= Double(loopEnd - loopBegin)
            }
        }
        voices[voice].samplePos = pos
    }

    // MARK: - Tick / row advancement

    private func advanceTick() {
        tick += 1
        if tick >= speed {
            tick = 0
            row += 1
            if row >= 64 {
                row = 0
                order += 1
                if !nextValidOrder() {
                    finished = true
                    return
                }
            }
            triggerRow()
        } else {
            applyTickEffects()
        }
    }

    /// Skip empty/marker entries in the order list. Returns false
    /// when we wrap past the end of the song.
    private func nextValidOrder() -> Bool {
        while order < file.orders.count {
            let p = file.orders[order]
            if p == 0xFF { return false }       // end of song
            if p == 0xFE { order += 1; continue } // marker
            return true
        }
        return false
    }

    /// On tick 0 we trigger notes, set instruments, apply tick-0
    /// effect commands (set speed/tempo, position jump, etc).
    private func triggerRow() {
        guard order < file.orders.count else {
            finished = true
            return
        }
        let patternIdx = Int(file.orders[order])
        guard patternIdx < file.patterns.count else {
            finished = true
            return
        }
        let pattern = file.patterns[patternIdx]
        guard row < pattern.rows.count else { return }
        let rowCells = pattern.rows[row]

        for (channel, cell) in rowCells.enumerated() where channel < voices.count {
            guard file.channelEnabled[channel] else { continue }
            applyTriggerCell(channel: channel, cell: cell)
        }
    }

    private func applyTriggerCell(channel: Int, cell: S3MPattern.Cell) {
        // Instrument set?
        if cell.instrument > 0 && Int(cell.instrument) - 1 < file.instruments.count {
            let ins = file.instruments[Int(cell.instrument) - 1]
            voices[channel].instrumentIndex = Int(cell.instrument)
            voices[channel].sample = ins.sampleData
            voices[channel].loopBegin = ins.loopBegin
            voices[channel].loopEnd = ins.loopEnd
            voices[channel].loops = ins.loops && ins.loopEnd > ins.loopBegin
            voices[channel].c2spd = ins.c2spd
            voices[channel].volume = Int(ins.defaultVolume)
            voices[channel].pan = channelPan[channel]
        }

        // Note?
        if cell.note != 0xFF {
            if cell.note == 0xFE {
                // Key off — drop volume to zero, deactivate.
                voices[channel].active = false
            } else {
                voices[channel].note = cell.note
                voices[channel].samplePos = 0
                voices[channel].active = !voices[channel].sample.isEmpty
                let octave = Int(cell.note >> 4)
                let halfStep = Int(cell.note & 0x0F)
                let semis = (octave - 4) * 12 + halfStep
                let freq = Double(voices[channel].c2spd) * pow(2.0, Double(semis) / 12.0)
                voices[channel].step = freq / sampleRate
            }
        }

        // Volume column.
        if cell.volume != 0xFF && cell.volume <= 64 {
            voices[channel].volume = Int(cell.volume)
        }

        // Effects.
        applyEffectTick0(channel: channel, command: cell.command, info: cell.info)
    }

    // MARK: - Effects (Tick 0)

    private func applyEffectTick0(channel: Int, command: UInt8, info: UInt8) {
        guard command != 0 else { return }
        // S3M uses command bytes 1..26 = A..Z.
        switch command {
        case 1:    // A — Set speed
            if info > 0 { speed = Int(info) }
        case 2:    // B — Position jump
            order = Int(info) - 1
            row = 63 // next tick advance bumps to row 0 of new order
        case 3:    // C — Pattern break
            // Decimal-encoded target row in info nibbles.
            let target = Int((info >> 4) * 10 + (info & 0x0F))
            row = min(target, 63) - 1
        case 4:    // D — Volume slide
            voices[channel].lastVolumeSlide = info
            applyVolumeSlideTick0(channel: channel, info: info)
        case 5:    // E — Portamento down
            if info != 0 { voices[channel].lastPortaDown = info }
            applyPortamentoTick0(channel: channel, amount: voices[channel].lastPortaDown, down: true)
        case 6:    // F — Portamento up
            if info != 0 { voices[channel].lastPortaUp = info }
            applyPortamentoTick0(channel: channel, amount: voices[channel].lastPortaUp, down: false)
        case 15:   // O — Sample offset
            if info != 0 { voices[channel].lastOffset = info }
            let offset = Int(voices[channel].lastOffset) * 256
            if offset < voices[channel].sample.count {
                voices[channel].samplePos = Double(offset)
            } else {
                voices[channel].active = false
            }
        case 20:   // T — Set tempo
            if info >= 32 { tempo = Int(info) }
        case 22:   // V — Global volume
            if info <= 64 { globalVolume = Int(info) }
        default:
            // Other effects parse but no-op for now.
            break
        }
    }

    // MARK: - Effects (Tick > 0)

    private func applyTickEffects() {
        guard order < file.orders.count else { return }
        let patternIdx = Int(file.orders[order])
        guard patternIdx < file.patterns.count else { return }
        let pattern = file.patterns[patternIdx]
        guard row < pattern.rows.count else { return }
        let rowCells = pattern.rows[row]

        for (channel, cell) in rowCells.enumerated() where channel < voices.count {
            switch cell.command {
            case 4:  // D — Volume slide
                applyVolumeSlideTickN(channel: channel, info: voices[channel].lastVolumeSlide)
            case 5:  // E — Portamento down
                applyPortamentoTickN(channel: channel, amount: voices[channel].lastPortaDown, down: true)
            case 6:  // F — Portamento up
                applyPortamentoTickN(channel: channel, amount: voices[channel].lastPortaUp, down: false)
            default:
                break
            }
        }
    }

    private func applyVolumeSlideTick0(channel: Int, info: UInt8) {
        let hi = (info >> 4) & 0x0F
        let lo = info & 0x0F
        // Fine slides (DFx / DxF) apply on tick 0 only.
        if hi == 0x0F && lo != 0 {
            voices[channel].volume = max(0, voices[channel].volume - Int(lo))
        } else if lo == 0x0F && hi != 0 {
            voices[channel].volume = min(64, voices[channel].volume + Int(hi))
        }
        // Coarse slides (Dxy where x != F and y != F) handled on
        // subsequent ticks.
    }

    private func applyVolumeSlideTickN(channel: Int, info: UInt8) {
        let hi = (info >> 4) & 0x0F
        let lo = info & 0x0F
        // Skip fine slides — they fired on tick 0.
        if hi == 0x0F || lo == 0x0F { return }
        if hi != 0 {
            voices[channel].volume = min(64, voices[channel].volume + Int(hi))
        } else if lo != 0 {
            voices[channel].volume = max(0, voices[channel].volume - Int(lo))
        }
    }

    private func applyPortamentoTick0(channel: Int, amount: UInt8, down: Bool) {
        // Fine porta: top nibble is 0xF → apply 4× the low nibble
        // on tick 0 only. Extra-fine porta: top nibble is 0xE → 1×
        // the low nibble on tick 0 only.
        let hi = (amount >> 4) & 0x0F
        let lo = amount & 0x0F
        if hi == 0x0F {
            applyPortamento(channel: channel, semitones: Double(lo) * 4 / 16, down: down)
        } else if hi == 0x0E {
            applyPortamento(channel: channel, semitones: Double(lo) / 16, down: down)
        }
    }

    private func applyPortamentoTickN(channel: Int, amount: UInt8, down: Bool) {
        let hi = (amount >> 4) & 0x0F
        if hi == 0x0F || hi == 0x0E { return }  // fine variants fired on tick 0
        let units = Double(amount) * 4 / 16
        applyPortamento(channel: channel, semitones: units, down: down)
    }

    /// Multiply playback step by `2^(±semitones / 12)`. The S3M
    /// porta unit is conventionally 1/16th of a semitone × 4.
    private func applyPortamento(channel: Int, semitones: Double, down: Bool) {
        guard voices[channel].step > 0 else { return }
        let exp = down ? -semitones : semitones
        voices[channel].step *= pow(2.0, exp / 12.0)
    }

    // MARK: - Timing helpers

    private func framesPerTick() -> Int {
        // tickRateHz = tempo * 2 / 5
        let tickRate = Double(tempo) * 2.0 / 5.0
        return max(1, Int(sampleRate / tickRate))
    }
}
