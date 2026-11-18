import AppIntents
import GarminShared

struct SyncWatchIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync my watch"
    static let description = IntentDescription("Syncs activities, sleep and health data from your Garmin watch.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await WatchCommands.syncNow()
        return .result()
    }
}

struct FindMyWatchIntent: AppIntent {
    static let title: LocalizedStringResource = "Find my watch"
    static let description = IntentDescription("Makes your Garmin watch beep so you can find it.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try await WatchCommands.findMyWatch()
        return .result()
    }
}

struct WatchBatteryIntent: AppIntent {
    static let title: LocalizedStringResource = "Watch battery"
    static let description = IntentDescription("Tells you the battery level of your Garmin watch.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let snapshot = WatchSnapshotStore.read(), let percent = snapshot.watchBattery else {
            return .result(dialog: "The watch battery is not known yet. Sync your watch first.")
        }
        let charging = snapshot.isCharging ? ", charging" : ""
        return .result(dialog: "\(snapshot.watchName ?? "Your watch") is at \(percent)%\(charging).")
    }
}

struct TodaysStepsIntent: AppIntent {
    static let title: LocalizedStringResource = "Today's steps"
    static let description = IntentDescription("Tells you your steps so far today.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let snapshot = WatchSnapshotStore.read(), Calendar.current.isDateInToday(snapshot.date) else {
            return .result(dialog: "No steps yet today. Sync your watch first.")
        }
        return .result(dialog: "You have \(snapshot.steps.formatted()) steps today.")
    }
}
