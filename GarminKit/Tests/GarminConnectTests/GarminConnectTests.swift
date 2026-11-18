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

    @Test func sleepReadsTheNightStagesAndScore() throws {
        // Levels 0 deep, 1 light. The DTO's totals (30 min awake, 10 min REM) match code 2's 30 minutes and code 3's 10,
        // so 2 is awake and 3 is REM. Code 7 is unknown and a level that ends before it starts is dropped.
        let data = Data(#"""
        {"dailySleepDTO":{"sleepStartTimestampGMT":1761113400000,"sleepEndTimestampGMT":1761125400000,
          "remSleepSeconds":600,"awakeSleepSeconds":1800,
          "sleepScores":{"overall":{"value":84},"totalDuration":{"value":90},"deepPercentage":{"value":70},
            "lightPercentage":{"value":55},"remPercentage":{"value":80},"awakeCount":{"value":65},"restlessness":{"value":40},
            "stress":{"value":30}}},
         "sleepLevels":[{"startGMT":"2025-10-22T06:10:00.0","endGMT":"2025-10-22T06:40:00.0","activityLevel":0.0},
           {"startGMT":"2025-10-22T06:40:00.0","endGMT":"2025-10-22T07:00:00.0","activityLevel":1},
           {"startGMT":"2025-10-22T07:00:00.0","endGMT":"2025-10-22T07:30:00.0","activityLevel":2},
           {"startGMT":"2025-10-22T07:30:00.0","endGMT":"2025-10-22T07:40:00.0","activityLevel":3},
           {"startGMT":"2025-10-22T07:40:00.0","endGMT":"2025-10-22T07:50:00.0","activityLevel":7},
           {"startGMT":"2025-10-22T07:50:00.0","endGMT":"2025-10-22T07:45:00.0","activityLevel":1}]}
        """#.utf8)
        let session = try #require(ConnectParsing.sleep(data))
        #expect(session.start == Date(timeIntervalSince1970: 1_761_113_400))
        #expect(session.end == Date(timeIntervalSince1970: 1_761_125_400))
        #expect(session.intervals == [
            SleepInterval(start: Date(timeIntervalSince1970: 1_761_113_400), end: Date(timeIntervalSince1970: 1_761_115_200), stage: .deep),
            SleepInterval(start: Date(timeIntervalSince1970: 1_761_115_200), end: Date(timeIntervalSince1970: 1_761_116_400), stage: .light),
            SleepInterval(start: Date(timeIntervalSince1970: 1_761_116_400), end: Date(timeIntervalSince1970: 1_761_118_200), stage: .awake),
            SleepInterval(start: Date(timeIntervalSince1970: 1_761_118_200), end: Date(timeIntervalSince1970: 1_761_118_800), stage: .rem),
        ])
        #expect(session.score == 84)
        #expect(session.scoreBreakdown == SleepScoreBreakdown(duration: 90, deep: 70, light: 55, rem: 80, awakenings: 65, restlessness: 40))
    }

    @Test func remAndAwakeCodesFollowTheNightsTotals() {
        // 80 minutes of code 2 and 25 of code 3 against 78 REM and 27 awake: 2 is REM.
        #expect(ConnectParsing.codeTwoIsREM(minutes: [2: 80, 3: 25], remMinutes: 78, awakeMinutes: 27))
        #expect(!ConnectParsing.codeTwoIsREM(minutes: [2: 80, 3: 25], remMinutes: 27, awakeMinutes: 78))
        // Without totals, the default seen on real accounts: 2 is awake.
        #expect(!ConnectParsing.codeTwoIsREM(minutes: [2: 80, 3: 25], remMinutes: nil, awakeMinutes: nil))
    }

    @Test func aDayWithoutSleepIsNoSession() {
        #expect(ConnectParsing.sleep(Data("null".utf8)) == nil)
        #expect(ConnectParsing.sleep(Data(#"{"dailySleepDTO":{"sleepStartTimestampGMT":5,"sleepEndTimestampGMT":5}}"#.utf8)) == nil)
    }

    @Test func stepsKeepTheIntervalsWithSteps() {
        let data = Data(#"[{"startGMT":"2026-04-20T22:00:00.0","endGMT":"2026-04-20T22:15:00.0","steps":120},{"startGMT":"2026-04-20T22:15:00.0","endGMT":"2026-04-20T22:30:00.0","steps":0},{"startGMT":"2026-04-20T22:30:00.0","endGMT":"2026-04-20T22:45:00.0","steps":null}]"#.utf8)
        #expect(ConnectParsing.steps(data) == [IntervalSample(start: Date(timeIntervalSince1970: 1_776_722_400), end: Date(timeIntervalSince1970: 1_776_723_300), value: 120)])
        #expect(ConnectParsing.steps(Data("null".utf8)).isEmpty)
    }

    @Test func restingHeartRateAndHRVOfTheDay() {
        #expect(ConnectParsing.restingHeartRate(Data(#"{"restingHeartRate":54}"#.utf8)) == 54)
        #expect(ConnectParsing.restingHeartRate(Data(#"{"restingHeartRate":null}"#.utf8)) == nil)
        let hrv = Data(#"{"hrvSummary":{"weeklyAvg":48,"lastNightAvg":52.0},"sleepEndTimestampGMT":"2026-04-21T06:00:00.0"}"#.utf8)
        #expect(ConnectParsing.hrv(hrv) == PointSample(date: Date(timeIntervalSince1970: 1_776_751_200), value: 52))
        #expect(ConnectParsing.hrv(Data()) == nil)
    }

    @Test func displayNameIsTheSocialProfilesName() throws {
        #expect(try ConnectParsing.displayName(Data(#"{"displayName":"abc-123","fullName":"Max"}"#.utf8)) == "abc-123")
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

@Test func activityListWithoutDaysPagesTheWholeAccount() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    let all = ConnectRequests.activitiesQuery(start: 200, limit: 100, from: nil, to: nil, calendar: calendar)
    #expect(all == [URLQueryItem(name: "start", value: "200"), URLQueryItem(name: "limit", value: "100")])
    // 2026-11-17 23:30 UTC is already the 18th in Berlin.
    let ranged = ConnectRequests.activitiesQuery(start: 0, limit: 100, from: Date(timeIntervalSince1970: 1_794_958_200),
                                                 to: Date(timeIntervalSince1970: 1_794_958_200), calendar: calendar)
    #expect(ranged.map(\.name) == ["start", "limit", "startDate", "endDate"])
    #expect(ranged[2].value == "2026-11-18")
}
