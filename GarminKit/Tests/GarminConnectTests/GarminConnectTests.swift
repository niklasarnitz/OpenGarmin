import Foundation
import Testing
import GarminModels
@testable import GarminConnect

/// The signatures are the ones oauthlib (the library garth's OAuth session uses) computes for the same inputs.
@Suite struct ConnectRequestTests {
    @Test func preauthorizedIsSignedWithTheConsumerKeyAlone() throws {
        let signer = OAuth1Signer(consumerKey: "CKEY", consumerSecret: "CSECRET", nonce: "abc123", timestamp: "1700000000")
        let request = ConnectRequests.preauthorized(ticket: "ST-1-abc", signer: signer)
        let header = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(request.httpMethod == "GET")
        #expect(header.contains("oauth_signature=\"3C1%2BzSjlCX%2B9d%2F2Q4rxuhjLUNiI%3D\""))
        #expect(!header.contains("oauth_token="))
    }

    @Test func exchangeWithMFATokenAsksForTheMobileAudience() throws {
        let token = ConnectOAuth1Token(token: "TOK", secret: "TSEC", mfaToken: "MFA1")
        let signer = OAuth1Signer(consumerKey: "CKEY", consumerSecret: "CSECRET", token: "TOK", tokenSecret: "TSEC",
                                  nonce: "def456", timestamp: "1700000001")
        let request = ConnectRequests.exchange(oauth1: token, signer: signer, login: true)
        let header = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(request.httpMethod == "POST")
        #expect(header.contains("oauth_signature=\"Wo2DgjXnkLuAKKXMhLntT4GRxok%3D\""))
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body == "audience=GARMIN_CONNECT_MOBILE_ANDROID_DI&mfa_token=MFA1")
    }

    @Test func refreshSendsNoAudience() throws {
        let token = ConnectOAuth1Token(token: "TOK", secret: "TSEC", mfaToken: "MFA1")
        let signer = OAuth1Signer(consumerKey: "CKEY", consumerSecret: "CSECRET", token: "TOK", tokenSecret: "TSEC")
        let request = ConnectRequests.exchange(oauth1: token, signer: signer, login: false)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body == "mfa_token=MFA1")
    }

    @Test func dayIsTheCalendarDayInTheGivenZone() {
        // 2026-03-04 23:30 UTC is already 2026-03-05 in Berlin (UTC+1 in March).
        let date = Date(timeIntervalSince1970: 1_772_667_000)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        #expect(ConnectRequests.day(date, calendar: utc) == "2026-03-04")
        #expect(ConnectRequests.day(date, calendar: berlin) == "2026-03-05")
    }
}

@Suite struct ConnectParsingTests {
    @Test func ssoReadsTicketMFAAndRejection() throws {
        let ticket = Data(#"{"responseStatus":{"type":"SUCCESSFUL"},"serviceTicketId":"ST-1"}"#.utf8)
        #expect(try ConnectParsing.sso(ticket) == .ticket("ST-1"))
        let mfa = Data(#"{"responseStatus":{"type":"MFA_REQUIRED"},"customerMfaInfo":{"mfaLastMethodUsed":"sms"}}"#.utf8)
        #expect(try ConnectParsing.sso(mfa) == .mfaRequired(method: "sms"))
        let rejected = Data(#"{"responseStatus":{"type":"INVALID_USERNAME_PASSWORD"}}"#.utf8)
        #expect(try ConnectParsing.sso(rejected) == .rejected(type: "INVALID_USERNAME_PASSWORD"))
    }

    @Test func oauth1TokenDecodesTheFormBodyAndDropsAnEmptyMFAToken() throws {
        let body = Data("oauth_token=abc&oauth_token_secret=de%2Bf%2Bg&mfa_token=&mfa_expiration_timestamp=2027-03-18+05%3A33%3A02.000".utf8)
        #expect(try ConnectParsing.oauth1Token(body) == ConnectOAuth1Token(token: "abc", secret: "de+f+g", mfaToken: nil))
        let withMFA = Data("oauth_token=abc&oauth_token_secret=s&mfa_token=XYZ".utf8)
        #expect(try ConnectParsing.oauth1Token(withMFA).mfaToken == "XYZ")
    }

    @Test func accessTokenExpiresAfterExpiresIn() throws {
        let data = Data(#"{"scope":"x","jti":"j","access_token":"AT","token_type":"bearer","refresh_token":"RT","expires_in":3600,"refresh_token_expires_in":7776000}"#.utf8)
        let token = try ConnectParsing.accessToken(data, now: Date(timeIntervalSince1970: 1_000_000))
        #expect(token.value == "AT")
        #expect(token.type == "bearer")
        #expect(token.expiresAt == Date(timeIntervalSince1970: 1_003_600))
    }

    @Test func activityStartIsUTCNotLocalTime() throws {
        let data = Data(#"[{"activityId":21482825013,"startTimeGMT":"2026-01-08 14:10:21","startTimeLocal":"2026-01-08 15:10:21"}]"#.utf8)
        #expect(try ConnectParsing.activities(data) == [
            ConnectActivity(id: 21482825013, start: Date(timeIntervalSince1970: 1_767_881_421)),
        ])
    }

    @Test func dailyStressKeepsOnlyMeasuredValues() throws {
        // Stress -1 means not measured; 101 and a body battery level of 101 are out of range; a battery row without a
        // level is short.
        let data = Data(#"{"stressValuesArray":[[1689811800000,12],[1689812100000,-1],[1689812400000,101]],"bodyBatteryValuesArray":[[1689811800000,"charging",45,1.0],[1689812100000,"charging",101,1.0],[1689812400000,"charging"]]}"#.utf8)
        let (stress, battery) = try ConnectParsing.dailyStress(data)
        #expect(stress == [PointSample(date: Date(timeIntervalSince1970: 1_689_811_800), value: 12)])
        #expect(battery == [PointSample(date: Date(timeIntervalSince1970: 1_689_811_800), value: 45)])
    }

    @Test func dayWithoutDataIsNoPoints() throws {
        let (stress, battery) = try ConnectParsing.dailyStress(Data("null".utf8))
        #expect(stress.isEmpty && battery.isEmpty)
    }
}

@Suite struct ZipArchiveTests {
    /// A zip made with the system `zip` tool: a deflated FIT file, a stored-size directory entry and a text file.
    static let archive = "UEsDBAoAAAAAALeFcl0AAAAAAAAAAAAAAAAEAAAAMTIzL1BLAwQUAAAACAC3hXJdzKyUxhgAAAA4AAAAFAAAADEyMy8xMjNfQUNUSVZJVFkuZml0c/MMcXEMcdQ1MDQyNjE1M7ew1HUjRggAUEsDBAoAAAAAALeFcl2sKpPYAgAAAAIAAAAKAAAAcmVhZG1lLnR4dGhpUEsBAh4DCgAAAAAAt4VyXQAAAAAAAAAAAAAAAAQAAAAAAAAAAAAQAO1BAAAAADEyMy9QSwECHgMUAAAACAC3hXJdzKyUxhgAAAA4AAAAFAAAAAAAAAABAAAApIEiAAAAMTIzLzEyM19BQ1RJVklUWS5maXRQSwECHgMKAAAAAAC3hXJdrCqT2AIAAAACAAAACgAAAAAAAAABAAAApIFsAAAAcmVhZG1lLnR4dFBLBQYAAAAAAwADAKwAAACWAAAAAAA="

    @Test func entriesAreReadWithTheirDeflatedContent() throws {
        let data = try #require(Data(base64Encoded: Self.archive))
        let entries = try ZipArchive.entries(data)
        #expect(entries.map(\.name) == ["123/123_ACTIVITY.fit", "readme.txt"])
        #expect(entries[0].data == Data("FITDATA-0123456789-FITDATA-0123456789-FITDATA-0123456789".utf8))
        #expect(entries[1].data == Data("hi".utf8))
    }

    @Test func truncatedArchiveIsMalformed() throws {
        let data = try #require(Data(base64Encoded: Self.archive))
        #expect(throws: GarminConnectError.malformedResponse) {
            _ = try ZipArchive.entries(data.prefix(40))
        }
    }
}
