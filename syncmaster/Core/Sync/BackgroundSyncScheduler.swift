import Foundation
import BackgroundTasks
import UserNotifications
import UIKit
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

    func scheduleNextSync() {
        let req = BGProcessingTaskRequest(identifier: processingTaskID)
        req.requiresNetworkConnectivity = true
        req.requiresExternalPower = UserDefaults.standard.bool(forKey: "syncOnCharging")
        req.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        try? BGTaskScheduler.shared.submit(req)
        log.info("Scheduled next processing sync in ~1 hour")
    }

    /// Schedules an urgent retry after upload failures — fires in 15 minutes.
    func scheduleAggressiveRetry() {
        let req = BGProcessingTaskRequest(identifier: processingTaskID)
        req.requiresNetworkConnectivity = true
        req.earliestBeginDate = Date(timeIntervalSinceNow: 900)
        try? BGTaskScheduler.shared.submit(req)
        log.warning("Scheduled aggressive retry in 15 min due to upload failures")
    }

    func scheduleNextRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 900)
        try? BGTaskScheduler.shared.submit(req)
    }

    // MARK: - Handlers

    private func handleProcessingTask(_ task: BGProcessingTask) {
        scheduleNextSync()
        scheduleNextRefresh()

        let workTask = Task { @MainActor in
            log.info("BGProcessingTask: starting sync")
            await AppEnvironment.shared.syncEngine.startSyncAndWait()
            let finalStatus = AppEnvironment.shared.syncEngine.status
            log.info("BGProcessingTask: completed")
            task.setTaskCompleted(success: true)
            sendCompletionNotification(for: finalStatus)
        }
        task.expirationHandler = {
            log.warning("BGProcessingTask: expired — cancelling sync")
            workTask.cancel()
            Task { @MainActor in AppEnvironment.shared.syncEngine.pauseSync() }
            task.setTaskCompleted(success: false)
        }
    }

    private func handleRefreshTask(_ task: BGAppRefreshTask) {
        scheduleNextRefresh()

        let workTask = Task { @MainActor in
            log.info("BGAppRefreshTask: starting sync")
            await AppEnvironment.shared.syncEngine.startSyncAndWait()
            let finalStatus = AppEnvironment.shared.syncEngine.status
            log.info("BGAppRefreshTask: completed")
            task.setTaskCompleted(success: true)
            sendCompletionNotification(for: finalStatus)
        }
        task.expirationHandler = {
            log.warning("BGAppRefreshTask: expired — cancelling")
            workTask.cancel()
            Task { @MainActor in AppEnvironment.shared.syncEngine.pauseSync() }
            task.setTaskCompleted(success: false)
        }
    }

    // MARK: - Immediate background execution

    /// Call when the app goes to background (scene phase `.background`).
    /// iOS grants ~30 seconds of execution time so an active sync can continue,
    /// or a new one can start, before the process is suspended.
    func beginBackgroundExecution() {
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "syncmaster.background") {
            // Time expired — iOS is suspending the app. Don't cancel the sync;
            // let iOS suspend the URLSession naturally so it can resume on next foreground.
            log.warning("Background execution time expired — app suspending")
            UIApplication.shared.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
        }
        guard bgTaskID != .invalid else { return }

        Task { @MainActor in
            log.info("Background execution started")
            await AppEnvironment.shared.syncEngine.startSyncAndWait()
            log.info("Background execution finished")
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
        }
    }

    // MARK: - Notification

    /// Request notification permission. Call once at launch.
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            log.info("Notification permission: \(granted ? "granted" : "denied")")
        }
    }

    private func sendCompletionNotification(for status: SyncStatus) {
        let content = UNMutableNotificationContent()
        content.sound = .default

        switch status {
        case .completed(let uploaded, let skipped, let failed):
            guard uploaded > 0 || failed > 0 else { return } // nothing interesting to report
            content.title = "SyncMaster — Backup Complete"
            var parts: [String] = []
            if uploaded > 0 { parts.append("\(uploaded) file\(uploaded == 1 ? "" : "s") backed up") }
            if skipped  > 0 { parts.append("\(skipped) already on server") }
            if failed   > 0 { parts.append("\(failed) failed") }
            content.body = parts.joined(separator: " · ")

        case .failed(let error):
            content.title = "SyncMaster — Backup Failed"
            content.body = error

        default:
            return
        }

        let request = UNNotificationRequest(
            identifier: "syncmaster.sync.complete.\(UUID().uuidString)",
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { err in
            if let err { log.error("Notification delivery failed: \(err.localizedDescription)") }
        }
    }
}
