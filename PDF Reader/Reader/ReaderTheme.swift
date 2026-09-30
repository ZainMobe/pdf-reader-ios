import PDFKit
import SwiftUI
import UIKit

/// Page rendering themes for the Reader.
///
/// Implemented at the PDFKit page-drawing level (a `PDFPage` subclass
/// installed through `PDFDocumentDelegate.classForPage`) so the effect is
/// exact at every zoom level, applies to thumbnails in the sidebar, and
/// costs nothing when the theme is `.light`.
enum ReaderTheme: String, CaseIterable, Identifiable {
    /// Original colours.
    case light
    /// Warm paper tint, black text unchanged. Easy on the eyes in daylight.
    case sepia
    /// Every colour dimmed to ~70%: images keep their look, whites go grey.
    case dim
    /// Full inversion: white paper becomes near-black, text becomes light.
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .light: "Light"
        case .sepia: "Sepia"
        case .dim: "Dim"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .light: "sun.max"
        case .sepia: "book.closed"
        case .dim: "circle.lefthalf.filled"
        case .dark: "moon.stars"
        }
    }

    /// Background behind and between pages.
    var viewBackground: UIColor {
        switch self {
        case .light: .systemGroupedBackground
        case .sepia: UIColor(red: 0.90, green: 0.85, blue: 0.75, alpha: 1)
        case .dim: UIColor(white: 0.16, alpha: 1)
        case .dark: UIColor(white: 0.05, alpha: 1)
        }
    }

    /// Colour used with the given blend mode over the drawn page.
    fileprivate var overlay: (color: UIColor, blend: CGBlendMode)? {
        switch self {
        case .light: nil
        case .sepia: (UIColor(red: 0.96, green: 0.91, blue: 0.80, alpha: 1), .multiply)
        case .dim: (UIColor(white: 0.72, alpha: 1), .multiply)
        case .dark: (UIColor.white, .difference)
        }
    }

    var prefersDarkChrome: Bool { self == .dark || self == .dim }

    static let storageKey = "settings.readerTheme"

    static var current: ReaderTheme {
        ReaderTheme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .light
    }
}

/// `PDFPage` subclass that applies the active theme after drawing the
/// page's own content and annotations. PDFKit instantiates it for every
/// page of a document whose delegate returns it from `classForPage()`.
final class ThemedPDFPage: PDFPage {
    /// Read on PDFKit's render threads; written only from the main thread
    /// right before the view is asked to redraw.
    nonisolated(unsafe) static var theme: ReaderTheme = .light

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)
        guard let overlay = Self.theme.overlay else { return }
        context.saveGState()
        context.setBlendMode(overlay.blend)
        context.setFillColor(overlay.color.cgColor)
        context.fill(bounds(for: box))
        context.restoreGState()
    }
}

/// Installs `ThemedPDFPage` on documents shown in the Reader.
final class ThemedDocumentDelegate: NSObject, PDFDocumentDelegate {
    static let shared = ThemedDocumentDelegate()

    func classForPage() -> AnyClass {
        ThemedPDFPage.self
    }
}

extension PDFView {
    /// Applies `theme` and forces a redraw of the visible pages.
    @MainActor
    func applyReaderTheme(_ theme: ReaderTheme) {
        ThemedPDFPage.theme = theme
        backgroundColor = theme.viewBackground
        // PDFView caches rendered page tiles; reassigning the document is the
        // reliable way to drop them. Keep the user's place.
        if let document {
            let page = currentPage
            self.document = document
            if let page { go(to: page) }
        }
    }
}
