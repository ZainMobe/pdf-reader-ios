import SwiftUI
import PDFKit
import UIKit

/// Renders a thumbnail of a document's first page, falling back to a
/// placeholder while it loads. Backed by an in-memory `NSCache` keyed by
/// document ID so the same image is reused across the grid + list views
/// and across re-renders during scroll. Re-fetches when the cache reports
/// an invalidation for this document (e.g. after a save in the Reader).
struct DocumentThumbnailView: View {
    let documentID: UUID
    let documentURL: URL
    /// Optional pre-rendered thumbnail bytes (JPEG) stored on the `Document`
    /// model. Preferred over live PDFKit rendering because it works offline
    /// and survives iCloud-placeholder files that haven't been downloaded.
    var thumbnailData: Data?
    var placeholderIconSize: CGFloat = 32

    @State private var image: UIImage?
    private let cache = ThumbnailCache.shared

    var body: some View {
        let version = cache.version(for: documentID)
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .background(.tertiary)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.small))
            } else {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.small)
                    .fill(.tertiary)
                    .overlay {
                        Image(systemName: "doc.text")
                            .font(.system(size: placeholderIconSize))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            ICloudSyncBadge(state: ICloudSyncMonitor.shared.state(for: documentID))
                .padding(DesignSystem.Spacing.xs)
        }
        .task(id: ThumbnailTaskKey(id: documentID, version: version)) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        if let cached = ThumbnailCache.shared.image(for: documentID) {
            image = cached
            return
        }
        // Prefer the persisted thumbnail: it works offline and is independent
        // of whether the underlying PDF has been downloaded from iCloud.
        if let data = thumbnailData, let decoded = UIImage(data: data) {
            ThumbnailCache.shared.set(decoded, for: documentID)
            image = decoded
            return
        }
        let url = documentURL
        let id = documentID
        let generated = await Task.detached(priority: .userInitiated) {
            ThumbnailGenerator.thumbnail(at: url, size: ThumbnailCache.targetSize)
        }.value
        guard let generated else { return }
        ThumbnailCache.shared.set(generated, for: id)
        image = generated
    }
}

private struct ThumbnailTaskKey: Hashable {
    let id: UUID
    let version: Int
}

/// Generates a first-page PDF thumbnail at a chosen size via PDFKit.
enum ThumbnailGenerator {
    /// Size used for persisted thumbnails. Picked to render crisply across
    /// grid + list rows without bloating SwiftData / CloudKit payloads.
    nonisolated static let persistedSize = CGSize(width: 240, height: 320)

    nonisolated static func thumbnail(at url: URL, size: CGSize) -> UIImage? {
        guard
            let pdf = PDFDocument(url: url),
            !pdf.isLocked,
            let page = pdf.page(at: 0)
        else { return nil }
        return page.thumbnail(of: size, for: .cropBox)
    }

    /// JPEG-encoded first-page thumbnail suitable for storing in
    /// `Document.thumbnailData`. Returns nil when the PDF isn't readable.
    nonisolated static func persistableThumbnailData(at url: URL) -> Data? {
        thumbnail(at: url, size: persistedSize)?.jpegData(compressionQuality: 0.7)
    }
}

/// Process-wide in-memory cache so the same first-page thumbnail isn't
/// rendered repeatedly as the user scrolls the grid or toggles list/grid.
/// `@Observable` so SwiftUI views that read `version(for:)` automatically
/// re-render (and re-run their `.task`) when a thumbnail is invalidated.
@Observable
final class ThumbnailCache: @unchecked Sendable {
    @MainActor static let shared = ThumbnailCache()
    /// Size requested from PDFKit. The card and list row downscale this as
    /// needed via `scaledToFit()`.
    nonisolated static let targetSize = CGSize(width: 240, height: 320)

    private let cache = NSCache<NSUUID, UIImage>()
    private var versions: [UUID: Int] = [:]

    private init() {
        cache.countLimit = 256
    }

    func image(for id: UUID) -> UIImage? {
        cache.object(forKey: id as NSUUID)
    }

    func set(_ image: UIImage, for id: UUID) {
        cache.setObject(image, forKey: id as NSUUID)
    }

    /// Bumps every time `invalidate(_:)` is called for this document. Views
    /// that read it become subscribed and will re-render on the next bump.
    func version(for id: UUID) -> Int {
        versions[id, default: 0]
    }

    func invalidate(_ id: UUID) {
        cache.removeObject(forKey: id as NSUUID)
        versions[id, default: 0] += 1
    }
}
