import Crypto
import Foundation
import SotoS3

/// Raw FIT bytes, addressed by key. Keys derive from the content, so storing the same bytes twice is a no-op.
protocol BlobStore: Sendable {
    func exists(_ key: String) async throws -> Bool
    func put(_ key: String, _ data: Data) async throws
    func get(_ key: String) async throws -> Data?
}

enum BlobKey {
    /// `fit/ab/abcdef….fit`, where the directory is the first two hex digits of the SHA-256.
    static func fit(sha256: String) -> String {
        "fit/\(sha256.prefix(2))/\(sha256).fit"
    }
}

enum ContentHash {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Files under `OPENGARMIN_DATA_DIR`. Used when no S3 endpoint is configured.
struct FileSystemBlobStore: BlobStore {
    let root: URL

    private func url(_ key: String) -> URL {
        root.appendingPathComponent(key)
    }

    func exists(_ key: String) async throws -> Bool {
        FileManager.default.fileExists(atPath: url(key).path)
    }

    func put(_ key: String, _ data: Data) async throws {
        let file = url(key)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    func get(_ key: String) async throws -> Data? {
        try? Data(contentsOf: url(key))
    }
}

/// An S3 bucket, addressed path-style so self-hosted stores (versitygw, MinIO) work.
struct S3BlobStore: BlobStore {
    let service: S3
    let bucket: String

    func exists(_ key: String) async throws -> Bool {
        do {
            _ = try await service.headObject(S3.HeadObjectRequest(bucket: bucket, key: key))
            return true
        } catch {
            if isNotFound(error) { return false }
            throw error
        }
    }

    func put(_ key: String, _ data: Data) async throws {
        _ = try await service.putObject(S3.PutObjectRequest(
            body: AWSHTTPBody(bytes: data),
            bucket: bucket,
            contentType: "application/octet-stream",
            key: key
        ))
    }

    func get(_ key: String) async throws -> Data? {
        do {
            let output = try await service.getObject(S3.GetObjectRequest(bucket: bucket, key: key))
            let buffer = try await output.body.collect(upTo: 1 << 31)
            return Data(buffer.readableBytesView)
        } catch {
            if isNotFound(error) { return nil }
            throw error
        }
    }

    /// A missing key is a 404. Soto reports it as a typed error when the response has a body, and as a raw error
    /// otherwise (HEAD responses have no body).
    private func isNotFound(_ error: Error) -> Bool {
        if let raw = error as? AWSRawError { return raw.context.responseCode == .notFound }
        if let typed = error as? AWSErrorType { return typed.context?.responseCode == .notFound }
        return false
    }
}
