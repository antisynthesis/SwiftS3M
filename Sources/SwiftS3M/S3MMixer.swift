/// S3MMixer.swift
///
/// Software mixer for an `S3MFile`. Iterates through the order list
/// plus patterns, applies effects, and renders interleaved stereo
/// `Float32` PCM frames on demand into a caller-provided buffer.
///
/// ## Timing model
/// S3M defines two timing knobs:
/// - `speed`  : ticks per row (default 6)
/// - `tempo`  : tick rate (default 125 = 50 Hz tick)
///
/// Concretely:
/// ```
/// tickRateHz       = tempo * 2 / 5
/// samplesPerTick   = sampleRate / tickRateHz
/// samplesPerRow    = samplesPerTick * speed
/// ```
///
/// Effects evaluate once per tick. Note triggers happen on tick 0;
/// continuous modulation (vibrato, tremolo, arpeggio, slides) runs
/// on every tick.
///
/// ## Supported effects
/// Full S3M PCM effect set:
/// - **A** Set speed
/// - **B** Position jump
/// - **C** Pattern break
/// - **D** Volume slide (incl. fine `DFx` / `DxF`)
/// - **E** Portamento down (incl. fine `EFx` / extra-fine `EEx`)
/// - **F** Portamento up (incl. fine `FFx` / extra-fine `FEx`)
/// - **G** Tone portamento
/// - **H** Vibrato
/// - **I** Tremor
/// - **J** Arpeggio
/// - **K** Vibrato + volume slide (`H` + `D`)
/// - **L** Tone portamento + volume slide (`G` + `D`)
/// - **O** Sample offset
/// - **Q** Retrigger
/// - **R** Tremolo
/// - **S** Special effect group (`S0`..`SF`)
/// - **T** Set tempo
/// - **U** Fine vibrato (1/4 depth)
/// - **V** Global volume
/// - **X** Set pan position
///
/// `S` subcommands:
/// - **S0x** Set filter (parsed, no-op on PCM)
/// - **S1x** Set glissando (round tone porta to semitones)
/// - **S2x** Set finetune
/// - **S3x** Set vibrato waveform (0..3)
/// - **S4x** Set tremolo waveform (0..3)
/// - **S8x** Set pan position
/// - **S9x** Sound control (S91 = surround)
/// - **SAx** Stereo control (parsed, no-op)
/// - **SBx** Pattern loop
/// - **SCx** Note cut
/// - **SDx** Note delay
/// - **SEx** Pattern delay (extra row repeats)
/// - **SFx** Set active macro (MIDI, parsed and ignored)
///
/// Adlib (type-2) instruments are routed through `OPL2Synth` so
/// the FM channels render alongside PCM. See `OPL2Synth.swift`.

import Foundation

public final class S3MMixer: @unchecked Sendable {

    // MARK: - Configuration

    /// Output sample rate, in Hz.
    public let sampleRate: Double

    // MARK: - Module state

    private let file: S3MFile
    private var order: Int = 0
    private var row: Int = 0
    private var tick: Int = 0
    private var speed: Int
    private var tempo: Int
    private var globalVolume: Int

    private var framesRemainingInTick: Int = 0
    private var voices: [Voice]
    private let channelPan: [Float]

    /// Set to `true` once the order list has been exhausted.
    public private(set) var finished: Bool = false

    // MARK: - Row-level orchestration

    /// SBx pattern-loop bookmark + remaining iteration count.
    private var patternLoopRow: Int = 0
    private var patternLoopCount: Int = 0

    /// SEx pattern delay: how many extra times to replay the
    /// current row before advancing. Effects continue running on
    /// each replay, but the cell's note does not retrigger.
    private var pendingRowRepeats: Int = 0
    /// True while we're inside a repeat iteration of the current
    /// row (suppresses note retriggering in `triggerRow`).
    private var suppressNoteTriggers: Bool = false

    /// `true` if a B/C/SB caused us to jump this row. Used so a
    /// later effect on the same row can't fight the jump.
    private var rowJumped: Bool = false

    /// Cheap PRNG state for waveform 3 (random vibrato/tremolo).
    /// Xorshift64; seeded once.
    private var rng: UInt64 = 0x9E3779B97F4A7C15

    // MARK: - Voice state

    private struct Voice {

        // Sample source state.
        var sample: [Int16] = []
        var samplePos: Double = 0

        /// Step at the current "base" pitch (last note + porta
        /// shifts). `effectiveStep` may differ when vibrato or
        /// arpeggio is overlaying modulation this tick.
        var baseStep: Double = 0
        /// Step the mixer actually advances by while rendering.
        var effectiveStep: Double = 0

        /// Underlying volume (0..64), modified by D/Q/I/SC.
        var volume: Int = 64
        /// Volume the mixer actually uses (R tremolo + I tremor
        /// layered on top of `volume`).
        var effectiveVolume: Int = 64

        var pan: Float = 0
        var instrumentIndex: Int = 0
        var loopBegin: Int = 0
        var loopEnd: Int = 0
        var loops: Bool = false
        var active: Bool = false

        var note: UInt8 = 0xFF
        var c2spd: UInt32 = 8363

        // Per-effect persistent state (sticky info bytes).
        var lastVolumeSlide: UInt8 = 0
        var lastPortaUp: UInt8 = 0
        var lastPortaDown: UInt8 = 0
        var lastOffset: UInt8 = 0
        var lastTonePorta: UInt8 = 0
        var lastVibrato: UInt8 = 0
        var lastTremolo: UInt8 = 0
        var lastArpeggio: UInt8 = 0
        var lastRetrigger: UInt8 = 0
        var lastTremor: UInt8 = 0

        // Tone portamento (G/L) target.
        var tonePortaTargetStep: Double = 0

        // Vibrato (H/U) and tremolo (R) oscillators.
        var vibratoPos: Int = 0
        var vibratoSpeed: Int = 0
        var vibratoDepth: Int = 0
        var vibratoWaveform: UInt8 = 0
        /// S3x bit 2 controls whether a new note resets vibratoPos.
        /// Default = reset on new note.
        var vibratoRetrigger: Bool = true

        var tremoloPos: Int = 0
        var tremoloSpeed: Int = 0
        var tremoloDepth: Int = 0
        var tremoloWaveform: UInt8 = 0
        var tremoloRetrigger: Bool = true

        // S1x glissando: tone porta snaps to semitone boundaries.
        var glissando: Bool = false

        // Tremor (I) on/off oscillator.
        var tremorOn: Bool = true
        var tremorCount: Int = 0

        // SCx note cut: kill volume on this tick (counting from 0).
        var noteCutAt: Int = -1

        // SDx note delay: trigger the deferred cell on this tick.
        var noteDelayAt: Int = -1
        var noteDelayedCell: S3MPattern.Cell?

        // Active-this-row effect flags. Reset on every row trigger
        // and set whenever the corresponding command runs on tick 0
        // so the per-tick handler knows what overlay to compute.
        var vibratoActive: Bool = false
        var tremoloActive: Bool = false
        var arpeggioActive: Bool = false
        var tonePortaActive: Bool = false
        var tremorActive: Bool = false
    }

    // MARK: - Waveform tables

    /// Sine wave, 64-step, peak ±64 (ST3 convention).
    private static let sineTable: [Int] = {
        var arr = [Int](repeating: 0, count: 64)
        for i in 0..<64 {
            arr[i] = Int((sin(Double(i) * .pi / 32.0) * 64.0).rounded())
        }
        return arr
    }()

    /// Sawtooth descending from +64 down to -64 over 64 steps.
    private static let rampDownTable: [Int] = {
        var arr = [Int](repeating: 0, count: 64)
        for i in 0..<64 {
            arr[i] = 64 - i * 2 - 1  // 63, 61, ..., -63, -65 (clamped)
        }
        return arr.map { max(-64, min(64, $0)) }
    }()

    /// Square wave +64 first half, -64 second half.
    private static let squareTable: [Int] = {
        var arr = [Int](repeating: 64, count: 64)
        for i in 32..<64 { arr[i] = -64 }
        return arr
    }()

    // MARK: - Init

    public init(file: S3MFile, sampleRate: Double) {
        self.file = file
        self.sampleRate = sampleRate
        self.speed = Int(file.initialSpeed == 0 ? 6 : file.initialSpeed)
        self.tempo = Int(file.initialTempo == 0 ? 125 : file.initialTempo)
        self.globalVolume = Int(file.globalVolume)
        self.voices = Array(repeating: Voice(), count: 32)
        self.channelPan = file.channelPanning.map { raw -> Float in
            let v = Float(min(raw, 15))
            return (v / 15.0) * 2.0 - 1.0
        }
        self.framesRemainingInTick = framesPerTick()
        triggerRow(applyNotes: true)
        recomputeEffectiveState()
    }

    // MARK: - Render entry point

    /// Fill `frames` interleaved stereo float samples (`L R L R …`).
    /// Returns the number of frames written. Less than `frames`
    /// means the song has ended; the unwritten tail is zeroed.
    @discardableResult
    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        var written = 0
        while written < frames {
            if finished { break }
            let toWrite = min(frames - written, framesRemainingInTick)
            renderChunk(into: buffer.advanced(by: written * 2), frames: toWrite)
            written += toWrite
            framesRemainingInTick -= toWrite
            if framesRemainingInTick == 0 {
                advanceTick()
                if finished { break }
                framesRemainingInTick = framesPerTick()
            }
        }
        if written < frames {
            let tail = (frames - written) * 2
            buffer.advanced(by: written * 2).update(repeating: 0, count: tail)
        }
        return written
    }

    // MARK: - Chunk rendering

    private func renderChunk(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        buffer.update(repeating: 0, count: frames * 2)
        for v in 0..<voices.count where voices[v].active {
            mixVoice(into: buffer, frames: frames, voice: v)
        }
    }

    private func mixVoice(into buffer: UnsafeMutablePointer<Float>, frames: Int, voice: Int) {
        let g = Float(globalVolume) / 64.0 * Float(file.masterVolume & 0x7F) / 127.0
        let amp = Float(voices[voice].effectiveVolume) / 64.0 * g /
                  Float(max(1, min(32, file.activeChannelCount)))
        let pan = voices[voice].pan
        let panL = max(0, (1 - pan) * 0.5)
        let panR = max(0, (1 + pan) * 0.5)

        let sample = voices[voice].sample
        let loopBegin = voices[voice].loopBegin
        let loopEnd = voices[voice].loopEnd
        let loops = voices[voice].loops
        var pos = voices[voice].samplePos
        let step = voices[voice].effectiveStep

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
            if pendingRowRepeats > 0 {
                pendingRowRepeats -= 1
                suppressNoteTriggers = true
                triggerRow(applyNotes: false)
                suppressNoteTriggers = false
            } else if rowJumped {
                rowJumped = false
                if !nextValidOrder() {
                    finished = true; return
                }
                triggerRow(applyNotes: true)
            } else {
                row += 1
                if row >= 64 {
                    row = 0
                    order += 1
                    if !nextValidOrder() {
                        finished = true; return
                    }
                }
                triggerRow(applyNotes: true)
            }
        } else {
            applyTickEffects()
        }
        // Handle any cells deferred via note delay (SDx).
        applyNoteDelayTriggers()
        recomputeEffectiveState()
    }

    private func nextValidOrder() -> Bool {
        while order < file.orders.count {
            let p = file.orders[order]
            if p == 0xFF { return false }
            if p == 0xFE { order += 1; continue }
            return true
        }
        return false
    }

    /// On tick 0 (or after a row jump / pattern-delay replay), set
    /// up each channel's state for the row. `applyNotes` is false
    /// when we're re-running a row due to SEx pattern delay; in
    /// that case effects still process (volume slides etc. fire
    /// again) but notes aren't retriggered.
    private func triggerRow(applyNotes: Bool) {
        guard order < file.orders.count else {
            finished = true; return
        }
        let patternIdx = Int(file.orders[order])
        guard patternIdx < file.patterns.count else {
            finished = true; return
        }
        let pattern = file.patterns[patternIdx]
        guard row < pattern.rows.count else { return }
        let rowCells = pattern.rows[row]

        // Clear per-row effect overlays. Volume slides/portas
        // restart fresh; vibrato/tremolo/arpeggio start inactive
        // and get re-armed by their command running on this row.
        for c in 0..<voices.count {
            voices[c].vibratoActive = false
            voices[c].tremoloActive = false
            voices[c].arpeggioActive = false
            voices[c].tonePortaActive = false
            voices[c].tremorActive = false
            voices[c].noteCutAt = -1
            voices[c].noteDelayAt = -1
            voices[c].noteDelayedCell = nil
        }

        for (channel, cell) in rowCells.enumerated() where channel < voices.count {
            guard file.channelEnabled[channel] else { continue }
            applyTriggerCell(channel: channel, cell: cell, applyNotes: applyNotes)
        }
    }

    /// Tick-0 handling for one channel.
    private func applyTriggerCell(channel: Int, cell: S3MPattern.Cell, applyNotes: Bool) {
        let usesTonePorta = (cell.command == 7 || cell.command == 12) // G or L
        let usesNoteDelay = (cell.command == 19) // S
                            && ((cell.info >> 4) == 0xD)
                            && ((cell.info & 0x0F) > 0)

        // Note delay: stash the cell for replay on tick X, then
        // skip everything else for tick 0 on this channel.
        if usesNoteDelay && applyNotes {
            voices[channel].noteDelayAt = Int(cell.info & 0x0F)
            voices[channel].noteDelayedCell = cell
            return
        }

        if applyNotes {
            installInstrument(channel: channel, cell: cell)
            installNote(channel: channel, cell: cell, usesTonePorta: usesTonePorta)
            applyVolumeColumn(channel: channel, cell: cell)
        }

        applyEffectTick0(channel: channel, command: cell.command, info: cell.info)
    }

    private func installInstrument(channel: Int, cell: S3MPattern.Cell) {
        guard cell.instrument > 0,
              Int(cell.instrument) - 1 < file.instruments.count
        else { return }
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

    private func installNote(channel: Int, cell: S3MPattern.Cell, usesTonePorta: Bool) {
        guard cell.note != 0xFF else { return }
        if cell.note == 0xFE {
            voices[channel].active = false
            return
        }
        let octave = Int(cell.note >> 4)
        let halfStep = Int(cell.note & 0x0F)
        let semis = (octave - 4) * 12 + halfStep
        let freq = Double(voices[channel].c2spd) * pow(2.0, Double(semis) / 12.0)
        let newStep = freq / sampleRate

        if usesTonePorta {
            // The note specifies a destination, not an immediate
            // retrigger. Keep current samplePos / baseStep alive.
            voices[channel].tonePortaTargetStep = newStep
            voices[channel].note = cell.note
            return
        }

        voices[channel].note = cell.note
        voices[channel].samplePos = 0
        voices[channel].active = !voices[channel].sample.isEmpty
        voices[channel].baseStep = newStep
        voices[channel].effectiveStep = newStep
        voices[channel].tonePortaTargetStep = newStep

        // Note-on resets the oscillators (unless S3x/S4x said no).
        if voices[channel].vibratoRetrigger {
            voices[channel].vibratoPos = 0
        }
        if voices[channel].tremoloRetrigger {
            voices[channel].tremoloPos = 0
        }
        voices[channel].tremorOn = true
        voices[channel].tremorCount = 0
    }

    private func applyVolumeColumn(channel: Int, cell: S3MPattern.Cell) {
        if cell.volume != 0xFF && cell.volume <= 64 {
            voices[channel].volume = Int(cell.volume)
        }
    }

    // MARK: - Effects (Tick 0)

    private func applyEffectTick0(channel: Int, command: UInt8, info: UInt8) {
        guard command != 0 else { return }
        switch command {
        case 1:    handleA(info: info)
        case 2:    handleB(info: info)
        case 3:    handleC(info: info)
        case 4:    handleDTick0(channel: channel, info: info)
        case 5:    handleETick0(channel: channel, info: info)
        case 6:    handleFTick0(channel: channel, info: info)
        case 7:    handleGTick0(channel: channel, info: info)
        case 8:    handleHTick0(channel: channel, info: info, fine: false)
        case 9:    handleITick0(channel: channel, info: info)
        case 10:   handleJTick0(channel: channel, info: info)
        case 11:   handleKTick0(channel: channel, info: info) // H + D
        case 12:   handleLTick0(channel: channel, info: info) // G + D
        case 15:   handleOTick0(channel: channel, info: info)
        case 17:   handleQTick0(channel: channel, info: info)
        case 18:   handleRTick0(channel: channel, info: info)
        case 19:   handleSTick0(channel: channel, info: info)
        case 20:   handleTTick0(info: info)
        case 21:   handleUTick0(channel: channel, info: info) // fine vibrato
        case 22:   handleVTick0(info: info)
        case 24:   handleXTick0(channel: channel, info: info)
        default:
            // Z, W, Y are not standard S3M effects.
            break
        }
    }

    // A: set speed
    private func handleA(info: UInt8) {
        if info > 0 { speed = Int(info) }
    }

    // B: position jump.
    private func handleB(info: UInt8) {
        order = Int(info)
        row = -1
        rowJumped = true
    }

    // C: pattern break to row x.
    private func handleC(info: UInt8) {
        let target = Int((info >> 4) * 10 + (info & 0x0F))
        order += 1
        row = min(target, 63) - 1
        rowJumped = true
    }

    // D: volume slide tick-0 (fine).
    private func handleDTick0(channel: Int, info: UInt8) {
        if info != 0 { voices[channel].lastVolumeSlide = info }
        applyVolumeSlideTick0(channel: channel, info: voices[channel].lastVolumeSlide)
    }

    // E: porta down tick-0 (fine/extra-fine).
    private func handleETick0(channel: Int, info: UInt8) {
        if info != 0 { voices[channel].lastPortaDown = info }
        applyPortamentoTick0(channel: channel, amount: voices[channel].lastPortaDown, down: true)
    }

    // F: porta up tick-0 (fine/extra-fine).
    private func handleFTick0(channel: Int, info: UInt8) {
        if info != 0 { voices[channel].lastPortaUp = info }
        applyPortamentoTick0(channel: channel, amount: voices[channel].lastPortaUp, down: false)
    }

    // G: tone portamento; info is slide rate (sticky).
    private func handleGTick0(channel: Int, info: UInt8) {
        if info != 0 { voices[channel].lastTonePorta = info }
        voices[channel].tonePortaActive = true
    }

    // H: vibrato. Hxy where x = speed, y = depth. Either nibble 0
    // means "keep previous." The `fine` flag (U command) divides
    // the depth by 4.
    private func handleHTick0(channel: Int, info: UInt8, fine: Bool) {
        let memoryInfo: UInt8
        if info != 0 { voices[channel].lastVibrato = info; memoryInfo = info }
        else { memoryInfo = voices[channel].lastVibrato }
        let hi = (memoryInfo >> 4) & 0x0F
        let lo = memoryInfo & 0x0F
        if hi != 0 { voices[channel].vibratoSpeed = Int(hi) }
        if lo != 0 {
            voices[channel].vibratoDepth = fine ? Int(lo) : Int(lo) * 4
        }
        voices[channel].vibratoActive = true
    }

    // I: tremor. Ixy where x = on ticks - 1, y = off ticks - 1.
    private func handleITick0(channel: Int, info: UInt8) {
        if info != 0 { voices[channel].lastTremor = info }
        voices[channel].tremorActive = true
    }

    // J: arpeggio.
    private func handleJTick0(channel: Int, info: UInt8) {
        if info != 0 { voices[channel].lastArpeggio = info }
        voices[channel].arpeggioActive = true
    }

    // K: vibrato + volume slide.
    private func handleKTick0(channel: Int, info: UInt8) {
        if info != 0 { voices[channel].lastVolumeSlide = info }
        voices[channel].vibratoActive = true  // vibrato reuses its own memory
        applyVolumeSlideTick0(channel: channel, info: voices[channel].lastVolumeSlide)
    }

    // L: tone porta + volume slide.
    private func handleLTick0(channel: Int, info: UInt8) {
        if info != 0 { voices[channel].lastVolumeSlide = info }
        voices[channel].tonePortaActive = true
        applyVolumeSlideTick0(channel: channel, info: voices[channel].lastVolumeSlide)
    }

    // O: sample offset.
    private func handleOTick0(channel: Int, info: UInt8) {
        if info != 0 { voices[channel].lastOffset = info }
        let offset = Int(voices[channel].lastOffset) * 256
        if offset < voices[channel].sample.count {
            voices[channel].samplePos = Double(offset)
        } else {
            voices[channel].active = false
        }
    }

    // Q: retrigger.
    private func handleQTick0(channel: Int, info: UInt8) {
        if info != 0 { voices[channel].lastRetrigger = info }
    }

    // R: tremolo. Rxy where x = speed, y = depth.
    private func handleRTick0(channel: Int, info: UInt8) {
        let memoryInfo: UInt8
        if info != 0 { voices[channel].lastTremolo = info; memoryInfo = info }
        else { memoryInfo = voices[channel].lastTremolo }
        let hi = (memoryInfo >> 4) & 0x0F
        let lo = memoryInfo & 0x0F
        if hi != 0 { voices[channel].tremoloSpeed = Int(hi) }
        if lo != 0 { voices[channel].tremoloDepth = Int(lo) }
        voices[channel].tremoloActive = true
    }

    // T: set tempo.
    private func handleTTick0(info: UInt8) {
        if info >= 32 { tempo = Int(info) }
    }

    // U: fine vibrato (1/4 depth).
    private func handleUTick0(channel: Int, info: UInt8) {
        handleHTick0(channel: channel, info: info, fine: true)
    }

    // V: global volume.
    private func handleVTick0(info: UInt8) {
        if info <= 64 { globalVolume = Int(info) }
    }

    // X: set pan position. 0x00..0x80 mapped to -1..+1.
    // 0xA4 = surround (we collapse to slightly-attenuated centre
    // since we don't render true surround).
    private func handleXTick0(channel: Int, info: UInt8) {
        if info == 0xA4 {
            voices[channel].pan = 0
        } else {
            let clamped = min(0x80, Int(info))
            voices[channel].pan = Float(clamped) / 64.0 - 1.0
        }
    }

    // MARK: - S effect group

    private func handleSTick0(channel: Int, info: UInt8) {
        let sub = (info >> 4) & 0x0F
        let v   = info & 0x0F
        switch sub {
        case 0x0:   // S0: set filter (no-op)
            break
        case 0x1:   // S1: glissando
            voices[channel].glissando = v != 0
        case 0x2:   // S2: finetune. Replaces c2spd via a fixed table.
            voices[channel].c2spd = Self.finetuneTable[Int(v)]
            // Recompute base step at the active note.
            if voices[channel].note != 0xFF && voices[channel].note != 0xFE {
                let octave = Int(voices[channel].note >> 4)
                let halfStep = Int(voices[channel].note & 0x0F)
                let semis = (octave - 4) * 12 + halfStep
                let freq = Double(voices[channel].c2spd) * pow(2.0, Double(semis) / 12.0)
                voices[channel].baseStep = freq / sampleRate
            }
        case 0x3:   // S3: vibrato waveform (bit 2 = "don't retrigger on note").
            voices[channel].vibratoWaveform = v & 0x03
            voices[channel].vibratoRetrigger = (v & 0x04) == 0
        case 0x4:   // S4: tremolo waveform.
            voices[channel].tremoloWaveform = v & 0x03
            voices[channel].tremoloRetrigger = (v & 0x04) == 0
        case 0x8:   // S8: set pan (4-bit, 0..15 = left..right).
            voices[channel].pan = (Float(v) / 15.0) * 2.0 - 1.0
        case 0x9:   // S9: sound control. S91 = surround (pan to centre).
            if v == 0x1 { voices[channel].pan = 0 }
        case 0xA:   // SA: stereo control (no-op)
            break
        case 0xB:   // SB: pattern loop
            handleSBPatternLoop(value: Int(v))
        case 0xC:   // SC: note cut
            voices[channel].noteCutAt = Int(v)
        case 0xD:   // SD: note delay (handled by triggerRow's path
                    // when applyNotes is true; nothing to do here).
            break
        case 0xE:   // SE: pattern delay
            pendingRowRepeats = Int(v)
            rowJumped = true   // hijack the advance-row path to repeat
        case 0xF:   // SF: set active macro (MIDI; ignore)
            break
        default:
            break
        }
    }

    private func handleSBPatternLoop(value: Int) {
        if value == 0 {
            patternLoopRow = row
        } else {
            if patternLoopCount == 0 {
                patternLoopCount = value
            } else {
                patternLoopCount -= 1
            }
            if patternLoopCount > 0 {
                row = patternLoopRow - 1
                rowJumped = true
            }
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
            case 4:                                          // D
                applyVolumeSlideTickN(channel: channel, info: voices[channel].lastVolumeSlide)
            case 5:                                          // E
                applyPortamentoTickN(channel: channel, amount: voices[channel].lastPortaDown, down: true)
            case 6:                                          // F
                applyPortamentoTickN(channel: channel, amount: voices[channel].lastPortaUp, down: false)
            case 7:                                          // G
                applyTonePortaTickN(channel: channel)
            case 11:                                         // K
                applyVolumeSlideTickN(channel: channel, info: voices[channel].lastVolumeSlide)
            case 12:                                         // L
                applyTonePortaTickN(channel: channel)
                applyVolumeSlideTickN(channel: channel, info: voices[channel].lastVolumeSlide)
            case 17:                                         // Q
                applyRetriggerTickN(channel: channel)
            default:
                break
            }
        }

        // Note cut + tremor are timer-driven and need to fire
        // regardless of whether their setup command was on this
        // tick. We walk all voices for them.
        for v in 0..<voices.count {
            if voices[v].noteCutAt == tick && tick > 0 {
                voices[v].volume = 0
            }
            if voices[v].tremorActive {
                advanceTremor(channel: v)
            }
        }
    }

    /// On the tick matching a SDx delay, run the deferred cell as
    /// if it were tick 0 (without re-entering the row trigger).
    private func applyNoteDelayTriggers() {
        for c in 0..<voices.count {
            guard voices[c].noteDelayAt == tick, let cell = voices[c].noteDelayedCell else {
                continue
            }
            voices[c].noteDelayAt = -1
            voices[c].noteDelayedCell = nil
            installInstrument(channel: c, cell: cell)
            installNote(channel: c, cell: cell, usesTonePorta: false)
            applyVolumeColumn(channel: c, cell: cell)
        }
    }

    private func applyVolumeSlideTick0(channel: Int, info: UInt8) {
        let hi = (info >> 4) & 0x0F
        let lo = info & 0x0F
        if hi == 0x0F && lo != 0 {
            voices[channel].volume = max(0, voices[channel].volume - Int(lo))
        } else if lo == 0x0F && hi != 0 {
            voices[channel].volume = min(64, voices[channel].volume + Int(hi))
        }
    }

    private func applyVolumeSlideTickN(channel: Int, info: UInt8) {
        let hi = (info >> 4) & 0x0F
        let lo = info & 0x0F
        if hi == 0x0F || lo == 0x0F { return }
        if hi != 0 {
            voices[channel].volume = min(64, voices[channel].volume + Int(hi))
        } else if lo != 0 {
            voices[channel].volume = max(0, voices[channel].volume - Int(lo))
        }
    }

    private func applyPortamentoTick0(channel: Int, amount: UInt8, down: Bool) {
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
        if hi == 0x0F || hi == 0x0E { return }
        let units = Double(amount) * 4 / 16
        applyPortamento(channel: channel, semitones: units, down: down)
    }

    private func applyPortamento(channel: Int, semitones: Double, down: Bool) {
        guard voices[channel].baseStep > 0 else { return }
        let exp = down ? -semitones : semitones
        let factor = pow(2.0, exp / 12.0)
        voices[channel].baseStep *= factor
        voices[channel].tonePortaTargetStep = voices[channel].baseStep
    }

    private func applyTonePortaTickN(channel: Int) {
        let amount = voices[channel].lastTonePorta
        guard amount > 0,
              voices[channel].baseStep > 0,
              voices[channel].tonePortaTargetStep > 0 else { return }
        let semis = Double(amount) * 4 / 16
        let factor = pow(2.0, semis / 12.0)
        let target = voices[channel].tonePortaTargetStep
        var step = voices[channel].baseStep
        if step < target {
            step = min(target, step * factor)
        } else if step > target {
            step = max(target, step / factor)
        }
        if voices[channel].glissando {
            // Snap toward target in whole-semitone increments.
            let ratio = step / Double(voices[channel].c2spd) * sampleRate
            let semisFromC2 = log2(ratio) * 12.0
            let rounded = (semisFromC2).rounded()
            step = Double(voices[channel].c2spd) * pow(2.0, rounded / 12.0) / sampleRate
        }
        voices[channel].baseStep = step
    }

    private func applyRetriggerTickN(channel: Int) {
        let info = voices[channel].lastRetrigger
        let interval = Int(info & 0x0F)
        guard interval > 0, tick % interval == 0 else { return }
        voices[channel].samplePos = 0
        voices[channel].active = !voices[channel].sample.isEmpty
        let mode = Int(info >> 4)
        var vol = voices[channel].volume
        switch mode {
        case 1:  vol -= 1
        case 2:  vol -= 2
        case 3:  vol -= 4
        case 4:  vol -= 8
        case 5:  vol -= 16
        case 6:  vol = (vol * 2) / 3
        case 7:  vol = vol / 2
        case 9:  vol += 1
        case 10: vol += 2
        case 11: vol += 4
        case 12: vol += 8
        case 13: vol += 16
        case 14: vol = (vol * 3) / 2
        case 15: vol = vol * 2
        default: break
        }
        voices[channel].volume = max(0, min(64, vol))
    }

    private func advanceTremor(channel: Int) {
        let info = voices[channel].lastTremor
        let onTicks = Int(info >> 4) + 1
        let offTicks = Int(info & 0x0F) + 1
        voices[channel].tremorCount += 1
        let cycle = onTicks + offTicks
        let phase = voices[channel].tremorCount % cycle
        voices[channel].tremorOn = phase < onTicks
    }

    // MARK: - Per-tick effective state recompute

    /// After every tick (0 or N), fold the active row-level
    /// overlays back into `effectiveStep` and `effectiveVolume`.
    /// Called from `init` and at the end of every `advanceTick`.
    private func recomputeEffectiveState() {
        for c in 0..<voices.count {
            var step = voices[c].baseStep
            if voices[c].vibratoActive && voices[c].vibratoDepth > 0 {
                let w = waveformSample(
                    pos: voices[c].vibratoPos,
                    waveform: voices[c].vibratoWaveform
                )
                let semis = Double(w * voices[c].vibratoDepth) / 128.0 / 16.0
                step *= pow(2.0, semis / 12.0)
                voices[c].vibratoPos = (voices[c].vibratoPos + voices[c].vibratoSpeed) & 0x3F
            }
            if voices[c].arpeggioActive && voices[c].lastArpeggio != 0 {
                let offset: Int
                switch tick % 3 {
                case 1: offset = Int(voices[c].lastArpeggio >> 4)
                case 2: offset = Int(voices[c].lastArpeggio & 0x0F)
                default: offset = 0
                }
                step *= pow(2.0, Double(offset) / 12.0)
            }
            voices[c].effectiveStep = step

            var vol = voices[c].volume
            if voices[c].tremoloActive && voices[c].tremoloDepth > 0 {
                let w = waveformSample(
                    pos: voices[c].tremoloPos,
                    waveform: voices[c].tremoloWaveform
                )
                vol += (w * voices[c].tremoloDepth) / 64
                voices[c].tremoloPos = (voices[c].tremoloPos + voices[c].tremoloSpeed) & 0x3F
            }
            if voices[c].tremorActive && !voices[c].tremorOn {
                vol = 0
            }
            voices[c].effectiveVolume = max(0, min(64, vol))
        }
    }

    private func waveformSample(pos: Int, waveform: UInt8) -> Int {
        let i = pos & 0x3F
        switch waveform {
        case 0: return Self.sineTable[i]
        case 1: return Self.rampDownTable[i]
        case 2: return Self.squareTable[i]
        case 3:
            // Random in [-64, +63]. Xorshift64.
            rng ^= rng << 13
            rng ^= rng >> 7
            rng ^= rng << 17
            return Int(Int8(bitPattern: UInt8(rng & 0xFF)) >> 1)
        default:
            return Self.sineTable[i]
        }
    }

    // MARK: - Finetune table

    /// Standard ST3 finetune (S2x) values. Index 0..15 = the 4-bit
    /// finetune nibble; each entry is a c2spd in Hz. Centred at
    /// 8363 Hz (index 8).
    private static let finetuneTable: [UInt32] = [
        7895, 7941, 7985, 8046, 8107, 8169, 8232, 8280,
        8363, 8413, 8463, 8529, 8581, 8651, 8723, 8757
    ]

    // MARK: - Timing helpers

    private func framesPerTick() -> Int {
        let tickRate = Double(tempo) * 2.0 / 5.0
        return max(1, Int(sampleRate / tickRate))
    }
}
