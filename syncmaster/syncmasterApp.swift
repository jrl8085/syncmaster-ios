import SwiftUI
import BackgroundTasks

@main
struct syncmasterApp: App {
    @StateObject private var env = AppEnvironment.shared

    init() {
        BackgroundSyncScheduler.shared.registerTasks()
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
