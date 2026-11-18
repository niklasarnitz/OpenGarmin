import Foundation
import Testing
import GarminModels
@testable import GarminBackend

private let base = "https://opengarmin.example"

/// Answers the requests a client sends, and keeps them for the test to check.
private actor FakeServer {
    private(set) var requests: [URLRequest] = []
    private let respond: @Sendable (URLRequest) -> (status: Int, body: Data)

    init(respond: @escaping @Sendable (URLRequest) -> (status: Int, body: Data)) {
        self.respond = respond
    }

    func answer(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

private func body(_ request: URLRequest) -> String {
    String(decoding: request.httpBody ?? Data(), as: UTF8.self)
}

private func client(_ server: FakeServer) throws -> BackendClient {
    try BackendClient(server: base, token: "TOK") { request in await server.answer(request) }
}

@Suite struct BackendRequestTests {
    @Test func registerPostsTheCredentialsAsJSONWithoutAToken() throws {
        let request = try BackendRequests.register(URL(string: base)!, email: "a@b.c", password: "pw")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://opengarmin.example/api/v1/auth/register")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: String]
        #expect(body == ["email": "a@b.c", "password": "pw"])
    }

    @Test func callsWithATokenSendTheBearerHeader() {
        let request = BackendRequests.me(URL(string: base)!, token: "TOK")
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://opengarmin.example/api/v1/me")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer TOK")
    }

    @Test func fitFileIsMultipartWithKeySourceUnitAndTheRawBytes() throws {
        let bytes = Data([0x0E, 0x10, 0x00, 0xFF])
        let request = BackendRequests.fitFile(URL(string: base)!, token: "TOK", bytes: bytes, key: "3-connect-42",
                                              source: .connect, deviceUnit: 3, boundary: "BOUND")
        #expect(request.url?.absoluteString == "https://opengarmin.example/api/v1/fit-files")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BOUND")
        let body = try #require(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("name=\"key\"\r\n\r\n3-connect-42\r\n"))
        #expect(text.contains("name=\"source\"\r\n\r\nconnect\r\n"))
        #expect(text.contains("name=\"deviceUnit\"\r\n\r\n3\r\n"))
        #expect(text.contains("filename=\"3-connect-42.fit\""))
        #expect(text.hasSuffix("--BOUND--\r\n"))
        #expect(body.range(of: bytes) != nil)
    }

    @Test func fitFileWithoutAUnitOmitsTheField() {
        let request = BackendRequests.fitFile(URL(string: base)!, token: nil, bytes: Data(), key: "k",
                                              source: .watch, deviceUnit: nil, boundary: "B")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(!String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("deviceUnit"))
    }

    @Test func batchDatesGoOutAsISO8601() throws {
        var batch = HealthBatch()
        batch.stress = [PointSample(date: Date(timeIntervalSince1970: 1_767_225_600), value: 30)]
        let request = try BackendRequests.batch(URL(string: base)!, token: "TOK", key: "connect-daily-1",
                                                source: .connect, batch: batch)
        #expect(request.url?.absoluteString == "https://opengarmin.example/api/v1/batches")
        let text = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(text.contains("\"2026-01-01T00:00:00Z\""))
        #expect(text.contains("\"key\":\"connect-daily-1\""))
        #expect(text.contains("\"source\":\"connect\""))
    }

    @Test func sourceIsConnectOnlyForConnectKeys() {
        #expect(BackendSource(key: "3-connect-42") == .connect)
        #expect(BackendSource(key: "connect-daily-1767225600") == .connect)
        #expect(BackendSource(key: "3-1-1700000000-2048") == .watch)
    }

    @Test func aServerURLMustBeHTTPOrHTTPS() {
        #expect(throws: BackendError.invalidServerURL) { try BackendClient(server: "ftp://example.org") }
        #expect(throws: BackendError.invalidServerURL) { try BackendClient(server: "opengarmin.example") }
    }
}

@Suite struct BackendResponseTests {
    @Test func loginReadsTheSessionToken() async throws {
        let server = FakeServer { _ in
            (200, Data(#"{"token":"TOK","user":{"id":"u1","email":"a@b.c","createdAt":"2026-01-01T00:00:00Z"}}"#.utf8))
        }
        let session = try await client(server).login(email: "a@b.c", password: "pw")
        #expect(session == BackendSession(token: "TOK", user: BackendUser(email: "a@b.c")))
    }

    @Test func syncStateReadsTheKeys() async throws {
        let server = FakeServer { _ in (200, Data(#"{"keys":["3-1-100-3","connect-daily-5"]}"#.utf8)) }
        #expect(try await client(server).syncState() == ["3-1-100-3", "connect-daily-5"])
    }

    @Test func unauthorizedAnswerAsksForASignInAgain() async throws {
        let server = FakeServer { _ in (401, Data()) }
        await #expect(throws: BackendError.unauthorized) { try await client(server).me() }
    }

    @Test func otherErrorStatusesKeepTheirCode() async throws {
        let server = FakeServer { _ in (500, Data()) }
        await #expect(throws: BackendError.http(500)) { try await client(server).me() }
        let forbidden = FakeServer { _ in (403, Data()) }
        await #expect(throws: BackendError.http(403)) { try await client(forbidden).me() }
    }

    @Test func aRefusalCarriesTheServersReason() async throws {
        let server = FakeServer { _ in (400, Data(#"{"error":true,"reason":"Bad FIT"}"#.utf8)) }
        await #expect(throws: BackendError.rejected(status: 400, message: "Bad FIT")) { try await client(server).me() }
        let plain = FakeServer { _ in (422, Data("oops".utf8)) }
        await #expect(throws: BackendError.rejected(status: 422, message: "HTTP 422")) { try await client(plain).me() }
    }

    @Test func aBodyTheAppDoesNotUnderstandIsMalformed() async throws {
        let server = FakeServer { _ in (200, Data("not json".utf8)) }
        await #expect(throws: BackendError.malformedResponse) { try await client(server).me() }
    }
}

@Suite struct BackendUploaderTests {
    /// A folder like the app's Application Support folder: two FIT files and one batch, none of them on the server yet.
    private func makeFolder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appending(path: "FIT"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appending(path: "Batches"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: directory.appending(path: "FIT/3-1-100-3.fit"))
        try Data([4, 5]).write(to: directory.appending(path: "FIT/3-connect-7.fit"))
        var batch = HealthBatch()
        batch.stress = [PointSample(date: Date(timeIntervalSince1970: 1_767_225_600), value: 30)]
        try JSONEncoder().encode(batch).write(to: directory.appending(path: "Batches/connect-daily-1.json"))
        return directory
    }

    @Test func uploadsOnlyWhatTheServerLacks() async throws {
        let server = FakeServer { request in
            request.url?.path == "/api/v1/sync/state" ? (200, Data(#"{"keys":["3-connect-7"]}"#.utf8)) : (200, Data("{}".utf8))
        }
        let report = await BackendUploader.run(directory: try makeFolder(), client: try client(server))

        #expect(report == UploadReport(uploaded: 2, pending: 0, failure: nil))
        let uploads = await server.requests.filter { $0.httpMethod == "POST" }
        #expect(uploads.map { $0.url?.path } == ["/api/v1/fit-files", "/api/v1/batches"])
        let fitBody = String(decoding: uploads[0].httpBody ?? Data(), as: UTF8.self)
        #expect(fitBody.contains("name=\"key\"\r\n\r\n3-1-100-3\r\n"))
        #expect(fitBody.contains("name=\"deviceUnit\"\r\n\r\n3\r\n"))
        let batchBody = String(decoding: uploads[1].httpBody ?? Data(), as: UTF8.self)
        #expect(batchBody.contains("\"key\":\"connect-daily-1\""))
        #expect(batchBody.contains("\"source\":\"connect\""))
    }

    @Test func aFailureStopsTheRunAndLeavesTheRestPending() async throws {
        let server = FakeServer { request in
            request.url?.path == "/api/v1/sync/state" ? (200, Data(#"{"keys":[]}"#.utf8)) : (500, Data())
        }
        let report = await BackendUploader.run(directory: try makeFolder(), client: try client(server))

        #expect(report == UploadReport(uploaded: 0, pending: 3, failure: .http(500)))
        let uploads = await server.requests.filter { $0.httpMethod == "POST" }
        #expect(uploads.count == 1)
    }

    @Test func aRefusedFileIsSkippedAndTheRunContinues() async throws {
        let server = FakeServer { request in
            if request.url?.path == "/api/v1/sync/state" { return (200, Data(#"{"keys":[]}"#.utf8)) }
            if body(request).contains("3-1-100-3") { return (400, Data(#"{"error":true,"reason":"Bad FIT"}"#.utf8)) }
            return (200, Data("{}".utf8))
        }
        let report = await BackendUploader.run(directory: try makeFolder(), client: try client(server))

        #expect(report == UploadReport(uploaded: 2, pending: 0, rejected: ["3-1-100-3": "Bad FIT"], failure: nil))
        #expect(await server.requests.filter { $0.httpMethod == "POST" }.count == 3)
    }

    @Test func aKnownRefusalIsNotTriedAgain() async throws {
        let server = FakeServer { request in
            request.url?.path == "/api/v1/sync/state" ? (200, Data(#"{"keys":[]}"#.utf8)) : (200, Data("{}".utf8))
        }
        let report = await BackendUploader.run(directory: try makeFolder(), client: try client(server),
                                               rejected: ["3-1-100-3": "Bad FIT"])

        #expect(report == UploadReport(uploaded: 2, pending: 0, rejected: ["3-1-100-3": "Bad FIT"], failure: nil))
        let uploads = await server.requests.filter { $0.httpMethod == "POST" }
        #expect(uploads.count == 2)
        #expect(!uploads.contains { body($0).contains("3-1-100-3") })
    }

    @Test(arguments: [401, 403, 503]) func anAuthorizationOrServerErrorStopsTheRun(status: Int) async throws {
        let server = FakeServer { request in
            request.url?.path == "/api/v1/sync/state" ? (200, Data(#"{"keys":[]}"#.utf8)) : (status, Data())
        }
        let report = await BackendUploader.run(directory: try makeFolder(), client: try client(server))

        let expected: BackendError = status == 401 ? .unauthorized : .http(status)
        #expect(report == UploadReport(uploaded: 0, pending: 3, failure: expected))
        #expect(await server.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test func aStopKeepsTheKnownRefusals() async throws {
        let server = FakeServer { request in
            request.url?.path == "/api/v1/sync/state" ? (200, Data(#"{"keys":[]}"#.utf8)) : (500, Data())
        }
        let report = await BackendUploader.run(directory: try makeFolder(), client: try client(server),
                                               rejected: ["3-1-100-3": "Bad FIT"])

        #expect(report == UploadReport(uploaded: 0, pending: 2, rejected: ["3-1-100-3": "Bad FIT"], failure: .http(500)))
    }
}
