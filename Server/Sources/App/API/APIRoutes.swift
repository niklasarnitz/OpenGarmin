import FluentSQL
import Foundation
import Vapor

func registerAPIRoutes(_ app: Application) throws {
    let api = app.grouped("api", "v1").grouped(CookieCSRFGuard())

    api.post("auth", "register") { req async throws -> Response in
        let body = try await req.content.decode(Credentials.self)
        return try await Accounts.register(email: body.email, password: body.password, on: req).sessionResponse()
    }
    api.post("auth", "login") { req async throws -> Response in
        let body = try await req.content.decode(Credentials.self)
        return try await Accounts.signIn(email: body.email, password: body.password, on: req).sessionResponse()
    }
    api.post("auth", "logout") { req async throws -> Response in
        if let token = req.presentedToken() {
            try await Accounts.signOut(token: token, on: req)
        }
        let response = Response(status: .noContent)
        response.cookies[SessionToken.cookieName] = SessionToken.cookie("", expires: Date(timeIntervalSince1970: 0), maxAge: 0)
        return response
    }
    api.get("me") { req async throws -> UserDTO in
        try await req.requireUser().dto
    }
    api.patch("me") { req async throws -> UserDTO in
        let user = try await req.requireUser()
        let body = try await req.content.decode(MePatch.self)
        if let zone = body.timeZone {
            guard TimeZone(identifier: zone) != nil else {
                throw Abort(.badRequest, reason: "`timeZone` must be an IANA time zone such as Europe/Berlin.")
            }
            try await Accounts.setTimeZone(zone, user: user, on: req)
        }
        if body.workDays != nil || body.workStart != nil || body.workEnd != nil {
            try await Accounts.setWorkingHours(body, user: user, on: req)
        }
        return try await req.requireUser().dto
    }

    // Uploads
    api.post("fit-files") { req async throws -> UploadResult in
        let user = try await req.requireUser()
        let upload = try await req.content.decode(FitUpload.self)
        return try await Ingest.fit(upload, user: user, on: req)
    }
    api.post("batches") { req async throws -> UploadResult in
        let user = try await req.requireUser()
        let upload = try await req.content.decode(BatchUpload.self)
        return try await Ingest.batch(upload, user: user, on: req)
    }
    api.get("sync", "state") { req async throws -> SyncState in
        let user = try await req.requireUser()
        let rows = try await req.sql.raw("""
            SELECT key FROM fit_files WHERE user_id = \(bind: user.id)
            UNION ALL SELECT key FROM connect_raw WHERE user_id = \(bind: user.id)
            """).all(decoding: KeyRow.self)
        return SyncState(keys: rows.map(\.key))
    }

    // Apple Health import
    api.post("healthkit", "samples") { req async throws -> UploadResult in
        let user = try await req.requireUser()
        let upload = try await req.content.decode(HealthSamplesUpload.self)
        return try await HealthKitImport.samples(upload, user: user, on: req)
    }
    api.post("healthkit", "workouts") { req async throws -> UploadResult in
        let user = try await req.requireUser()
        let upload = try await req.content.decode(HealthWorkoutsUpload.self)
        return try await HealthKitImport.workouts(upload, user: user, on: req)
    }
    api.post("healthkit", "electrocardiograms") { req async throws -> UploadResult in
        let user = try await req.requireUser()
        let upload = try await req.content.decode(HealthElectrocardiogramsUpload.self)
        return try await HealthKitImport.electrocardiograms(upload, user: user, on: req)
    }
    api.get("healthkit", "types") { req async throws -> [HealthTypeSummary] in
        let user = try await req.requireUser()
        return try await HealthKitImport.types(req, user: user)
    }

    // Garmin Connect archive
    api.post("connect", "raw") { req async throws -> UploadResult in
        let user = try await req.requireUser()
        let upload = try ConnectArchive.decode(req)
        return try await ConnectArchive.archive(upload, user: user, on: req)
    }
    api.get("connect", "diagnostics") { req async throws -> ConnectDiagnostics in
        let user = try await req.requireUser()
        return try await ConnectArchive.diagnostics(req, user: user)
    }

    api.get("insights") { req async throws -> [Insight] in
        let user = try await req.requireUser()
        return try await InsightStore.serve(req, user: user)
    }

    // Reads
    api.get("samples", ":metric") { req async throws -> Response in
        try await Reads.samples(req)
    }
    api.get("sleep") { req async throws -> [SleepSessionDTO] in
        let user = try await req.requireUser()
        return try await Reads.sleep(req, user: user, window: try Reads.window(req, timeZone: user.timeZone))
    }
    api.get("activities") { req async throws -> ActivityPage in
        let user = try await req.requireUser()
        var window = try Reads.window(req, timeZone: user.timeZone)
        if let cursor = try Reads.date(req, "cursor", timeZone: user.timeZone) {
            window.to = min(window.to, cursor)
        }
        let limit = min(max(Int(req.query[String.self, at: "limit"] ?? "") ?? 50, 1), 200)
        return try await Reads.activityPage(req, user: user, window: window, limit: limit)
    }
    api.get("activities", ":id") { req async throws -> ActivityDetail in
        let user = try await req.requireUser()
        guard let id = req.parameters.get("id", as: UUID.self),
              let detail = try await Reads.activityDetail(req, user: user, id: id)
        else { throw Abort(.notFound) }
        return detail
    }
    api.get("activities", ":id", "fit") { req async throws -> Response in
        let user = try await req.requireUser()
        guard let id = req.parameters.get("id", as: UUID.self),
              let file = try await Reads.fitFile(req, user: user, id: id),
              let data = try await req.serverContext.blobs.get(file.storageKey)
        else { throw Abort(.notFound) }
        var headers = HTTPHeaders()
        headers.contentType = .binary
        headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=\"\(file.externalId).fit\"")
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }
    api.get("days") { req async throws -> [DaySummary] in
        let user = try await req.requireUser()
        return try await Reads.days(req, user: user, window: try Reads.window(req, timeZone: user.timeZone))
    }
    api.get("metrics") { req async throws -> [MetricInfo] in
        let user = try await req.requireUser()
        return try await Rollup.metrics(req, user: user)
    }
    api.get("metrics", "daily") { req async throws -> [MetricDay] in
        let user = try await req.requireUser()
        let window = try Reads.window(req, timeZone: user.timeZone)
        let names = (req.query[String.self, at: "metrics"] ?? "").split(separator: ",").map(String.init)
        return try await Rollup.daily(req, user: user, window: window, metrics: names)
    }
    api.get("healthkit", "quantities", ":type") { req async throws -> [SampleBucket] in
        let user = try await req.requireUser()
        guard let type = req.parameters.get("type"), type.hasPrefix("HKQuantityTypeIdentifier") else {
            throw Abort(.notFound, reason: "Not a quantity type.")
        }
        let resolution = req.query[String.self, at: "resolution"] ?? "day"
        return try await HealthKitImport.quantities(req, user: user, type: type, window: try Reads.window(req, timeZone: user.timeZone), resolution: resolution)
    }
    api.get("export", "history") { req async throws -> Response in
        let user = try await req.requireUser()
        let batch = try await Reads.history(req, user: user, window: try Reads.window(req, timeZone: user.timeZone))
        return try Response.json(batch)
    }
}

private struct KeyRow: Decodable {
    let key: String
}
