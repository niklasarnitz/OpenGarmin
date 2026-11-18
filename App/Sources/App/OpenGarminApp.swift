import SwiftUI

@main
struct OpenGarminApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let environment: AppEnvironment

    init() {
        let environment = AppEnvironment.live()
        self.environment = environment
        BackgroundSync.register(environment)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .tint(Palette.blaze)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { BackgroundSync.schedule() }
        }
    }
}

/// First launch goes through onboarding; afterwards the app opens on its tabs.
struct RootView: View {
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    var body: some View {
        if onboardingComplete {
            MainTabView()
        } else {
            OnboardingView { onboardingComplete = true }
        }
    }
}
