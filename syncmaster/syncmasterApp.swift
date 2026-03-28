import SwiftUI
import BackgroundTasks

@main
struct syncmasterApp: App {
    @StateObject private var env = AppEnvironment.shared

    init() {
        BackgroundSyncScheduler.shared.registerTasks()
        BackgroundSyncScheduler.shared.scheduleNextSync()
        BackgroundSyncScheduler.shared.scheduleNextRefresh()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if env.settings.hasCompletedOnboarding {
                    ContentView()
                } else {
                    OnboardingView()
                }
            }
            .environmentObject(env)
            .environmentObject(env.syncEngine)
            .environmentObject(env.networkMonitor)
            .environmentObject(env.settings)
            .environmentObject(env.mediaLibrary)
        }
    }
}
