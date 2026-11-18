import Foundation
import Vapor

/// The dashboard is a static single-page app in `Public/`. A GET for a path that is not a file gets its `index.html`,
/// so the client router decides what the path shows. API paths never fall back: an unknown one is a 404.
func registerStaticRoutes(_ app: Application) {
    let serveIndex: @Sendable (Request) async throws -> Response = { req in
        let path = req.application.directory.publicDirectory + "index.html"
        guard FileManager.default.fileExists(atPath: path) else { throw Abort(.notFound) }
        return try await req.fileio.asyncStreamFile(at: path)
    }
    app.get(use: serveIndex)
    app.get("**") { req async throws -> Response in
        let path = req.url.path
        if path == "/api" || path.hasPrefix("/api/") { throw Abort(.notFound) }
        return try await serveIndex(req)
    }
}
