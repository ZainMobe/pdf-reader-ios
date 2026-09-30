import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Principal class of the Share Extension. Hosts the SwiftUI sheet and
/// bridges completion/cancellation back to the extension context.
///
/// The extension does the minimum: copy the shared files into the App
/// Group inbox and write a manifest. All conversion and importing happens
/// in the main app, which keeps this process fast and far below the
/// extension memory ceiling even for twenty camera photos.
final class ShareViewController: UIViewController {
    private var model: ShareModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let model = ShareModel(
            extensionItems: items,
            sourceAppName: nil,
            onFinish: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.cancel() }
        )
        self.model = model

        let host = UIHostingController(rootView: ShareSheetView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        preferredContentSize = CGSize(width: 420, height: 560)
        Task { await model.load() }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        model?.discard()
        let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        extensionContext?.cancelRequest(withError: error)
    }

}
