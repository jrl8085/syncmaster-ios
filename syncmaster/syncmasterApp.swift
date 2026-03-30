import SwiftUI
import BackgroundTasks

@main
struct syncmasterApp: App {
    @StateObject private var env = AppEnvironment.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BackgroundSyncScheduler.shared.registerTasks()
        BackgroundSyncScheduler.shared.scheduleNextSync()
        BackgroundSyncScheduler.shared.scheduleNextRefresh()
        BackgroundSyncScheduler.shared.requestNotificationPermission()
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
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                BackgroundSyncScheduler.shared.beginBackgroundExecution()
            }
        }
    }
}
