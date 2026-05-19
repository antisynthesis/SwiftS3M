import Testing
import Foundation
@testable import SwiftS3M

@Suite("S3MMixer")
struct S3MMixerTests {

    @Test("Renders silence into the provided buffer for an empty module")
    func rendersSilenceWithoutCrashing() throws {
        let data = makeEmptyModule()
        let file = try S3MFile(data: data)
        let mixer = S3MMixer(file: file, sampleRate: 44_100)

        let frames = 256
        var buffer = [Float](repeating: 1.0, count: frames * 2)
        buffer.withUnsafeMutableBufferPointer { ptr in
            _ = mixer.render(into: ptr.baseAddress!, frames: frames)
        }

        // With no instruments and no patterns, every output frame
        // should be silence — the mixer should have zeroed the
        // buffer even though the input was pre-filled with 1.0.
        #expect(buffer.allSatisfy { $0 == 0 })
    }

    @Test("Reports finished after the order list is exhausted")
    func finishesEmptyOrderList() throws {
        let data = makeEmptyModule()
        let file = try S3MFile(data: data)
        let mixer = S3MMixer(file: file, sampleRate: 44_100)

        // Render a buffer larger than one tick to force at least
        // one `advanceTick` cycle. The first row trigger sees an
        // empty order list and trips `finished`.
        let frames = 8_192
        var buffer = [Float](repeating: 0, count: frames * 2)
        let written = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
            mixer.render(into: ptr.baseAddress!, frames: frames)
        }

        #expect(mixer.finished)
        #expect(written <= frames)
    }

    @Test("Honors the requested sample rate")
    func samplerate() throws {
        let data = makeEmptyModule()
        let file = try S3MFile(data: data)
        let mixer = S3MMixer(file: file, sampleRate: 48_000)
        #expect(mixer.sampleRate == 48_000)
    }
}

/// Same minimal S3M scaffold the parser tests use — 0x60-byte
/// header with no orders, instruments, or patterns.
private func makeEmptyModule() -> Data {
    var data = Data(repeating: 0, count: 0x60)
    data[0x1C] = 0x1A
    data[0x1D] = 0x10
    data[0x2A] = 0x02
    data[0x2C] = 0x53
    data[0x2D] = 0x43
    data[0x2E] = 0x52
    data[0x2F] = 0x4D
    data[0x30] = 64
    data[0x31] = 6
    data[0x32] = 125
    data[0x33] = 48
    for i in 0..<16 { data[0x40 + i] = 0x00 }
    for i in 16..<32 { data[0x40 + i] = 0xFF }
    return data
}
