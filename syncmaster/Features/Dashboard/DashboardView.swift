import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var syncEngine: SyncEngine
    @EnvironmentObject var networkMonitor: NetworkMonitor
    @EnvironmentObject var settings: SyncSettings
    @EnvironmentObject var mediaLibrary: MediaLibraryService

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ConnectionCard()
                    SyncStatusCard()
                    StatisticsCard()
                    QuickActionsCard()
                    LastSyncCard()
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("SyncMaster")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(networkMonitor.serverReachable ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(networkMonitor.serverReachable ? "Online" : "Offline")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .refreshable {
                await networkMonitor.checkServerReachability()
            }
        }
    }
}

// MARK: - Connection Card

struct ConnectionCard: View {
    @EnvironmentObject var networkMonitor: NetworkMonitor
    @EnvironmentObject var settings: SyncSettings

    var body: some View {
        DashCard {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Server Connection").font(.headline)
                        Text(networkMonitor.serverReachable
                             ? settings.serverHost
                             : (settings.serverHost.isEmpty ? "No server configured" : "Cannot reach server"))
                            .font(.subheadline)
                            .foregroundStyle(networkMonitor.serverReachable ? Color.gray : Color.orange)
                    }
                } icon: {
                    Image(systemName: networkMonitor.serverReachable ? "wifi" : "wifi.slash")
                        .foregroundStyle(networkMonitor.serverReachable ? .green : .orange)
                }
                Spacer()
            }
        }
    }
}

// MARK: - Sync Status Card

struct SyncStatusCard: View {
    @EnvironmentObject var syncEngine: SyncEngine

    var statusColor: Color {
        switch syncEngine.status {
        case .idle: return .secondary
        case .scanning, .uploading: return .blue
        case .completed: return .green
        case .failed: return .red
        case .paused: return .orange
        }
    }

    var body: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Sync Status").font(.headline)
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .stroke(Color(.systemFill), lineWidth: 8)
                            .frame(width: 68, height: 68)
                        Circle()
                            .trim(from: 0, to: syncEngine.overallProgress)
                            .stroke(
                                LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing),
                                style: StrokeStyle(lineWidth: 8, lineCap: .round)
                            )
                            .frame(width: 68, height: 68)
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.3), value: syncEngine.overallProgress)
                        Text("\(Int(syncEngine.overallProgress * 100))%")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(syncEngine.status.displayText)
                            .font(.subheadline)
                            .foregroundStyle(statusColor)
                        if let s = syncEngine.currentSession {
                            Text("\(s.uploadedCount) uploaded · \(s.skippedCount) skipped")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Stats Card

struct StatisticsCard: View {
    @EnvironmentObject var mediaLibrary: MediaLibraryService

    var body: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Library").font(.headline)
                HStack {
                    StatTile(value: "\(mediaLibrary.totalCount)", label: "Total", icon: "photo.stack", color: .blue)
                    Divider()
                    StatTile(value: "\(mediaLibrary.uploadedCount)", label: "Backed Up", icon: "checkmark.icloud", color: .green)
                    Divider()
                    StatTile(value: "\(mediaLibrary.pendingCount)", label: "Pending", icon: "clock.arrow.circlepath", color: .orange)
                }
            }
        }
    }
}

struct StatTile: View {
    let value: String; let label: String; let icon: String; let color: Color
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            Text(value).font(.system(.title2, design: .rounded, weight: .bold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

// MARK: - Quick Actions

struct QuickActionsCard: View {
    @EnvironmentObject var syncEngine: SyncEngine
    @EnvironmentObject var networkMonitor: NetworkMonitor

    var body: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Actions").font(.headline)
                HStack(spacing: 10) {
                    if syncEngine.status.isActive {
                        ActionBtn(title: "Pause", icon: "pause.fill", color: .orange) { syncEngine.pauseSync() }
                        ActionBtn(title: "Stop", icon: "stop.fill", color: .red) { syncEngine.stopSync() }
                    } else {
                        ActionBtn(title: "Sync Now", icon: "arrow.triangle.2.circlepath", color: .blue,
                                  disabled: !networkMonitor.serverReachable) {
                            Task { await syncEngine.startSync() }
                        }
                    }
                }
            }
        }
    }
}

struct ActionBtn: View {
    let title: String; let icon: String; let color: Color
    var disabled: Bool = false; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(disabled ? Color.gray : Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(disabled ? Color(.systemFill) : color, in: RoundedRectangle(cornerRadius: 10))
        }
        .disabled(disabled)
    }
}

// MARK: - Last Sync

struct LastSyncCard: View {
    @EnvironmentObject var settings: SyncSettings
    var body: some View {
        DashCard {
            HStack {
                Image(systemName: "clock").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last backup").font(.subheadline)
                    if let date = settings.lastSyncDate {
                        Text(date, style: .relative).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Never").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
    }
}

// MARK: - Shared card container

struct DashCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
