import SwiftUI
import PDFKit

/// Renders a small thumbnail of a `PDFPage`. Falls back to a placeholder
/// rectangle if the page or its thumbnail can't be produced.
struct PageThumbnail: View {
    let page: PDFPage?
    var size: CGSize = CGSize(width: 80, height: 120)

    var body: some View {
        Group {
            if let image = page?.thumbnail(of: size, for: .cropBox) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.small)
                    .fill(.tertiary)
            }
        }
    }
}
