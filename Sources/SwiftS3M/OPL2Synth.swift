/// OPL2Synth.swift
///
/// 9-channel 2-operator FM synthesizer modeled on the Yamaha
/// YM3812 (Adlib / OPL2). S3M places its Adlib voices on channels
/// 16..24 of the channel map; this synth renders those 9 channels
/// into the same stereo float buffer the PCM mixer uses, so a
/// mixed PCM+FM module sounds coherent without the host having to
/// know which channels were which.
///
/// This is an MVP-grade emulation, not cycle-accurate. The goal is
/// "tracker S3Ms that use Adlib instruments produce recognizable
/// FM sound" rather than "passes a Nuked-OPL2 test suite." The
/// envelope model uses a continuous (not LFO-clocked) ADSR; the
/// waveform is always pure sine (OPL2 has no waveform-select bit,
/// OPL3-only `E0`/`E1` register bytes are read from the instrument
/// for round-trip preservation but currently ignored).
///
/// Per-operator state:
/// - AR / DR / SL / RR : 4-bit attack/decay/sustain/release rates
/// - TL                : 6-bit total-level attenuation (0..63, 0.75dB/step)
/// - KSL               : 2-bit key-scale level (attenuation per octave)
/// - MULT              : 4-bit frequency multiplier (Yamaha mapping)
/// - EGT (sustain bit) : if set, hold at SL after decay; else release
/// - KSR               : key-scale rate (faster envelope at higher notes)
///
/// Per-channel state:
/// - FB                : 3-bit feedback amount applied to op1 self-modulation
/// - CNT               : connection mode (0 = FM, 1 = additive)

import Foundation

final class OPL2Synth: @unchecked Sendable {

    let sampleRate: Double

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.channels = Array(repeating: Channel(), count: 9)
    }

    // MARK: - Key on / off / volume

    /// Configure operators from the instrument's OPL2 register
    /// bytes, compute the FNUM-style frequency from the note (we
    /// reuse the S3M C2SPD-based formula since we're not bound to
    /// real OPL2 FNUM/BLOCK accounting), and start both operators
    /// in their attack phase.
    func keyOn(channel idx: Int, note: UInt8, instrument: S3MInstrument, volume: Int) {
        guard idx >= 0, idx < channels.count else { return }
        var ch = channels[idx]
        configureOperator(&ch.op1, char: instrument.adlib.modChar,
                          scale: instrument.adlib.modScale,
                          attack: instrument.adlib.modAttack,
                          sustain: instrument.adlib.modSustain)
        configureOperator(&ch.op2, char: instrument.adlib.carChar,
                          scale: instrument.adlib.carScale,
                          attack: instrument.adlib.carAttack,
                          sustain: instrument.adlib.carSustain)
        let fc = instrument.adlib.feedConnect
        ch.feedback = Int((fc >> 1) & 0x07)
        ch.additive = (fc & 0x01) != 0

        let octave = Int(note >> 4)
        let halfStep = Int(note & 0x0F)
        let semis = (octave - 4) * 12 + halfStep
        ch.frequency = Double(instrument.c2spd) * pow(2.0, Double(semis) / 12.0)

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

    // MARK: - Render

    /// Mix this synth's output into `buffer` (interleaved stereo
    /// float) for `frames` samples. `mainAmp` scales by the host's
    /// global/master volume so the OPL voices balance against PCM.
    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int, mainAmp: Float) {
        for i in 0..<frames {
            var sum: Double = 0
            for c in 0..<channels.count {
                sum += renderChannel(c)
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
        /// Two-sample running average of op1's output, fed back
        /// into op1's phase next sample (standard YM3812 feedback
        /// topology).
        var feedbackHistory: (Double, Double) = (0, 0)
    }

    private var channels: [Channel]

    private func configureOperator(_ op: inout Operator,
                                   char: UInt8, scale: UInt8,
                                   attack: UInt8, sustain: UInt8) {
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

    /// Advance one frame for one channel and return its mono
    /// sample contribution in roughly the [-1, +1] band.
    private func renderChannel(_ idx: Int) -> Double {
        var ch = channels[idx]
        defer { channels[idx] = ch }

        // Idle channels save work.
        if !ch.keyOn && ch.op2.envLevel < 1e-5 && ch.op1.envLevel < 1e-5 {
            return 0
        }

        // Carrier base phase increment.
        let basePhaseInc = ch.frequency * ch.pitchFactor * 2 * .pi / sampleRate

        // Op1 (modulator) with self-feedback.
        let fb = ch.feedback == 0
            ? 0.0
            : (ch.feedbackHistory.0 + ch.feedbackHistory.1) * 0.5
              * Self.feedbackScale[ch.feedback]
        let op1Inc = basePhaseInc * Double(ch.op1.mult)
        ch.op1.phase += op1Inc
        if ch.op1.phase > 2 * .pi { ch.op1.phase -= 2 * .pi }
        let op1Sample = sin(ch.op1.phase + fb)
        advanceEnvelope(&ch.op1)
        let op1Out = op1Sample * ch.op1.envLevel * tlAttenuation(ch.op1.tl)

        // Op2 (carrier). FM mode uses op1's output as phase mod;
        // additive mode renders op2 independently.
        let op2Inc = basePhaseInc * Double(ch.op2.mult)
        ch.op2.phase += op2Inc
        if ch.op2.phase > 2 * .pi { ch.op2.phase -= 2 * .pi }
        let op2Mod = ch.additive ? 0.0 : op1Out * .pi
        let op2Sample = sin(ch.op2.phase + op2Mod)
        advanceEnvelope(&ch.op2)
        let op2Out = op2Sample * ch.op2.envLevel * tlAttenuation(ch.op2.tl)

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

    private func advanceEnvelope(_ op: inout Operator) {
        switch op.stage {
        case .off:
            op.envLevel = 0
        case .attack:
            op.envLevel += attackIncrement(rate: op.ar)
            if op.envLevel >= 1 {
                op.envLevel = 1
                op.stage = .decay
            }
        case .decay:
            let sustainLevel = max(0, 1.0 - Double(op.sl) / 15.0)
            op.envLevel -= decayIncrement(rate: op.dr)
            if op.envLevel <= sustainLevel {
                op.envLevel = sustainLevel
                op.stage = op.egt ? .sustain : .release
            }
        case .sustain:
            break
        case .release:
            op.envLevel -= releaseIncrement(rate: op.rr)
            if op.envLevel <= 0 {
                op.envLevel = 0
                op.stage = .off
            }
        }
    }

    private func attackIncrement(rate: Int) -> Double {
        if rate == 0 { return 0 }
        // Rate 15 ≈ 1 ms attack; rate 1 ≈ several seconds. Each
        // step roughly doubles the time.
        let timeMs = 1.0 * pow(2.0, Double(15 - rate))
        return 1.0 / (timeMs * sampleRate / 1000.0)
    }

    private func decayIncrement(rate: Int) -> Double {
        if rate == 0 { return 0 }
        let timeMs = 8.0 * pow(2.0, Double(15 - rate))
        return 1.0 / (timeMs * sampleRate / 1000.0)
    }

    private func releaseIncrement(rate: Int) -> Double {
        if rate == 0 { return 0 }
        let timeMs = 16.0 * pow(2.0, Double(15 - rate))
        return 1.0 / (timeMs * sampleRate / 1000.0)
    }

    /// TL is 6-bit, 0.75dB-per-step attenuation. TL=0 means full
    /// amplitude, TL=63 is roughly -47dB (near silent).
    private func tlAttenuation(_ tl: Int) -> Double {
        pow(10.0, -Double(tl) * 0.75 / 20.0)
    }
}
