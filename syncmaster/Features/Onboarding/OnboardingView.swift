import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var settings: SyncSettings
    @EnvironmentObject var mediaLibrary: MediaLibraryService
    @State private var page = 0

    var body: some View {
        TabView(selection: $page) {
            WelcomePage { withAnimation { page = 1 } }.tag(0)
            PermissionsPage { withAnimation { page = 2 } }.tag(1)
            ServerSetupView(isOnboarding: true).tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .animation(.easeInOut, value: page)
        .ignoresSafeArea(edges: .top)
    }
}

// MARK: - Welcome

struct WelcomePage: View {
    let onNext: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "arrow.triangle.2.circlepath.icloud.fill")
                .font(.system(size: 80))
                .foregroundStyle(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(.bottom, 24)
            Text("SyncMaster")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("Automatically back up all your photos and videos to your home server when you're on your home Wi-Fi.")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32).padding(.top, 8)
            Spacer()
            VStack(spacing: 16) {
                FeatureRow(icon: "wifi", color: .blue, title: "Local Network", detail: "Backs up automatically when home")
                FeatureRow(icon: "arrow.triangle.2.circlepath", color: .green, title: "Incremental", detail: "Only uploads new media")
                FeatureRow(icon: "lock.shield.fill", color: .purple, title: "Secure", detail: "API key + certificate pinning")
            }.padding(.horizontal, 32)
            Spacer()
            Button(action: onNext) {
                Text("Get Started")
                    .font(.headline).frame(maxWidth: .infinity).padding()
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }.padding(.horizontal, 32).padding(.bottom, 40)
        }
    }
}

// MARK: - Permissions

struct PermissionsPage: View {
    @EnvironmentObject var mediaLibrary: MediaLibraryService
    let onNext: () -> Void
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 60)).foregroundStyle(.blue)
            Text("Photo Library Access")
                .font(.system(.title, design: .rounded, weight: .bold))
            Text("SyncMaster needs access to your entire photo library to back up all your memories.")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 12) {
                Button {
                    Task {
                        let s = await mediaLibrary.requestAuthorization()
                        if s == .authorized || s == .limited { onNext() }
                    }
                } label: {
                    Text("Allow Access").font(.headline).frame(maxWidth: .infinity).padding()
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                Button("Skip for Now", action: onNext).foregroundStyle(.secondary)
            }.padding(.horizontal, 32).padding(.bottom, 40)
        }
    }
}

// MARK: - Feature row

struct FeatureRow: View {
    let icon: String; let color: Color; let title: String; let detail: String
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.title2).foregroundStyle(color).frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
