import Foundation
import SotoS3
import XCTest
@testable import App

/// The S3 blob store against a real S3 API (MinIO or versitygw). Set OPENGARMIN_TEST_S3_ENDPOINT, _BUCKET, _ACCESS_KEY,
/// _SECRET_KEY and optionally _REGION. The bucket is created when missing. Without the endpoint the test is skipped.
final class S3BlobStoreTests: XCTestCase {
    func testPutExistsGetAgainstS3() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["OPENGARMIN_TEST_S3_ENDPOINT"] else {
            throw XCTSkip("Set OPENGARMIN_TEST_S3_ENDPOINT (and _BUCKET, _ACCESS_KEY, _SECRET_KEY) to test the S3 store.")
        }
        let bucket = environment["OPENGARMIN_TEST_S3_BUCKET"] ?? "opengarmin-test"
        let client = AWSClient(credentialProvider: .static(
            accessKeyId: environment["OPENGARMIN_TEST_S3_ACCESS_KEY"] ?? "",
            secretAccessKey: environment["OPENGARMIN_TEST_S3_SECRET_KEY"] ?? ""
        ))
        do {
            let service = S3(client: client, region: .init(rawValue: environment["OPENGARMIN_TEST_S3_REGION"] ?? "us-east-1"),
                             endpoint: endpoint)
            _ = try? await service.createBucket(S3.CreateBucketRequest(bucket: bucket))
            let store = S3BlobStore(service: service, bucket: bucket)

            let bytes = Data("fit bytes \(UUID().uuidString)".utf8)
            let key = BlobKey.fit(sha256: ContentHash.sha256Hex(bytes))
            let missing = try await store.exists(key)
            XCTAssertFalse(missing)
            try await store.put(key, bytes)
            let present = try await store.exists(key)
            XCTAssertTrue(present)
            let read = try await store.get(key)
            XCTAssertEqual(read, bytes)
            let absent = try await store.get("fit/00/\(UUID().uuidString).fit")
            XCTAssertNil(absent)
        } catch {
            try? await client.shutdown()
            throw error
        }
        try await client.shutdown()
    }
}
