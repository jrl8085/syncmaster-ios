import SwiftUI
import Photos

struct LibraryView: View {
    @EnvironmentObject var mediaLibrary: MediaLibraryService
    @EnvironmentObject var syncEngine: SyncEngine
    @State private var filter: FilterOption = .all

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 130), spacing: 2)]

    enum FilterOption: String, CaseIterable {
        case all = "All", pending = "Pending", uploaded = "Backed Up", videos = "Videos", failed = "Failed"
    }

    var filtered: [MediaItem] {
        switch filter {
        case .all: return mediaLibrary.allAssets
        case .pending: return mediaLibrary.allAssets.filter { !syncEngine.failedIdentifiers.contains($0.id) && $0.isPending }
        case .uploaded: return mediaLibrary.allAssets.filter { $0.isUploaded }
        case .videos: return mediaLibrary.allAssets.filter { $0.asset.mediaType == .video }
        case .failed: return mediaLibrary.allAssets.filter { syncEngine.failedIdentifiers.contains($0.id) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch mediaLibrary.authorizationStatus {
                case .authorized, .limited: content
                case .notDetermined:
                    ContentUnavailableView {
                        Label("Photo Access Required", systemImage: "photo.on.rectangle.angled")
                    } description: { Text("SyncMaster needs access to back up your media.") } actions: {
                        Button("Grant Access") { Task { await mediaLibrary.requestAuthorization() } }
                            .buttonStyle(.borderedProminent)
                    }
                default:
                    ContentUnavailableView {
                        Label("Access Denied", systemImage: "lock.shield")
                    } description: { Text("Enable photo access in Settings → Privacy → Photos.") } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if mediaLibrary.isLoading { ProgressView().controlSize(.small) }
                    else { Button { Task { await mediaLibrary.loadAssets() } } label: { Image(systemName: "arrow.clockwise") } }
                }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FilterOption.allCases, id: \.self) { opt in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { filter = opt }
                        } label: {
                            HStack(spacing: 4) {
                                Text(opt.rawValue)
                                    .font(.subheadline.weight(filter == opt ? .semibold : .regular))
                                if opt == .failed, !syncEngine.failedIdentifiers.isEmpty {
                                    Text("\(syncEngine.failedIdentifiers.count)")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(.red, in: Capsule())
                                        .foregroundStyle(.white)
                                }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(
                                opt == .failed && filter != opt
                                    ? (!syncEngine.failedIdentifiers.isEmpty ? Color.red.opacity(0.12) : Color(.secondarySystemFill))
                                    : (filter == opt ? Color.accentColor : Color(.secondarySystemFill)),
                                in: Capsule()
                            )
                            .foregroundStyle(filter == opt ? .white : .primary)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal).padding(.vertical, 8)
            }.background(Color(.systemBackground))

            if filtered.isEmpty {
                ContentUnavailableView("No Media", systemImage: "photo.on.rectangle.angled",
                                       description: Text("Nothing matches this filter."))
                    .padding(.top, 60)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(filtered) { item in ThumbnailCell(item: item) }
                    }
                }
            }
        }
    }
}

// MARK: - Thumbnail Cell

struct ThumbnailCell: View {
    let item: MediaItem
    @State private var thumbnail: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let img = thumbnail {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Color(.systemFill))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.width).clipped()

                // Type badge
                if item.asset.mediaType == .video {
                    Image(systemName: item.mediaType == .slowMo ? "gauge.with.dots.needle.67percent" : "video.fill")
                        .font(.caption2).foregroundStyle(.white)
                        .padding(4).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                } else if item.mediaType == .livePhotoImage {
                    Image(systemName: "livephoto").font(.caption2).foregroundStyle(.white)
                        .padding(4).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }

                // Upload state
                switch item.uploadState {
                case .uploaded:
                    VStack { HStack { Spacer()
                        Image(systemName: "checkmark.icloud.fill").font(.caption).foregroundStyle(.white)
                            .padding(4).background(.green.opacity(0.85), in: Circle()).padding(4)
                    }; Spacer() }
                case .uploading(let p):
                    VStack { Spacer()
                        Rectangle().fill(.blue.opacity(0.7)).frame(height: 3)
                            .frame(maxWidth: geo.size.width * p, alignment: .leading)
                    }
                case .failed:
                    VStack { HStack { Spacer()
                        Image(systemName: "exclamationmark.icloud.fill").font(.caption).foregroundStyle(.white)
                            .padding(4).background(.red.opacity(0.85), in: Circle()).padding(4)
                    }; Spacer() }
                default: EmptyView()
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .task { thumbnail = await loadThumb() }
    }

    func loadThumb() async -> UIImage? {
        await withCheckedContinuation { cont in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.isNetworkAccessAllowed = true
            opts.resizeMode = .fast
            var resumed = false
            PHImageManager.default().requestImage(
                for: item.asset, targetSize: CGSize(width: 150, height: 150),
                contentMode: .aspectFill, options: opts
            ) { img, info in
                // .opportunistic fires twice (degraded preview, then final).
                // Only resume on the final result to avoid crashing the continuation.
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded, !resumed {
                    resumed = true
                    cont.resume(returning: img)
                }
            }
        }
    }
}
