import CZlib
import Foundation

/// gzip for archived Connect responses. Foundation on Linux has no gzip, so this calls the system zlib.
enum Gzip {
    enum Failure: Error {
        case zlib(Int32)
    }

    static func compress(_ data: Data) throws -> Data {
        var stream = z_stream()
        // windowBits 15 + 16 writes a gzip header and trailer.
        let started = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                                    ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard started == Z_OK else { throw Failure.zlib(started) }
        defer { deflateEnd(&stream) }

        var input = [UInt8](data)
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        try input.withUnsafeMutableBufferPointer { source in
            stream.next_in = source.baseAddress
            stream.avail_in = uInt(source.count)
            var status: Int32 = Z_OK
            repeat {
                try chunk.withUnsafeMutableBufferPointer { target in
                    stream.next_out = target.baseAddress
                    stream.avail_out = uInt(target.count)
                    status = deflate(&stream, Z_FINISH)
                    output.append(target.baseAddress!, count: target.count - Int(stream.avail_out))
                }
            } while status == Z_OK
            guard status == Z_STREAM_END else { throw Failure.zlib(status) }
        }
        return output
    }

    static func decompress(_ data: Data) throws -> Data {
        var stream = z_stream()
        let started = inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard started == Z_OK else { throw Failure.zlib(started) }
        defer { inflateEnd(&stream) }

        var input = [UInt8](data)
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        try input.withUnsafeMutableBufferPointer { source in
            stream.next_in = source.baseAddress
            stream.avail_in = uInt(source.count)
            var status: Int32 = Z_OK
            while status != Z_STREAM_END {
                try chunk.withUnsafeMutableBufferPointer { target in
                    stream.next_out = target.baseAddress
                    stream.avail_out = uInt(target.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    output.append(target.baseAddress!, count: target.count - Int(stream.avail_out))
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw Failure.zlib(status) }
            }
        }
        return output
    }
}
