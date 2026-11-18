import Compression
import Foundation

/// Counts how many bytes a Garmin zlib stream inflates to while it arrives, so a download can show progress against
/// the file's uncompressed size. The stream's two-byte zlib header is skipped; Compression's zlib is raw deflate.
/// Uses `compression_stream` directly because `OutputFilter` releases only one output buffer per write, which makes
/// progress trail far behind on well-compressed files.
final class InflateMeter {
    private var stream = compression_stream(dst_ptr: UnsafeMutablePointer(bitPattern: 1)!, dst_size: 0,
                                            src_ptr: UnsafePointer(bitPattern: 1)!, src_size: 0, state: nil)
    private var isOpen: Bool
    private var headerBytesLeft = 2
    private let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: InflateMeter.scratchSize)
    private(set) var inflatedBytes = 0
    private static let scratchSize = 16 * 1024

    init() {
        isOpen = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
    }

    deinit {
        if isOpen { compression_stream_destroy(&stream) }
        scratch.deallocate()
    }

    /// Feeds the next compressed bytes and returns the inflated total, or nil once the stream cannot be measured.
    func feed(_ data: Data) -> Int? {
        guard isOpen else { return nil }
        var data = data
        if headerBytesLeft > 0 {
            let skipped = min(headerBytesLeft, data.count)
            data = data.dropFirst(skipped)
            headerBytesLeft -= skipped
        }
        guard !data.isEmpty else { return inflatedBytes }
        let ok = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = raw.count
            // Drain until the input is consumed and the output buffer was not filled: then nothing is held back.
            while true {
                stream.dst_ptr = scratch
                stream.dst_size = Self.scratchSize
                let status = compression_stream_process(&stream, 0)
                inflatedBytes += Self.scratchSize - stream.dst_size
                switch status {
                case COMPRESSION_STATUS_OK:
                    if stream.src_size == 0, stream.dst_size > 0 { return true }
                case COMPRESSION_STATUS_END:
                    return true
                default:
                    return false
                }
            }
        }
        if !ok {
            compression_stream_destroy(&stream)
            isOpen = false
            return nil
        }
        return inflatedBytes
    }
}
