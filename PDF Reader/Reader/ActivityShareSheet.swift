import SwiftUI
import UIKit

/// SwiftUI wrapper around `UIActivityViewController` for cases where
/// `ShareLink` isn't a clean fit (e.g. sharing a file generated on tap).
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
