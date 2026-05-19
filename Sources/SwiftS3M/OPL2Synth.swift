/// OPL2Synth.swift
///
/// 9-channel 2-operator FM synthesizer modeled on the Yamaha
/// YM3812 (Adlib / OPL2). S3M places its Adlib melodic voices on
/// channels 16..24 of the channel map and the rhythm voices on
/// 25..31; this synth renders both into the same stereo float
/// buffer the PCM mixer uses, so a mixed PCM + FM module sounds
/// coherent without the host having to know which channels were
/// which.
///
/// Per-operator state:
/// - AR / DR / SL / RR : 4-bit attack/decay/sustain/release rates
/// - TL                : 6-bit total-level attenuation (0..63, 0.75dB/step)
/// - KSL               : 2-bit key-scale level (attenuation per octave)
/// - MULT              : 4-bit frequency multiplier (Yamaha mapping)
/// - EGT (sustain bit) : if set, hold at SL after decay; else release
/// - KSR               : key-scale rate (faster envelope at higher notes)
/// - AM                : operator-level amplitude modulation flag
/// - VIB               : operator-level vibrato flag
/// - waveform          : E0/E1 waveform select (0..3 on OPL2)
///
/// Per-channel state:
/// - FB                : 3-bit feedback amount applied to op1 self-modulation
/// - CNT               : connection mode (0 = FM, 1 = additive)
///
/// Global state:
/// - AM LFO (≈3.7 Hz) and VIB LFO (≈6.4 Hz) modulate operators that
///   set the corresponding flag.
/// - Rhythm mode (toggled by the host) reroutes channels 6/7/8 into
///   five percussion voices (bass drum / snare / tom / cymbal /
///   hi-hat), with a shared white-noise generator driving the
///   noise-tinted voices.

import Foundation

final class OPL2Synth: @unchecked Sendable {

    /// Percussion voice indices addressable by the host when rhythm
    /// mode is enabled. The host maps S3M channels 25..29 onto these
    /// (25 = bass, 26 = snare, 27 = tom, 28 = cymbal, 29 = hi-hat).
    enum PercussionVoice: Int, Sendable {
        case bassDrum  = 0
        case snareDrum = 1
        case tomTom    = 2
        case cymbal    = 3
        case hiHat     = 4
    }

    let sampleRate: Double

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.channels = Array(repeating: Channel(), count: 9)
        self.amPhaseStep = 2 * .pi * Self.amLFOHz / sampleRate
        self.vibPhaseStep = 2 * .pi * Self.vibLFOHz / sampleRate
    }

    /// Host control: toggle OPL2 rhythm mode on/off. When on, the
    /// last two melodic channels (6, 7, 8) are diverted to drive
    /// five percussion voices; existing melodic voices on those
    /// channels are silenced.
    func setRhythmMode(_ enabled: Bool) {
        if enabled == rhythmMode { return }
        rhythmMode = enabled
        if enabled {
            // Silence the melodic content on channels 6..8.
            for i in 6...8 {
                channels[i].keyOn = false
                channels[i].op1.stage = .off
                channels[i].op2.stage = .off
                channels[i].op1.envLevel = 0
                channels[i].op2.envLevel = 0
            }
        }
    }

    // MARK: - Key on / off / volume

    /// Configure operators from the instrument's OPL2 register
    /// bytes, compute the FNUM-style frequency from the note (we
    /// reuse the S3M C2SPD-based formula since we're not bound to
    /// real OPL2 FNUM/BLOCK accounting), and start both operators
    /// in their attack phase.
    func keyOn(channel idx: Int, note: UInt8, instrument: S3MInstrument, volume: Int) {
        guard idx >= 0, idx < channels.count else { return }
        // While rhythm mode is on, the melodic key-on for channels
        // 6..8 is suppressed so percussion routing isn't trampled.
        if rhythmMode && idx >= 6 && idx <= 8 { return }

        var ch = channels[idx]
        configureOperator(&ch.op1,
                          char: instrument.adlib.modChar,
                          scale: instrument.adlib.modScale,
                          attack: instrument.adlib.modAttack,
                          sustain: instrument.adlib.modSustain,
                          waveform: instrument.adlib.modWave)
        configureOperator(&ch.op2,
                          char: instrument.adlib.carChar,
                          scale: instrument.adlib.carScale,
                          attack: instrument.adlib.carAttack,
                          sustain: instrument.adlib.carSustain,
                          waveform: instrument.adlib.carWave)
        let fc = instrument.adlib.feedConnect
        ch.feedback = Int((fc >> 1) & 0x07)
        ch.additive = (fc & 0x01) != 0

        let octave = Int(note >> 4)
        let halfStep = Int(note & 0x0F)
        let semis = (octave - 4) * 12 + halfStep
        ch.frequency = Double(instrument.c2spd) * pow(2.0, Double(semis) / 12.0)
        // Key-scale number drives KSR-based envelope acceleration.
        // OPL2 derives KSN from (block << 1) | (fnum >> 9); here we
        // approximate it from the played octave.
        ch.keyScaleNumber = max(0, min(15, octave * 2 + (halfStep > 6 ? 1 : 0)))

        ch.volume = max(0, min(64, volume))
        ch.keyOn = true
        ch.op1.stage = .attack
        ch.op2.stage = .attack
        ch.op1.envLevel = 0
        ch.op2.envLevel = 0
        ch.op1.phase = 0
        ch.op2.phase = 0
        ch.feedbackHistory = (0, 0)
        channels[idx] = ch
    }

    func keyOff(channel idx: Int) {
        guard idx >= 0, idx < channels.count else { return }
        if rhythmMode && idx >= 6 && idx <= 8 { return }
        channels[idx].keyOn = false
        channels[idx].op1.stage = .release
        channels[idx].op2.stage = .release
    }

    func setVolume(channel idx: Int, volume: Int) {
        guard idx >= 0, idx < channels.count else { return }
        channels[idx].volume = max(0, min(64, volume))
    }

    /// Multiply the carrier frequency by `factor` (used by the
    /// outer mixer to apply porta / vibrato / arpeggio overlays
    /// per tick).
    func pitchScale(channel idx: Int, factor: Double) {
        guard idx >= 0, idx < channels.count else { return }
        channels[idx].pitchFactor = factor
    }

    /// True when the channel still has audible envelope output.
    func isActive(channel idx: Int) -> Bool {
        guard idx >= 0, idx < channels.count else { return false }
        let ch = channels[idx]
        return ch.keyOn || ch.op2.envLevel > 1e-5
    }

    // MARK: - Percussion (rhythm mode)

    /// Trigger one of the five rhythm-mode percussion voices.
    /// `keyOff` releases the voice; `volume` (0..64) scales the
    /// instrument's TL.
    func triggerPercussion(_ voice: PercussionVoice, instrument: S3MInstrument, volume: Int) {
        guard rhythmMode else { return }
        let idx = voice.rawValue
        var p = percussion[idx]
        configureOperator(&p.op1,
                          char: instrument.adlib.modChar,
                          scale: instrument.adlib.modScale,
                          attack: instrument.adlib.modAttack,
                          sustain: instrument.adlib.modSustain,
                          waveform: instrument.adlib.modWave)
        if voice == .bassDrum {
            // BD uses both operators — full 2-op FM voice like a
            // melodic channel.
            configureOperator(&p.op2,
                              char: instrument.adlib.carChar,
                              scale: instrument.adlib.carScale,
                              attack: instrument.adlib.carAttack,
                              sustain: instrument.adlib.carSustain,
                              waveform: instrument.adlib.carWave)
            let fc = instrument.adlib.feedConnect
            p.feedback = Int((fc >> 1) & 0x07)
            p.additive = (fc & 0x01) != 0
        }
        // Percussion uses a fixed frequency based on the instrument's
        // C2SPD (most authors tune drums via the same field).
        p.frequency = Double(instrument.c2spd)
        p.volume = max(0, min(64, volume))
        p.keyOn = true
        p.op1.stage = .attack
        p.op2.stage = .attack
        p.op1.envLevel = 0
        p.op2.envLevel = 0
        p.op1.phase = 0
        p.op2.phase = 0
        p.feedbackHistory = (0, 0)
        percussion[idx] = p
    }

    /// Release a percussion voice. Most drum hits use one-shot
    /// envelopes (high RR), so release usually completes within a
    /// few ms whether or not the host calls this.
    func keyOffPercussion(_ voice: PercussionVoice) {
        let idx = voice.rawValue
        percussion[idx].keyOn = false
        percussion[idx].op1.stage = .release
        percussion[idx].op2.stage = .release
    }

    // MARK: - Render

    /// Mix this synth's output into `buffer` (interleaved stereo
    /// float) for `frames` samples. `mainAmp` scales by the host's
    /// global/master volume so the OPL voices balance against PCM.
    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int, mainAmp: Float) {
        for i in 0..<frames {
            // Advance global LFOs once per sample.
            amPhase += amPhaseStep
            if amPhase > 2 * .pi { amPhase -= 2 * .pi }
            vibPhase += vibPhaseStep
            if vibPhase > 2 * .pi { vibPhase -= 2 * .pi }
            // Advance the noise generator once per sample. Cheap
            // 16-bit LFSR — Yamaha used a similar polynomial.
            noise = (noise >> 1) ^ (((noise ^ (noise >> 14)) & 1) << 15)

            var sum: Double = 0
            for c in 0..<channels.count {
                // In rhythm mode, channels 6..8 are commandeered by
                // the percussion render path below.
                if rhythmMode && c >= 6 && c <= 8 { continue }
                sum += renderChannel(c)
            }
            if rhythmMode {
                for v in 0..<percussion.count {
                    sum += renderPercussion(v)
                }
            }
            // OPL2 is mono on real hardware; route equally L/R.
            let s = Float(sum) * mainAmp * 0.25  // headroom
            buffer[i * 2]     += s
            buffer[i * 2 + 1] += s
        }
    }

    // MARK: - Internal model

    private struct Operator {
        var phase: Double = 0
        var envLevel: Double = 0     // 0 = silent, 1 = max
        var stage: Stage = .off
        var ar: Int = 0
        var dr: Int = 0
        var sl: Int = 0
        var rr: Int = 0
        var tl: Int = 0
        var ksl: Int = 0
        var mult: Int = 1
        var egt: Bool = false        // envelope type (sustain)
        var ksr: Bool = false
        var am: Bool = false
        var vib: Bool = false
        var waveform: Int = 0        // E0/E1 select: 0..3 on OPL2

        enum Stage { case off, attack, decay, sustain, release }
    }

    private struct Channel {
        var op1 = Operator()
        var op2 = Operator()
        var feedback: Int = 0        // 0..7
        var additive: Bool = false   // CNT bit
        var frequency: Double = 0    // base frequency in Hz
        var pitchFactor: Double = 1  // outer-mixer overlay
        var keyOn: Bool = false
        var volume: Int = 64
        /// Octave-derived key-scale number. Drives KSR-based
        /// envelope acceleration.
        var keyScaleNumber: Int = 0
        /// Two-sample running average of op1's output, fed back
        /// into op1's phase next sample (standard YM3812 feedback
        /// topology).
        var feedbackHistory: (Double, Double) = (0, 0)
    }

    private var channels: [Channel]
    private var percussion: [Channel] = Array(repeating: Channel(), count: 5)

    // MARK: - Global LFO + rhythm state

    /// OPL2 LFO frequencies per the Yamaha datasheet (well-known
    /// values used by every emulator). Both run all the time;
    /// operators only see them if their AM/VIB bit is set.
    private static let amLFOHz: Double = 3.7
    private static let vibLFOHz: Double = 6.4

    /// AM-depth setting (bit 7 of reg 0xBD). On OPL2 the two values
    /// are 1.0 dB or 4.8 dB; we hard-code the "deep" 4.8 dB version
    /// since that's what most Adlib music expected. Output is a
    /// scalar attenuation multiplier in roughly [0.6, 1.0].
    private static let amDepth: Double = 0.4 // 4.8 dB ≈ 0.4 attenuation
    /// VIB-depth setting (bit 6 of reg 0xBD). Yamaha's "deep" mode
    /// is ±14 cents, ≈±0.81%. We use that here.
    private static let vibDepth: Double = 0.0081

    private var amPhase: Double = 0
    private var amPhaseStep: Double = 0
    private var vibPhase: Double = 0
    private var vibPhaseStep: Double = 0

    /// 16-bit LFSR pseudo-noise. Drives the SD / HH / CY percussion
    /// voices when rhythm mode is on.
    private var noise: UInt32 = 0xBEEF

    private var rhythmMode: Bool = false

    private func configureOperator(_ op: inout Operator,
                                   char: UInt8, scale: UInt8,
                                   attack: UInt8, sustain: UInt8,
                                   waveform: UInt8) {
        op.mult = Self.multTable[Int(char & 0x0F)]
        op.ksr  = (char & 0x10) != 0
        op.egt  = (char & 0x20) != 0
        op.vib  = (char & 0x40) != 0
        op.am   = (char & 0x80) != 0

        op.ksl  = Int((scale >> 6) & 0x03)
        op.tl   = Int(scale & 0x3F)

        op.ar   = Int((attack >> 4) & 0x0F)
        op.dr   = Int(attack & 0x0F)

        op.sl   = Int((sustain >> 4) & 0x0F)
        op.rr   = Int(sustain & 0x0F)

        op.waveform = Int(waveform & 0x03)
    }

    // OPL2's MULT register encodes frequency multipliers with a
    // non-linear table: most slots are 1..n, but 0 = 1/2 and the
    // top entries collapse to 10/12/15.
    private static let multTable: [Int] = [
        1, 1, 2, 3, 4, 5, 6, 7,
        8, 9, 10, 10, 12, 12, 15, 15
        // index 0 is technically 0.5; we use 1 since per-sample
        // phase increment quantization would be awkward otherwise.
    ]

    /// Sample one of the four OPL2 waveforms at the given phase.
    /// Phase is in radians (0..2π); the carrier always wraps before
    /// calling, so we don't redo modulo math here.
    private func waveformSample(phase: Double, waveform: Int) -> Double {
        let s = sin(phase)
        switch waveform {
        case 0: return s
        case 1: return s > 0 ? s : 0           // half sine (positive half only)
        case 2: return abs(s)                  // absolute sine (rectified)
        case 3:
            // Quarter sine: 1st and 3rd quarters only.
            let quarter = Int(phase * 2 / .pi) & 0x03
            return (quarter == 0 || quarter == 2) ? abs(s) : 0
        default: return s
        }
    }

    /// Advance one frame for one channel and return its mono
    /// sample contribution in roughly the [-1, +1] band.
    private func renderChannel(_ idx: Int) -> Double {
        var ch = channels[idx]
        defer { channels[idx] = ch }

        // Idle channels save work.
        if !ch.keyOn && ch.op2.envLevel < 1e-5 && ch.op1.envLevel < 1e-5 {
            return 0
        }

        let amMod = amModulation()
        let vibMod = vibModulation()

        // Carrier base phase increment with global vibrato applied
        // per operator (only if its VIB bit is set).
        let basePhaseInc = ch.frequency * ch.pitchFactor * 2 * .pi / sampleRate

        // Op1 (modulator) with self-feedback.
        let fb = ch.feedback == 0
            ? 0.0
            : (ch.feedbackHistory.0 + ch.feedbackHistory.1) * 0.5
              * Self.feedbackScale[ch.feedback]
        let op1Vib = ch.op1.vib ? vibMod : 0
        let op1Inc = basePhaseInc * Double(ch.op1.mult) * (1 + op1Vib)
        ch.op1.phase += op1Inc
        if ch.op1.phase > 2 * .pi { ch.op1.phase -= 2 * .pi }
        let op1Wave = waveformSample(phase: ch.op1.phase + fb, waveform: ch.op1.waveform)
        advanceEnvelope(&ch.op1, keyScaleNumber: ch.keyScaleNumber)
        let op1AmGain = ch.op1.am ? (1 - amMod) : 1.0
        let op1Out = op1Wave * ch.op1.envLevel * tlAttenuation(ch.op1.tl) * op1AmGain

        // Op2 (carrier). FM mode uses op1's output as phase mod;
        // additive mode renders op2 independently.
        let op2Vib = ch.op2.vib ? vibMod : 0
        let op2Inc = basePhaseInc * Double(ch.op2.mult) * (1 + op2Vib)
        ch.op2.phase += op2Inc
        if ch.op2.phase > 2 * .pi { ch.op2.phase -= 2 * .pi }
        let op2Mod = ch.additive ? 0.0 : op1Out * .pi
        let op2Wave = waveformSample(phase: ch.op2.phase + op2Mod, waveform: ch.op2.waveform)
        advanceEnvelope(&ch.op2, keyScaleNumber: ch.keyScaleNumber)
        let op2AmGain = ch.op2.am ? (1 - amMod) : 1.0
        let op2Out = op2Wave * ch.op2.envLevel * tlAttenuation(ch.op2.tl) * op2AmGain

        // Save feedback memory (op1's output history).
        ch.feedbackHistory.1 = ch.feedbackHistory.0
        ch.feedbackHistory.0 = op1Out

        // Channel volume scales the audible output, not the
        // modulator. Apply at the very end.
        let volScale = Double(ch.volume) / 64.0
        if ch.additive {
            return (op1Out + op2Out) * volScale
        }
        return op2Out * volScale
    }

    /// Render one rhythm-mode percussion voice. Five voices with
    /// different operator topologies and noise routing per the OPL2
    /// rhythm-mode spec; the noise generator (`self.noise`) is
    /// already advanced once per sample by `render`.
    private func renderPercussion(_ idx: Int) -> Double {
        var p = percussion[idx]
        defer { percussion[idx] = p }
        if !p.keyOn && p.op1.envLevel < 1e-5 && p.op2.envLevel < 1e-5 { return 0 }

        let noiseSample = Double(Int(noise & 0xFFFF) - 0x8000) / 32768.0
        let basePhaseInc = p.frequency * p.pitchFactor * 2 * .pi / sampleRate

        switch idx {
        case PercussionVoice.bassDrum.rawValue:
            // Full 2-op FM, same shape as a melodic voice.
            let op1Inc = basePhaseInc * Double(p.op1.mult)
            p.op1.phase += op1Inc
            if p.op1.phase > 2 * .pi { p.op1.phase -= 2 * .pi }
            let op1Wave = waveformSample(phase: p.op1.phase, waveform: p.op1.waveform)
            advanceEnvelope(&p.op1, keyScaleNumber: 8)
            let op1Out = op1Wave * p.op1.envLevel * tlAttenuation(p.op1.tl)

            let op2Inc = basePhaseInc * Double(p.op2.mult)
            p.op2.phase += op2Inc
            if p.op2.phase > 2 * .pi { p.op2.phase -= 2 * .pi }
            let op2Wave = waveformSample(phase: p.op2.phase + op1Out * .pi,
                                         waveform: p.op2.waveform)
            advanceEnvelope(&p.op2, keyScaleNumber: 8)
            return op2Wave * p.op2.envLevel * tlAttenuation(p.op2.tl) * Double(p.volume) / 64.0

        case PercussionVoice.snareDrum.rawValue:
            // Snare = op2 (carrier) phase-modulated by noise.
            let inc = basePhaseInc * Double(p.op1.mult)
            p.op1.phase += inc
            if p.op1.phase > 2 * .pi { p.op1.phase -= 2 * .pi }
            let noisy = noiseSample * .pi
            let s = waveformSample(phase: p.op1.phase + noisy, waveform: p.op1.waveform)
            advanceEnvelope(&p.op1, keyScaleNumber: 8)
            return s * p.op1.envLevel * tlAttenuation(p.op1.tl) * Double(p.volume) / 64.0

        case PercussionVoice.tomTom.rawValue:
            // Tom = straight modulator output (no carrier).
            let inc = basePhaseInc * Double(p.op1.mult)
            p.op1.phase += inc
            if p.op1.phase > 2 * .pi { p.op1.phase -= 2 * .pi }
            let s = waveformSample(phase: p.op1.phase, waveform: p.op1.waveform)
            advanceEnvelope(&p.op1, keyScaleNumber: 8)
            return s * p.op1.envLevel * tlAttenuation(p.op1.tl) * Double(p.volume) / 64.0

        case PercussionVoice.cymbal.rawValue:
            // Cymbal = noise + phase-modulated carrier; the spec
            // uses HH's modulator phase too, but the simpler
            // formulation below sounds metallic enough.
            let inc = basePhaseInc * Double(p.op1.mult)
            p.op1.phase += inc
            if p.op1.phase > 2 * .pi { p.op1.phase -= 2 * .pi }
            let mix = 0.5 * noiseSample + 0.5 * sin(p.op1.phase * 3)
            advanceEnvelope(&p.op1, keyScaleNumber: 8)
            return mix * p.op1.envLevel * tlAttenuation(p.op1.tl) * Double(p.volume) / 64.0

        case PercussionVoice.hiHat.rawValue:
            // Hi-hat = mostly noise tinted by the modulator phase.
            let inc = basePhaseInc * Double(p.op1.mult)
            p.op1.phase += inc
            if p.op1.phase > 2 * .pi { p.op1.phase -= 2 * .pi }
            let mix = 0.85 * noiseSample + 0.15 * sin(p.op1.phase * 5)
            advanceEnvelope(&p.op1, keyScaleNumber: 8)
            return mix * p.op1.envLevel * tlAttenuation(p.op1.tl) * Double(p.volume) / 64.0

        default:
            return 0
        }
    }

    private func amModulation() -> Double {
        // Triangle approximation of the AM LFO (Yamaha uses an
        // 8-step ramp; sin is close enough at audio rates).
        let s = (1 - cos(amPhase)) * 0.5   // [0, 1]
        return s * Self.amDepth
    }

    private func vibModulation() -> Double {
        // Sin-based VIB LFO returns a signed factor in
        // [-vibDepth, +vibDepth]; voices with the VIB bit multiply
        // their phase increment by `(1 + this)`.
        return sin(vibPhase) * Self.vibDepth
    }

    private static let feedbackScale: [Double] = {
        // OPL2's feedback bits 1..7 map to roughly π * 2^(fb-1) /
        // ((2^7) * something). We approximate with a 7-step
        // geometric table chosen to sound right at fb=7 (strong
        // self-modulation) without clipping at fb=1.
        var arr = [Double](repeating: 0, count: 8)
        for i in 1...7 {
            arr[i] = .pi / pow(2.0, Double(8 - i))
        }
        return arr
    }()

    /// Effective envelope rate after KSR scaling. OPL2 scales the
    /// rate by adding part of the key-scale number to it, then
    /// clamps to 0..63. The exact OPL2 formula is
    /// `effective = 4 * rate + (KSR ? ksn : ksn >> 2)`; we follow
    /// it directly. Returns 0 when `rate == 0` so the envelope
    /// stalls (Yamaha behavior).
    private func effectiveRate(_ rate: Int, ksr: Bool, ksn: Int) -> Int {
        if rate == 0 { return 0 }
        let offset = ksr ? ksn : (ksn >> 2)
        return min(63, 4 * rate + offset)
    }

    /// Envelope step per output sample, derived from a Yamaha-style
    /// rate table. Each rate doubles the step every 4 rate units,
    /// matching the documented OPL2 EG clock dividers within a
    /// few percent. The 49716 Hz reference is the chip's nominal
    /// envelope-generator clock; we scale through `sampleRate` so
    /// the perceived envelope timing is rate-invariant.
    private func envelopeStep(forRate r: Int) -> Double {
        if r <= 0 { return 0 }
        let yamahaClockHz = 49716.0
        let stepsPerSecond = yamahaClockHz * pow(2.0, Double(r) / 4.0) / 32768.0
        return stepsPerSecond / sampleRate
    }

    private func advanceEnvelope(_ op: inout Operator, keyScaleNumber ksn: Int) {
        switch op.stage {
        case .off:
            op.envLevel = 0
        case .attack:
            let r = effectiveRate(op.ar, ksr: op.ksr, ksn: ksn)
            // Attack on real OPL2 is exponential — increment slows
            // as we approach 1.0. The (1 - envLevel) factor gives
            // that shape without a per-rate LUT.
            op.envLevel += envelopeStep(forRate: r) * (1.001 - op.envLevel) * 8
            if op.envLevel >= 1 {
                op.envLevel = 1
                op.stage = .decay
            }
        case .decay:
            let sustainLevel = max(0, 1.0 - Double(op.sl) / 15.0)
            let r = effectiveRate(op.dr, ksr: op.ksr, ksn: ksn)
            op.envLevel -= envelopeStep(forRate: r)
            if op.envLevel <= sustainLevel {
                op.envLevel = sustainLevel
                op.stage = op.egt ? .sustain : .release
            }
        case .sustain:
            break
        case .release:
            let r = effectiveRate(op.rr, ksr: op.ksr, ksn: ksn)
            op.envLevel -= envelopeStep(forRate: r)
            if op.envLevel <= 0 {
                op.envLevel = 0
                op.stage = .off
            }
        }
    }

    /// TL is 6-bit, 0.75dB-per-step attenuation. TL=0 means full
    /// amplitude, TL=63 is roughly -47dB (near silent).
    private func tlAttenuation(_ tl: Int) -> Double {
        pow(10.0, -Double(tl) * 0.75 / 20.0)
    }
}
