import SwiftUI
import PDFKit
import UIKit

/// Renders a thumbnail of a document's first page, falling back to a
/// placeholder while it loads. Backed by an in-memory `NSCache` keyed by
/// document ID so the same image is reused across the grid + list views
/// and across re-renders during scroll.
struct DocumentThumbnailView: View {
    let documentID: UUID
    let documentURL: URL
    var placeholderIconSize: CGFloat = 32

    @State private var image: UIImage?

    var body: some View {
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
        .task(id: documentID) {
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
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    /// Size requested from PDFKit. The card and list row downscale this as
    /// needed via `scaledToFit()`.
    static let targetSize = CGSize(width: 240, height: 320)

    private let cache = NSCache<NSUUID, UIImage>()

    private init() {
        cache.countLimit = 256
    }

    func image(for id: UUID) -> UIImage? {
        cache.object(forKey: id as NSUUID)
    }

    func set(_ image: UIImage, for id: UUID) {
        cache.setObject(image, forKey: id as NSUUID)
    }

    func invalidate(_ id: UUID) {
        cache.removeObject(forKey: id as NSUUID)
    }
}
