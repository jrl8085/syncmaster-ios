import SwiftUI

struct ServerSetupView: View {
    @EnvironmentObject var settings: SyncSettings
    @Environment(\.dismiss) private var dismiss
    var isOnboarding: Bool = false

    @State private var host = ""
    @State private var port = "8443"
    @State private var apiKey = ""
    @State private var status: Status = .idle
    @State private var fingerprint = ""

    enum Status: Equatable {
        case idle, testing
        case connected(version: String)
        case failed(error: String)
    }

    var canSave: Bool { !host.isEmpty && !apiKey.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                // Header
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 44))
                            .foregroundStyle(LinearGradient(colors: [.blue, .cyan], startPoint: .top, endPoint: .bottom))
                        Text(isOnboarding ? "Set Up Your Server" : "Server Configuration")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        Text("Enter the IP address of your Windows PC running the SyncMaster server app.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                }.listRowBackground(Color.clear)

                Section("Server Address") {
                    HStack {
                        Image(systemName: "network").foregroundStyle(.blue)
                        TextField("192.168.1.100", text: $host)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    HStack {
                        Image(systemName: "number").foregroundStyle(.blue)
                        TextField("8443", text: $port).keyboardType(.numberPad)
                    }
                }

                Section("Authentication") {
                    HStack {
                        Image(systemName: "key.fill").foregroundStyle(.orange)
                        SecureField("API Key from server app", text: $apiKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }

                Section("Certificate") {
                    Button {
                        Task { await testAndCapture() }
                    } label: {
                        HStack {
                            if status == .testing { ProgressView().controlSize(.small) }
                            else { Image(systemName: "lock.shield").foregroundStyle(.purple) }
                            Text("Test & Trust Certificate")
                        }
                    }
                    .disabled(host.isEmpty || apiKey.isEmpty || status == .testing)

                    switch status {
                    case .idle: EmptyView()
                    case .testing: Label("Connecting…", systemImage: "network").foregroundStyle(.secondary).font(.caption)
                    case .connected(let v): Label("Connected · v\(v)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    case .failed(let e): Label(e, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
                    }

                    if !fingerprint.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Certificate Fingerprint").font(.caption2).foregroundStyle(.secondary)
                            Text(fingerprint.prefix(32) + "…")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button { save() } label: {
                        Text(isOnboarding ? "Start Using SyncMaster" : "Save")
                            .font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle("Server Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isOnboarding {
                    ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                }
            }
            .onAppear {
                host = settings.serverHost
                port = String(settings.serverPort)
                apiKey = settings.apiKey
                fingerprint = settings.sslFingerprint
            }
        }
    }

    private func testAndCapture() async {
        guard let portInt = Int(port),
              let url = URL(string: "https://\(host):\(portInt)") else {
            status = .failed(error: "Invalid address"); return
        }
        status = .testing
        do {
            let fp = try await FingerprintCapturingDelegate.capture(from: url)
            fingerprint = fp

            let delegate = SSLPinningDelegate(fingerprint: fp)
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            var req = URLRequest(url: url.appendingPathComponent("health"))
            req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            req.timeoutInterval = 5
            let (data, response) = try await session.data(for: req)
            if (response as? HTTPURLResponse)?.statusCode == 200,
               let h = try? JSONDecoder().decode(HealthResponse.self, from: data) {
                status = .connected(version: h.version)
            } else {
                status = .failed(error: "Server returned an error")
            }
        } catch {
            status = .failed(error: error.localizedDescription)
        }
    }

    private func save() {
        settings.serverHost = host
        settings.serverPort = Int(port) ?? 8443
        settings.apiKey = apiKey
        if !fingerprint.isEmpty { settings.sslFingerprint = fingerprint }
        settings.hasCompletedOnboarding = true
        dismiss()
    }
}
