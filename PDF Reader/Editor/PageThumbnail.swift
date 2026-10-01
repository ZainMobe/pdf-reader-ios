import SwiftUI
import PDFKit

/// Renders a small thumbnail of a `PDFPage`. Falls back to a placeholder
/// rectangle while rendering or if the page can't be drawn.
///
/// Rendering happens off the main thread in a task keyed by the page's
/// identity and rotation, so scrolling a grid of thumbnails doesn't
/// re-rasterise every visible page on each layout pass.
struct PageThumbnail: View {
    let page: PDFPage?
    var size: CGSize = CGSize(width: 80, height: 120)

    @State private var image: UIImage?

    private struct RenderKey: Hashable {
        let page: ObjectIdentifier?
        let rotation: Int
        let width: CGFloat
        let height: CGFloat
    }

    private var renderKey: RenderKey {
        RenderKey(
            page: page.map(ObjectIdentifier.init),
            rotation: page?.rotation ?? 0,
            width: size.width,
            height: size.height
        )
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.small)
                    .fill(.tertiary)
            }
        }
        .task(id: renderKey) {
            guard let page else {
                image = nil
                return
            }
            let targetSize = size
            let rendered = await Task.detached(priority: .userInitiated) {
                page.thumbnail(of: targetSize, for: .cropBox)
            }.value
            guard !Task.isCancelled else { return }
            image = rendered
        }
    }
}
