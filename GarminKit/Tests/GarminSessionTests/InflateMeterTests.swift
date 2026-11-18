import Foundation
import Testing
@testable import GarminSession

@Test func inflateMeterCountsTheUncompressedBytesOfAChunkedZlibStream() throws {
    // 40 000 bytes of mildly repetitive data, compressed as the watch sends it: zlib header, then raw deflate.
    let original = Data((0..<40_000).map { UInt8(($0 * 7 + $0 / 13) % 251) })
    let deflate = try (original as NSData).compressed(using: .zlib) as Data
    let stream = Data([0x78, 0x9C]) + deflate

    let meter = InflateMeter()
    var reports: [Int] = []
    // One byte first, so the two-byte header is split across chunks, then BLE-sized pieces.
    var offset = 0
    for size in [1] + Array(repeating: 244, count: stream.count / 244 + 1) where offset < stream.count {
        let end = min(offset + size, stream.count)
        if let inflated = meter.feed(stream.subdata(in: offset..<end)) { reports.append(inflated) }
        offset = end
    }
    #expect(reports == reports.sorted())
    #expect(reports.contains { $0 > 0 && $0 < original.count }, "progress is reported before the end")
    // Nothing is held back: once the last chunk is in, the meter has the file's full size.
    #expect(reports.last == original.count)
}
