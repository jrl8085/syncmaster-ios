import Foundation
import BackgroundTasks

final class BackgroundSyncScheduler {
    static let shared = BackgroundSyncScheduler()
    private let taskID = "com.syncmaster.syncmaster.sync"
    private init() {}

    func registerTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            self.handleBackgroundSync(task: task)
        }
    }

    func scheduleNextSync() {
        let req = BGProcessingTaskRequest(identifier: taskID)
        req.requiresNetworkConnectivity = true
        req.requiresExternalPower = UserDefaults.standard.bool(forKey: "syncOnCharging")
        req.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        try? BGTaskScheduler.shared.submit(req)
    }

    private func handleBackgroundSync(task: BGProcessingTask) {
        scheduleNextSync()
        let syncTask = Task {
            await AppEnvironment.shared.syncEngine.startSync()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            syncTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
