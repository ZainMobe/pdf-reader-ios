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
        .task(id: ThumbnailTaskKey(id: documentID, version: version)) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        if let cached = ThumbnailCache.shared.image(for: documentID) {
            image = cached
            return
        }
        let url = documentURL
        let id = documentID
        let generated = await Task.detached(priority: .userInitiated) {
            await ThumbnailGenerator.thumbnail(at: url, size: ThumbnailCache.targetSize)
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
    static func thumbnail(at url: URL, size: CGSize) -> UIImage? {
        guard
            let pdf = PDFDocument(url: url),
            !pdf.isLocked,
            let page = pdf.page(at: 0)
        else { return nil }
        return page.thumbnail(of: size, for: .cropBox)
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
    static let targetSize = CGSize(width: 240, height: 320)

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
