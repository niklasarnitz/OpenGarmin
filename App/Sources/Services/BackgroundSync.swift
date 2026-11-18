import BackgroundTasks

/// Periodic sync while iOS lets the app run in the background.
enum BackgroundSync {
    static let identifier = "com.niklasarnitz.opengarmin.sync"

    /// Call once during launch, before the first scene connects.
    @MainActor
    static func register(_ environment: AppEnvironment) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            Task { @MainActor in
                schedule()
                await environment.watch.syncNow()
                task.setTaskCompleted(success: true)
            }
        }
    }

    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.earliestBeginDate = .now.addingTimeInterval(60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
