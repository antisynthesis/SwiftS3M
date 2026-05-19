import Testing
import Foundation
@testable import SwiftS3M

/// Tests for the parser entry points. We don't ship a binary test
/// fixture — instead each test composes a synthetic byte stream
/// matching the spec, which keeps the test suite hermetic and lets
/// reviewers see exactly what's being asserted.
@Suite("S3MFile parser")
struct S3MFileTests {

    @Test("Rejects input shorter than the fixed header")
    func tooShort() throws {
        let data = Data([0x00, 0x01, 0x02])
        #expect(throws: S3MError.tooShort) {
            _ = try S3MFile(data: data)
        }
    }

    @Test("Rejects input missing the SCRM signature")
    func badSignature() throws {
        var data = Data(repeating: 0, count: 0x60)
        // Deliberately wrong bytes at the signature offset.
        data[0x2C] = 0x41  // 'A'
        data[0x2D] = 0x42  // 'B'
        data[0x2E] = 0x43  // 'C'
        data[0x2F] = 0x44  // 'D'
        #expect(throws: S3MError.badSignature) {
            _ = try S3MFile(data: data)
        }
    }

    @Test("Parses a minimal valid header")
    func minimalHeader() throws {
        let data = makeMinimalS3M(title: "HELLO")
        let file = try S3MFile(data: data)
        #expect(file.title == "HELLO")
        #expect(file.orderCount == 0)
        #expect(file.instrumentCount == 0)
        #expect(file.patternCount == 0)
        #expect(file.initialSpeed == 6)
        #expect(file.initialTempo == 125)
        #expect(file.channelEnabled.count == 32)
    }

    @Test("Truncates the title at the DOS EOF marker")
    func titleTruncation() throws {
        // "HI" + 0x1A + garbage past the EOF marker should yield "HI".
        var data = makeMinimalS3M(title: "")
        data[0] = 0x48 // H
        data[1] = 0x49 // I
        data[2] = 0x1A // DOS EOF
        data[3] = 0x4A // 'J' — should be ignored
        let file = try S3MFile(data: data)
        #expect(file.title == "HI")
    }

    @Test("Honors the initial speed and tempo when non-zero")
    func customTiming() throws {
        var data = makeMinimalS3M(title: "T")
        data[0x31] = 4    // speed
        data[0x32] = 150  // tempo
        let file = try S3MFile(data: data)
        #expect(file.initialSpeed == 4)
        #expect(file.initialTempo == 150)
    }
}

/// Compose a syntactically valid (if musically empty) S3M file.
///
/// Layout: 0x60-byte header followed by no orders/instruments/patterns.
/// The SCRM signature, file type, EOF marker, and default speed/tempo
/// are all set so the parser walks the header without complaining.
private func makeMinimalS3M(title: String) -> Data {
    var data = Data(repeating: 0, count: 0x60)
    // Title (28 bytes, ASCII, NUL-padded).
    let titleBytes = Array(title.utf8).prefix(28)
    for (i, b) in titleBytes.enumerated() {
        data[i] = b
    }
    data[0x1C] = 0x1A    // DOS EOF
    data[0x1D] = 0x10    // ScreamTracker module
    // OrderCount / InsCount / PatCount = 0 (already zeroed).
    data[0x2A] = 0x02    // unsigned samples
    data[0x2C] = 0x53    // 'S'
    data[0x2D] = 0x43    // 'C'
    data[0x2E] = 0x52    // 'R'
    data[0x2F] = 0x4D    // 'M'
    data[0x30] = 64      // global volume
    data[0x31] = 6       // initial speed
    data[0x32] = 125     // initial tempo
    data[0x33] = 48      // master volume
    // Channel settings — leave first 16 enabled, rest disabled.
    for i in 0..<16 { data[0x40 + i] = 0x00 }
    for i in 16..<32 { data[0x40 + i] = 0xFF }
    return data
}
