/// S3MFile.swift
///
/// Parser for Scream Tracker 3 (.s3m) module files. Reads the binary
/// layout into Swift structs the mixer can run against. Spec
/// references: the original "Scream Tracker 3.21 Technical
/// Documentation" (S3M.TXT) by Sami Tammilehto, plus the OpenMPT
/// community's documentation.
///
/// ## File layout (relevant fields)
///
/// ```
/// 0x00  28 bytes   Song title (ASCIIZ-ish, 0x00 or 0x1A padding)
/// 0x1C   1 byte    0x1A — DOS EOF marker
/// 0x1D   1 byte    File type (0x10 = ScreamTracker module)
/// 0x1E   2 bytes   Reserved
/// 0x20   2 bytes   OrderCount (number of orders in the order list)
/// 0x22   2 bytes   InsCount (number of instruments)
/// 0x24   2 bytes   PatCount (number of patterns)
/// 0x26   2 bytes   Flags
/// 0x28   2 bytes   Created with tracker version
/// 0x2A   2 bytes   File format info (1 = signed samples, 2 = unsigned)
/// 0x2C   4 bytes   "SCRM" signature
/// 0x30   1 byte    Global volume (0..64)
/// 0x31   1 byte    Initial speed (1..255, ticks per row)
/// 0x32   1 byte    Initial tempo (32..255, BPM-ish)
/// 0x33   1 byte    Master volume (bit 7 = stereo)
/// 0x34   1 byte    Ultra-click removal
/// 0x35   1 byte    Default panning flag (252 = use default panning)
/// 0x36   8 bytes   Reserved
/// 0x3E   2 bytes   Special parapointer
/// 0x40  32 bytes   Channel settings (0..0x7F enabled, 0xFF disabled)
/// 0x60+ OrderCount bytes  Order list (each = pattern index, 0xFE = +++, 0xFF = ---)
/// (then) InsCount × 16-bit parapointers
/// (then) PatCount × 16-bit parapointers
/// (then) 32 bytes default panning (if flag = 252)
/// ```
///
/// Parapointer = `UInt16` little-endian, multiplied by 16 to get
/// the file offset.

import Foundation

public struct S3MFile: Sendable {

    // MARK: - Header

    public let title: String
    public let orderCount: Int
    public let instrumentCount: Int
    public let patternCount: Int
    public let globalVolume: UInt8
    public let initialSpeed: UInt8
    public let initialTempo: UInt8
    public let masterVolume: UInt8
    public let signedSamples: Bool

    /// Per-channel enable mask (32 entries). Disabled channels are
    /// skipped by the mixer.
    public let channelEnabled: [Bool]

    /// Number of channels actively enabled in `channelEnabled` —
    /// the mixer's voice count.
    public var activeChannelCount: Int { channelEnabled.filter { $0 }.count }

    // Module-internal: the mixer consumes these directly.
    let channelPanning: [UInt8]
    let orders: [UInt8]
    let instruments: [S3MInstrument]
    let patterns: [S3MPattern]

    // MARK: - Init / parse

    public init(data: Data) throws {
        guard data.count >= 0x60 else { throw S3MError.tooShort }

        // SCRM signature check.
        let sig = data.subdata(in: 0x2C..<0x30)
        guard sig == Data([0x53, 0x43, 0x52, 0x4D]) else {
            throw S3MError.badSignature
        }

        title = Self.readString(data, range: 0x00..<0x1C)
        orderCount = Int(data.readUInt16LE(at: 0x20))
        instrumentCount = Int(data.readUInt16LE(at: 0x22))
        patternCount = Int(data.readUInt16LE(at: 0x24))
        globalVolume = data[0x30]
        initialSpeed = data[0x31]
        initialTempo = data[0x32]
        masterVolume = data[0x33]
        signedSamples = data.readUInt16LE(at: 0x2A) == 1

        // Channel settings (32 bytes). 0x00..0x07 = left side enabled,
        // 0x08..0x0F = right side enabled, anything else = disabled.
        var enabled = [Bool](repeating: false, count: 32)
        for i in 0..<32 {
            let v = data[0x40 + i]
            enabled[i] = v < 0x10
        }
        channelEnabled = enabled

        // Order list (sized `orderCount`, follows header).
        var orderList: [UInt8] = []
        for i in 0..<orderCount {
            let offset = 0x60 + i
            guard offset < data.count else { break }
            orderList.append(data[offset])
        }
        orders = orderList

        // Instrument parapointers — `instrumentCount` × UInt16,
        // immediately after the order list.
        let insPtrBase = 0x60 + orderCount
        var insPtrs: [Int] = []
        for i in 0..<instrumentCount {
            let p = Int(data.readUInt16LE(at: insPtrBase + i * 2))
            insPtrs.append(p * 16)
        }

        // Pattern parapointers — `patternCount` × UInt16, right
        // after the instrument parapointer table.
        let patPtrBase = insPtrBase + instrumentCount * 2
        var patPtrs: [Int] = []
        for i in 0..<patternCount {
            let p = Int(data.readUInt16LE(at: patPtrBase + i * 2))
            patPtrs.append(p * 16)
        }

        // Default panning — if `data[0x35] == 0xFC`, 32 bytes
        // immediately follow the pattern parapointer table.
        var panning = [UInt8](repeating: 0x08, count: 32)  // center
        if data[0x35] == 0xFC {
            let panBase = patPtrBase + patternCount * 2
            for i in 0..<32 where panBase + i < data.count {
                let v = data[panBase + i]
                if v & 0x20 != 0 {
                    panning[i] = v & 0x0F
                }
            }
        }
        channelPanning = panning

        // Decode instrument headers.
        var ins: [S3MInstrument] = []
        for ptr in insPtrs {
            if ptr == 0 || ptr + 0x50 > data.count {
                ins.append(.empty)
                continue
            }
            ins.append(S3MInstrument(data: data, at: ptr, signedPCM: signedSamples))
        }
        instruments = ins

        // Decode patterns.
        var pats: [S3MPattern] = []
        for ptr in patPtrs {
            if ptr == 0 || ptr + 2 > data.count {
                pats.append(S3MPattern.empty)
                continue
            }
            pats.append(S3MPattern.decode(data: data, at: ptr))
        }
        patterns = pats
    }

    private static func readString(_ data: Data, range: Range<Int>) -> String {
        let bytes = data.subdata(in: range)
        // ASCIIZ — truncate at first 0x00 or 0x1A.
        var idx = bytes.startIndex
        while idx < bytes.endIndex {
            let b = bytes[idx]
            if b == 0x00 || b == 0x1A { break }
            idx = bytes.index(after: idx)
        }
        return String(data: bytes[bytes.startIndex..<idx], encoding: .ascii) ?? ""
    }
}

// MARK: - Errors

public enum S3MError: Error, LocalizedError, Sendable {
    case tooShort
    case badSignature

    public var errorDescription: String? {
        switch self {
        case .tooShort:     return "S3M file too short."
        case .badSignature: return "S3M signature (SCRM) not found."
        }
    }
}

// MARK: - Adlib registers

/// Raw OPL2 register bytes shipped with a type-2 (Adlib)
/// instrument. Names follow the original `S3M.TXT` field names,
/// which themselves echo the Yamaha YM3812 register addresses
/// they correspond to.
struct AdlibRegisters: Sendable, Hashable {

    /// `D00` AM / VIB / EG / KSR / MULT (modulator).
    var modChar: UInt8 = 0
    /// `D01` AM / VIB / EG / KSR / MULT (carrier).
    var carChar: UInt8 = 0
    /// `D40` KSL / TL (modulator).
    var modScale: UInt8 = 0
    /// `D41` KSL / TL (carrier).
    var carScale: UInt8 = 0
    /// `D60` AR / DR (modulator).
    var modAttack: UInt8 = 0
    /// `D61` AR / DR (carrier).
    var carAttack: UInt8 = 0
    /// `D80` SL / RR (modulator).
    var modSustain: UInt8 = 0
    /// `D81` SL / RR (carrier).
    var carSustain: UInt8 = 0
    /// `E0` waveform select (modulator). OPL3 only.
    var modWave: UInt8 = 0
    /// `E1` waveform select (carrier). OPL3 only.
    var carWave: UInt8 = 0
    /// `C0` feedback / connection (FB bits 1..3, CNT bit 0).
    var feedConnect: UInt8 = 0
}

// MARK: - Instrument

struct S3MInstrument: Sendable {

    /// Sentinel for empty instrument slots — keeps array indices
    /// aligned with the file's 1-based instrument references.
    static let empty = S3MInstrument(
        type: 0,
        name: "",
        sampleData: [],
        loopBegin: 0,
        loopEnd: 0,
        loops: false,
        bits16: false,
        stereo: false,
        defaultVolume: 64,
        c2spd: 8363,
        adlib: AdlibRegisters()
    )

    let type: UInt8         // 0=empty, 1=PCM, 2=Adlib
    let name: String
    /// PCM samples normalized to signed 16-bit, regardless of the
    /// source bit depth. Empty array for non-PCM instruments.
    let sampleData: [Int16]
    let loopBegin: Int
    let loopEnd: Int
    let loops: Bool
    let bits16: Bool
    let stereo: Bool
    let defaultVolume: UInt8
    /// Frequency at which the sample plays at its native pitch
    /// (C-4). Used to convert note → playback rate.
    let c2spd: UInt32
    /// OPL2 register bytes for type-2 (Adlib) instruments. Zero
    /// for PCM / empty instruments.
    let adlib: AdlibRegisters

    init(data: Data, at offset: Int, signedPCM: Bool) {
        let type = data[offset]
        let name = Self.readString(data, range: (offset + 0x30)..<(offset + 0x4C))
        let memseg = (Int(data[offset + 0x0D]) << 16)
                   | Int(data.readUInt16LE(at: offset + 0x0E))
        let sampleOffset = memseg * 16
        let length = Int(data.readUInt32LE(at: offset + 0x10))
        let loopBegin = Int(data.readUInt32LE(at: offset + 0x14))
        let loopEnd = Int(data.readUInt32LE(at: offset + 0x18))
        let defaultVolume = data[offset + 0x1C]
        let flags = data[offset + 0x1F]
        let c2spd = data.readUInt32LE(at: offset + 0x20)

        let loops = flags & 0x01 != 0
        let stereo = flags & 0x02 != 0
        let bits16 = flags & 0x04 != 0

        var samples: [Int16] = []
        if type == 1 && length > 0 && sampleOffset > 0 {
            samples = Self.readPCM(
                data: data,
                offset: sampleOffset,
                length: length,
                signed: signedPCM,
                bits16: bits16
            )
        }

        // Adlib (type 2) instruments stash their OPL2 register
        // bytes at fixed offsets in the instrument header.
        var adlib = AdlibRegisters()
        if type == 2 && offset + 0x1B < data.count {
            adlib.modChar     = data[offset + 0x10]
            adlib.carChar     = data[offset + 0x11]
            adlib.modScale    = data[offset + 0x12]
            adlib.carScale    = data[offset + 0x13]
            adlib.modAttack   = data[offset + 0x14]
            adlib.carAttack   = data[offset + 0x15]
            adlib.modSustain  = data[offset + 0x16]
            adlib.carSustain  = data[offset + 0x17]
            adlib.modWave     = data[offset + 0x18]
            adlib.carWave     = data[offset + 0x19]
            adlib.feedConnect = data[offset + 0x1A]
        }

        self.type = type
        self.name = name
        self.sampleData = samples
        self.loopBegin = loopBegin
        self.loopEnd = loopEnd
        self.loops = loops
        self.bits16 = bits16
        self.stereo = stereo
        self.defaultVolume = defaultVolume
        self.c2spd = c2spd
        self.adlib = adlib
    }

    private init(type: UInt8, name: String, sampleData: [Int16], loopBegin: Int,
                 loopEnd: Int, loops: Bool, bits16: Bool, stereo: Bool,
                 defaultVolume: UInt8, c2spd: UInt32, adlib: AdlibRegisters) {
        self.type = type
        self.name = name
        self.sampleData = sampleData
        self.loopBegin = loopBegin
        self.loopEnd = loopEnd
        self.loops = loops
        self.bits16 = bits16
        self.stereo = stereo
        self.defaultVolume = defaultVolume
        self.c2spd = c2spd
        self.adlib = adlib
    }

    private static func readString(_ data: Data, range: Range<Int>) -> String {
        let safe = max(0, min(range.lowerBound, data.count))..<max(0, min(range.upperBound, data.count))
        let bytes = data.subdata(in: safe)
        var idx = bytes.startIndex
        while idx < bytes.endIndex && bytes[idx] != 0 {
            idx = bytes.index(after: idx)
        }
        return String(data: bytes[bytes.startIndex..<idx], encoding: .ascii) ?? ""
    }

    /// Read raw PCM samples and return signed 16-bit.
    /// S3M historically stores unsigned 8-bit; some files use signed
    /// via the FileFormatInfo flag. 16-bit samples are always signed
    /// little-endian when the flag is set.
    private static func readPCM(
        data: Data,
        offset: Int,
        length: Int,
        signed: Bool,
        bits16: Bool
    ) -> [Int16] {
        if bits16 {
            let bytes = length * 2
            let end = min(offset + bytes, data.count)
            guard end > offset else { return [] }
            var result: [Int16] = []
            result.reserveCapacity((end - offset) / 2)
            var p = offset
            while p + 1 < end {
                let lo = UInt16(data[p])
                let hi = UInt16(data[p + 1])
                let raw = Int16(bitPattern: lo | (hi << 8))
                result.append(raw)
                p += 2
            }
            return result
        } else {
            let end = min(offset + length, data.count)
            guard end > offset else { return [] }
            var result: [Int16] = []
            result.reserveCapacity(end - offset)
            for i in offset..<end {
                if signed {
                    let raw = Int8(bitPattern: data[i])
                    result.append(Int16(raw) << 8)
                } else {
                    let raw = Int(data[i]) - 128
                    result.append(Int16(raw) << 8)
                }
            }
            return result
        }
    }
}

// MARK: - Pattern

struct S3MPattern: Sendable {

    /// One cell in the 64-row × 32-channel grid.
    struct Cell: Sendable {
        /// Encoded as `(octave << 4) | halfStep`. `0xFF` = no note,
        /// `0xFE` = key off.
        var note: UInt8 = 0xFF
        var instrument: UInt8 = 0
        var volume: UInt8 = 0xFF       // 0xFF = no volume column entry
        var command: UInt8 = 0          // 'A'..'Z' minus 0x40, or 0 for none
        var info: UInt8 = 0
    }

    /// 64 rows × 32 channels.
    let rows: [[Cell]]

    static let empty = S3MPattern(rows: Array(
        repeating: Array(repeating: Cell(), count: 32),
        count: 64
    ))

    /// Decompress the packed pattern data starting at `at` in
    /// `data`. Each row is a sequence of `(what, …payload)` tuples
    /// terminated by a `0x00` byte. `what`'s low 5 bits address the
    /// channel; bits 5/6/7 flag the presence of note+instrument,
    /// volume, and command+info respectively.
    static func decode(data: Data, at offset: Int) -> S3MPattern {
        var rows = Array(
            repeating: Array(repeating: Cell(), count: 32),
            count: 64
        )

        // Length prefix (16-bit LE) precedes the packed bytes.
        let length = Int(data.readUInt16LE(at: offset))
        let start = offset + 2
        let end = min(start + length, data.count)

        var p = start
        var row = 0
        while p < end && row < 64 {
            let what = data[p]
            p += 1
            if what == 0 {
                row += 1
                continue
            }
            let channel = Int(what & 0x1F)
            var note: UInt8 = 0xFF
            var instrument: UInt8 = 0
            var volume: UInt8 = 0xFF
            var command: UInt8 = 0
            var info: UInt8 = 0
            if what & 0x20 != 0 {
                guard p + 1 < end else { break }
                note = data[p]; p += 1
                instrument = data[p]; p += 1
            }
            if what & 0x40 != 0 {
                guard p < end else { break }
                volume = data[p]; p += 1
            }
            if what & 0x80 != 0 {
                guard p + 1 < end else { break }
                command = data[p]; p += 1
                info = data[p]; p += 1
            }
            if channel < 32 {
                rows[row][channel].note = note
                rows[row][channel].instrument = instrument
                rows[row][channel].volume = volume
                rows[row][channel].command = command
                rows[row][channel].info = info
            }
        }

        return S3MPattern(rows: rows)
    }
}

// MARK: - Data conveniences

extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        let lo = UInt16(self[offset])
        let hi = UInt16(self[offset + 1])
        return lo | (hi << 8)
    }
    func readUInt32LE(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1])
        let b2 = UInt32(self[offset + 2])
        let b3 = UInt32(self[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}
