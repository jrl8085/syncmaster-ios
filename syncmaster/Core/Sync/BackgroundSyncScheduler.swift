import Foundation
import BackgroundTasks
import OSLog

private let log = Logger(subsystem: "com.syncmaster", category: "BackgroundSync")

final class BackgroundSyncScheduler {
    static let shared = BackgroundSyncScheduler()
    private let processingTaskID = "com.syncmaster.syncmaster.sync"
    private let refreshTaskID    = "com.syncmaster.syncmaster.refresh"
    private init() {}

    // MARK: - Registration (call once at launch)

    func registerTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingTaskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            self.handleProcessingTask(task)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            self.handleRefreshTask(task)
        }
    }

    // MARK: - Scheduling

    /// Schedule the next heavy processing task (~1 hour from now).
    /// Respects the "sync on Wi-Fi only" / "sync on charging" settings.
    func scheduleNextSync() {
        let req = BGProcessingTaskRequest(identifier: processingTaskID)
        req.requiresNetworkConnectivity = true
        req.requiresExternalPower = UserDefaults.standard.bool(forKey: "syncOnCharging")
        req.earliestBeginDate = Date(timeIntervalSinceNow: 3600) // retry after 1 hour
        try? BGTaskScheduler.shared.submit(req)
        log.info("Scheduled next processing sync in ~1 hour")
    }

    /// Schedules an urgent retry after upload failures — fires in 15 minutes.
    /// Submitting a new request with the same identifier replaces any pending one.
    func scheduleAggressiveRetry() {
        let req = BGProcessingTaskRequest(identifier: processingTaskID)
        req.requiresNetworkConnectivity = true
        req.earliestBeginDate = Date(timeIntervalSinceNow: 900) // 15 minutes
        try? BGTaskScheduler.shared.submit(req)
        log.warning("Scheduled aggressive retry in 15 min due to upload failures")
    }

    /// Schedule the next lightweight refresh task (~15 minutes from now).
    func scheduleNextRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 900) // 15 minutes
        try? BGTaskScheduler.shared.submit(req)
    }

    // MARK: - Handlers

    private func handleProcessingTask(_ task: BGProcessingTask) {
        // Reschedule immediately so the chain continues even if this run is cut short.
        scheduleNextSync()
        scheduleNextRefresh()

        let syncTask = Task {
            log.info("BGProcessingTask: starting sync")
            await AppEnvironment.shared.syncEngine.startSync()
            // Wait for sync to finish (status leaves .isActive) up to the task budget.
            // The expirationHandler will cancel syncTask if iOS cuts us off first.
            task.setTaskCompleted(success: true)
            log.info("BGProcessingTask: completed")
        }
        task.expirationHandler = {
            log.warning("BGProcessingTask: expired — cancelling sync")
            syncTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    private func handleRefreshTask(_ task: BGAppRefreshTask) {
        // Reschedule next refresh immediately.
        scheduleNextRefresh()

        let syncTask = Task {
            log.info("BGAppRefreshTask: starting sync")
            await AppEnvironment.shared.syncEngine.startSync()
            task.setTaskCompleted(success: true)
            log.info("BGAppRefreshTask: completed")
        }
        task.expirationHandler = {
            log.warning("BGAppRefreshTask: expired — cancelling")
            syncTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
