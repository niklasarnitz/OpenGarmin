import Testing
import Foundation
@testable import GarminCore

@Test func cobsEncodesGarminFramingVectors() {
    #expect(Cobs.encode(Data([0x41])) == Data([0x00, 0x02, 0x41, 0x00]))
    #expect(Cobs.encode(Data()) == Data([0x00, 0x00]))
    #expect(Cobs.encode(Data([0x00])) == Data([0x00, 0x01, 0x01, 0x00]))
    #expect(Cobs.encode(Data([0x41, 0x00])) == Data([0x00, 0x02, 0x41, 0x01, 0x00]))
    #expect(Cobs.encode(Data([0x00, 0x41])) == Data([0x00, 0x01, 0x02, 0x41, 0x00]))
}

@Test func cobsSplitsRunsAt254And255NonZeroBytes() {
    let run254 = Data(repeating: 0x41, count: 254)
    #expect(Cobs.encode(run254) == Data([0x00, 0xFF] + Array(run254) + [0x01, 0x00]))

    let run255 = Data(repeating: 0x41, count: 255)
    #expect(Cobs.encode(run255) == Data([0x00, 0xFF] + Array(run255.prefix(254)) + [0x02, 0x41, 0x00]))
}

@Test func cobsRoundTripsEdgeCases() {
    let inputs: [Data] = [
        Data([0x00]),
        Data([0x00, 0x00, 0x00]),
        Data([0x00] + Array(repeating: 0x41, count: 254) + [0x00]),
        Data(repeating: 0x41, count: 253),
        Data(repeating: 0x41, count: 254),
        Data(repeating: 0x41, count: 255),
        Data(repeating: 0x41, count: 508) + Data([0x00]),
        Data((0...255).map { UInt8($0) }),
        Data([0x13, 0x00, 0x00, 0x7F, 0x00]),
    ]
    for input in inputs {
        let encoded = Cobs.encode(input)
        #expect(Cobs.decode(encoded) == input)
        var decoder = CobsDecoder()
        #expect(decoder.feed(encoded) == [input])
    }
}

@Test func cobsDecodesHandWrittenFrame() {
    #expect(Cobs.decode(Data([0x00, 0x02, 0x41, 0x01, 0x00])) == Data([0x41, 0x00]))
}

@Test func decoderHandlesFramesFedByteByByte() {
    let stream = Cobs.encode(Data([0x01, 0x00, 0x02])) + Cobs.encode(Data([0x42]))
    var decoder = CobsDecoder()
    var frames: [Data] = []
    for byte in stream { frames += decoder.feed(Data([byte])) }
    #expect(frames == [Data([0x01, 0x00, 0x02]), Data([0x42])])
}

@Test func decoderReturnsEveryFrameInOneChunk() {
    let stream = Cobs.encode(Data([0x41])) + Cobs.encode(Data([0x42, 0x00]))
    var decoder = CobsDecoder()
    #expect(decoder.feed(stream) == [Data([0x41]), Data([0x42, 0x00])])
}

@Test func decoderSkipsGarbageBeforeFrame() {
    var decoder = CobsDecoder()
    #expect(decoder.feed(Data([0x13, 0x77]) + Cobs.encode(Data([0x41]))) == [Data([0x41])])
}

@Test func decoderDropsTruncatedFrameAndResyncs() {
    // The first frame lost a notification: its code byte claims four bytes but only two arrived.
    let truncated = Data([0x00, 0x05, 0x41, 0x42, 0x00])
    var decoder = CobsDecoder()
    #expect(decoder.feed(truncated + Cobs.encode(Data([0x41]))) == [Data([0x41])])
}

@Test func decoderIgnoresEmptyFrames() {
    var decoder = CobsDecoder()
    #expect(decoder.feed(Data([0x00, 0x00, 0x00])) == [])
}
