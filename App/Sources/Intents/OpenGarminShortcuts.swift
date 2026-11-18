import AppIntents

struct OpenGarminShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .orange

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SyncWatchIntent(),
                    phrases: ["Sync my watch with \(.applicationName)", "Sync \(.applicationName)"],
                    shortTitle: "Sync watch", systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: FindMyWatchIntent(),
                    phrases: ["Find my watch with \(.applicationName)"],
                    shortTitle: "Find watch", systemImageName: "applewatch.radiowaves.left.and.right")
        AppShortcut(intent: WatchBatteryIntent(),
                    phrases: ["Watch battery in \(.applicationName)"],
                    shortTitle: "Watch battery", systemImageName: "battery.75percent")
        AppShortcut(intent: TodaysStepsIntent(),
                    phrases: ["Today's steps in \(.applicationName)"],
                    shortTitle: "Today's steps", systemImageName: "figure.walk")
        AppShortcut(intent: SendWorkoutIntent(),
                    phrases: ["Send \(\.$workout) with \(.applicationName)"],
                    shortTitle: "Send workout", systemImageName: "paperplane.fill")
    }
}
