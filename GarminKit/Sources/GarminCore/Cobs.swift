import Foundation

/// Garmin's COBS variant (Gadgetbridge's CobsCoDec, garmin-ble's cobs.py). Unlike standard COBS, every frame
/// starts with a leading 0x00 and ends with a trailing 0x00, and the body never contains 0x00.
public enum Cobs {
    public static func encode(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out: [UInt8] = [0]
        var start = 0
        var lastByteWasZero = false
        while start < bytes.count {
            var zero = start
            while zero < bytes.count && bytes[zero] != 0 { zero += 1 }
            lastByteWasZero = zero < bytes.count
            var length = zero - start
            while length >= 0xFE {
                out.append(0xFF)
                out.append(contentsOf: bytes[start..<start + 0xFE])
                length -= 0xFE
                start += 0xFE
            }
            out.append(UInt8(length + 1))
            out.append(contentsOf: bytes[start..<start + length])
            start = zero + 1
        }
        if lastByteWasZero { out.append(0x01) }
        out.append(0)
        return Data(out)
    }

    /// Decodes one complete frame, delimiters included. Returns nil if the body is malformed or truncated.
    public static func decode(_ frame: Data) -> Data? {
        let bytes = [UInt8](frame)
        guard bytes.count >= 2, bytes.first == 0, bytes.last == 0 else { return nil }
        let body = Array(bytes[1..<bytes.count - 1])
        var out: [UInt8] = []
        var i = 0
        while i < body.count {
            let code = Int(body[i])
            i += 1
            guard code != 0, i + code - 1 <= body.count else { return nil }
            out.append(contentsOf: body[i..<i + code - 1])
            i += code - 1
            if code != 0xFF && i < body.count { out.append(0) }
        }
        return Data(out)
    }
}

/// Incremental decoder for a byte stream: feed bytes as they arrive, get back every complete frame.
/// A frame that fails to decode is dropped, and decoding resumes at the next 0x00 byte.
public struct CobsDecoder: Sendable {
    /// Bytes of the frame in progress, starting with its leading 0x00; empty between frames.
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ data: Data) -> [Data] {
        var frames: [Data] = []
        for byte in data {
            if buffer.isEmpty {
                // Bytes before a frame start are garbage from a lost notification.
                if byte == 0 { buffer = [0] }
                continue
            }
            if byte != 0 {
                buffer.append(byte)
                continue
            }
            // A 0x00 closes the open frame and also opens the next one.
            if buffer.count > 1, let frame = Cobs.decode(Data(buffer + [0])) {
                frames.append(frame)
            }
            buffer = [0]
        }
        return frames
    }
}
