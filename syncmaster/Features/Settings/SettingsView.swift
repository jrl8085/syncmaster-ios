import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SyncSettings
    @EnvironmentObject var networkMonitor: NetworkMonitor
    @EnvironmentObject var env: AppEnvironment

    @State private var showingServerSetup = false
    @State private var showingResetConfirm = false
    @State private var testResult: TestResult?
    @State private var isTesting = false

    enum TestResult { case ok(String), fail(String) }

    var body: some View {
        NavigationStack {
            List {
                // Server
                Section("Media Server") {
                    if settings.serverHost.isEmpty {
                        Button { showingServerSetup = true } label: {
                            Label("Configure Server", systemImage: "plus.circle.fill")
                        }
                    } else {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(settings.serverHost).font(.subheadline.weight(.medium))
                                Text("Port \(settings.serverPort)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle().fill(networkMonitor.serverReachable ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                        }
                        Button(isTesting ? "Testing…" : "Test Connection") {
                            Task { await testConnection() }
                        }.disabled(isTesting)

                        if let r = testResult {
                            switch r {
                            case .ok(let m): Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                            case .fail(let m): Label(m, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
                            }
                        }
                        Button("Edit Server") { showingServerSetup = true }
                    }
                }

                // Sync
                Section("Sync Behavior") {
                    Toggle("Auto-Sync", isOn: $settings.autoSyncEnabled)
                    Toggle("Wi-Fi Only", isOn: $settings.wifiOnlySync)
                    Toggle("Only When Charging", isOn: $settings.syncOnCharging)
                    HStack {
                        Text("Last backup")
                        Spacer()
                        if let d = settings.lastSyncDate { Text(d, style: .relative).foregroundStyle(.secondary) }
                        else { Text("Never").foregroundStyle(.secondary) }
                    }
                }

                // Backup folder
                Section {
                    HStack {
                        Text("Backup Folder")
                        Spacer()
                        TextField("Folder name", text: $settings.deviceFolder)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Server Folder")
                } footer: {
                    Text("Files are saved under this folder name on the server. Each device should use a unique name.")
                }

                // Security
                Section("Security") {
                    HStack {
                        Text("API Key")
                        Spacer()
                        Text(settings.apiKey.isEmpty ? "Not set" : "••••••••••••••••")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                    Button("Reset Sync Records", role: .destructive) { showingResetConfirm = true }
                }

                // About
                Section("About") {
                    HStack { Text("Version"); Spacer(); Text("1.0.0").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showingServerSetup) { ServerSetupView() }
            .confirmationDialog("Reset Sync State", isPresented: $showingResetConfirm, titleVisibility: .visible) {
                Button("Reset", role: .destructive) {
                    Task { await env.syncEngine.resetSyncRecords() }
                }
            } message: {
                Text("Resets the local sync state and re-checks the server. Only files missing from the server will be re-uploaded.")
            }
        }
    }

    private func testConnection() async {
        isTesting = true; testResult = nil
        do {
            let h = try await env.syncEngine.apiClient.healthCheck()
            testResult = .ok("Connected · v\(h.version)")
        } catch {
            testResult = .fail(error.localizedDescription)
        }
        isTesting = false
    }
}
