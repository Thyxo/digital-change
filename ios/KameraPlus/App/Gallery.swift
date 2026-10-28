import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct GalleryItem: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var isVideo: Bool { url.pathExtension.lowercased() == "mov" }
}

/// Appens eget galleri (Application Support/Galleri). Gem i Fotos er valgfrit (kun tilføj).
@MainActor
final class PhotoStore: ObservableObject {
    @Published private(set) var items: [GalleryItem] = []
    @Published private(set) var thumbnail: UIImage?
    let dir: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("Galleri", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        items = files.filter { ["jpg", "mov"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { GalleryItem(url: $0) }
        updateThumbnail()
    }

    private func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: Date())
    }

    func newVideoURL() -> URL { dir.appendingPathComponent("IMG-\(stamp()).mov") }

    func savePhoto(_ image: CGImage, orientation: UIImage.Orientation, toPhotos: Bool) {
        let url = dir.appendingPathComponent("IMG-\(stamp()).jpg")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ui = UIImage(cgImage: image, scale: 1, orientation: orientation)
            guard let data = ui.jpegData(compressionQuality: 0.92) else { return }
            try? data.write(to: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if toPhotos { UIImageWriteToSavedPhotosAlbum(ui, nil, nil, nil) }
                    self?.reload()
                }
            }
        }
    }

    func addVideo(_ url: URL, toPhotos: Bool) {
        if toPhotos && UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(url.path) {
            UISaveVideoAtPathToSavedPhotosAlbum(url.path, nil, nil, nil)
        }
        reload()
    }

    func delete(_ item: GalleryItem) {
        try? FileManager.default.removeItem(at: item.url)
        reload()
    }

    private func updateThumbnail() {
        guard let last = items.last else { thumbnail = nil; return }
        if last.isVideo {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: last.url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 160, height: 160)
            gen.generateCGImageAsynchronously(for: .zero) { [weak self] cg, _, _ in
                guard let cg else { return }
                let img = UIImage(cgImage: cg)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.thumbnail = img } }
            }
        } else {
            thumbnail = PhotoStore.downscaled(UIImage(contentsOfFile: last.url.path), 160)
        }
    }

    static func downscaled(_ img: UIImage?, _ side: CGFloat) -> UIImage? {
        guard let img else { return nil }
        let k = side / max(img.size.width, img.size.height)
        let size = CGSize(width: img.size.width * k, height: img.size.height * k)
        return UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

/// Simpel fotovisning af appens egne billeder og videoer.
struct GalleryView: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var store: PhotoStore
    @State private var selection: URL?
    @State private var confirmDelete = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if store.items.isEmpty {
                Text(CameraText.noPhotos).foregroundStyle(.secondary)
            } else {
                TabView(selection: $selection) {
                    ForEach(store.items) { item in
                        GalleryPage(item: item).tag(Optional(item.url))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }
            VStack {
                HStack {
                    Button { engine.galleryOpen = false } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                    }
                    .accessibilityIdentifier("galleryBack")
                    Spacer()
                    if selection != nil {
                        Button { confirmDelete = true } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 18))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(Color.white.opacity(0.12)))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
        }
        .statusBarHidden(true)
        .onAppear { selection = store.items.last?.url }
        .confirmationDialog(CameraText.deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(CameraText.delete, role: .destructive) {
                if let url = selection, let item = store.items.first(where: { $0.url == url }) {
                    let idx = store.items.firstIndex(of: item) ?? 0
                    store.delete(item)
                    selection = store.items.isEmpty ? nil : store.items[min(idx, store.items.count - 1)].url
                }
            }
        }
    }
}

private struct GalleryPage: View {
    let item: GalleryItem
    @State private var image: UIImage?

    var body: some View {
        Group {
            if item.isVideo {
                VideoPlayer(player: AVPlayer(url: item.url))
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.black
            }
        }
        .onAppear {
            if !item.isVideo && image == nil { image = UIImage(contentsOfFile: item.url.path) }
        }
    }
}
