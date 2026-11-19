import Vapor

@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        let app = try await Application.make(env)
        do {
            try await configure(app, config: ServerConfig.fromEnvironment(ProcessInfo.processInfo.environment))
            try await app.autoMigrate()
            Task { await ConnectArchive.reprocessOutdated(app) }
            Task { await InsightJob.run(app) }
            Task { await Rollup.upgradeOutdated(app) }
            try await app.execute()
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
