import Foundation

/// The requests garth sends to Garmin's SSO and Connect API. Pure: nothing is sent here, so the builders are tested
/// against the requests garth makes.
enum ConnectRequests {
    static let clientID = "GCM_ANDROID_DARK"
    static let loginService = "https://mobile.integration.garmin.com/gcm/android"
    static let exchangeAudience = "GARMIN_CONNECT_MOBILE_ANDROID_DI"
    static let consumerURL = URL(string: "https://thegarth.s3.amazonaws.com/oauth_consumer.json")!
    /// garth's user agent for the SSO and Connect API calls.
    static let userAgent = "GCM-iOS-5.22.1.4"
    /// The Android app's user agent, which garth sends with the OAuth calls.
    static let oauthUserAgent = "com.garmin.android.apps.connectmobile"
    /// Garmin's SSO sits behind a bot check that rejects clients which do not look like a browser, so the SSO calls use
    /// the headers of the page its web view loads.
    static let ssoHeaders = [
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Sec-Fetch-Mode": "navigate",
        "Sec-Fetch-Dest": "document",
    ]

    static let activitiesPath = "/activitylist-service/activities/search/activities"

    private static let loginQuery = [
        URLQueryItem(name: "clientId", value: clientID),
        URLQueryItem(name: "locale", value: "en-US"),
        URLQueryItem(name: "service", value: loginService),
    ]

    // MARK: - Sign-in

    static func ssoPage() -> URLRequest {
        var headers = ssoHeaders
        headers["Sec-Fetch-Site"] = "none"
        return request("GET", ssoURL("/mobile/sso/en/sign-in", [URLQueryItem(name: "clientId", value: clientID)]),
                       headers: headers)
    }

    static func login(email: String, password: String) -> URLRequest {
        jsonRequest(ssoURL("/mobile/api/login", loginQuery), body: [
            "username": email,
            "password": password,
            "rememberMe": false,
            "captchaToken": "",
        ])
    }

    static func verifyMFA(code: String, method: String) -> URLRequest {
        jsonRequest(ssoURL("/mobile/api/mfa/verifyCode", loginQuery), body: [
            "mfaMethod": method,
            "mfaVerificationCode": code,
            "rememberMyBrowser": false,
            "reconsentList": [String](),
            "mfaSetup": false,
        ])
    }

    /// Garth loads this page after sign-in so the backend pinning cookie is set. Its failure is not an error.
    static func portalEmbed() -> URLRequest {
        var headers = ssoHeaders
        headers["Sec-Fetch-Site"] = "same-origin"
        return request("GET", ssoURL("/portal/sso/embed", []), headers: headers)
    }

    /// Trades the service ticket for the OAuth1 token. Signed with the consumer key alone.
    static func preauthorized(ticket: String, signer: OAuth1Signer) -> URLRequest {
        let url = apiURL("/oauth-service/oauth/preauthorized", [
            URLQueryItem(name: "ticket", value: ticket),
            URLQueryItem(name: "login-url", value: loginService),
            URLQueryItem(name: "accepts-mfa-tokens", value: "true"),
        ])
        return request("GET", url, headers: oauthHeaders("GET", url, form: [], signer: signer))
    }

    /// Trades the OAuth1 token for an OAuth2 access token. The sign-in asks for the Connect Mobile audience; a refresh
    /// does not.
    static func exchange(oauth1: ConnectOAuth1Token, signer: OAuth1Signer, login: Bool) -> URLRequest {
        var form: [(String, String)] = []
        if login { form.append(("audience", exchangeAudience)) }
        if let mfaToken = oauth1.mfaToken { form.append(("mfa_token", mfaToken)) }
        let url = apiURL("/oauth-service/oauth/exchange/user/2.0")
        var headers = oauthHeaders("POST", url, form: form, signer: signer)
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        var urlRequest = request("POST", url, headers: headers)
        urlRequest.httpBody = OAuth1Signer.formBody(form)
        return urlRequest
    }

    // MARK: - Connect API

    /// One page of the activity list, newest first, between two calendar days. Without days it pages through every
    /// activity of the account.
    static func activitiesQuery(start: Int, limit: Int, from: Date?, to: Date?, calendar: Calendar) -> [URLQueryItem] {
        var query = [
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let from { query.append(URLQueryItem(name: "startDate", value: day(from, calendar: calendar))) }
        if let to { query.append(URLQueryItem(name: "endDate", value: day(to, calendar: calendar))) }
        return query
    }

    /// The original file of an activity: a zip archive that holds the FIT file.
    static func originalActivityPath(_ id: Int64) -> String {
        "/download-service/files/activity/\(id)"
    }

    /// Stress and Body Battery of one calendar day.
    static func dailyStressPath(_ day: String) -> String {
        "/wellness-service/wellness/dailyStress/\(day)"
    }

    static let socialProfilePath = "/userprofile-service/socialProfile"

    static func dailySleepPath(_ name: String) -> String {
        "/wellness-service/wellness/dailySleepData/\(name)"
    }

    static func stepsChartPath(_ name: String) -> String {
        "/wellness-service/wellness/dailySummaryChart/\(name)"
    }

    static func dailySummaryPath(_ name: String) -> String {
        "/usersummary-service/usersummary/daily/\(name)"
    }

    static func hrvPath(_ day: String) -> String {
        "/hrv-service/hrv/\(day)"
    }

    /// "yyyy-MM-dd" of a calendar day, the form Garmin's date parameters take.
    static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// A Connect API call, authorised with the access token.
    static func apiRequest(_ path: String, query: [URLQueryItem], accessToken: ConnectAccessToken) -> URLRequest {
        request("GET", apiURL(path, query), headers: [
            "User-Agent": userAgent,
            "Accept": "*/*",
            "Authorization": "\(accessToken.type.capitalized) \(accessToken.value)",
        ])
    }

    // MARK: - Building blocks

    private static func oauthHeaders(_ method: String, _ url: URL, form: [(String, String)],
                                     signer: OAuth1Signer) -> [String: String] {
        [
            "User-Agent": oauthUserAgent,
            "Accept": "*/*",
            "Authorization": signer.authorization(method: method, url: url, form: form),
        ]
    }

    private static func jsonRequest(_ url: URL, body: [String: Any]) -> URLRequest {
        var urlRequest = request("POST", url, headers: ssoHeaders.merging(["Content-Type": "application/json"]) { $1 })
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private static func request(_ method: String, _ url: URL, headers: [String: String]) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        for (name, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        return urlRequest
    }

    private static func ssoURL(_ path: String, _ query: [URLQueryItem]) -> URL {
        url("https://sso.garmin.com", path, query)
    }

    private static func apiURL(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        url("https://connectapi.garmin.com", path, query)
    }

    /// The paths are constants and the query values are percent-encoded by URLComponents, so the URL is always valid.
    private static func url(_ base: String, _ path: String, _ query: [URLQueryItem]) -> URL {
        var components = URLComponents(string: base + path)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }
}
