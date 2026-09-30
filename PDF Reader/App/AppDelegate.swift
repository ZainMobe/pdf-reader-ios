import UIKit

/// Minimal UIKit delegates so the SwiftUI app can receive Home Screen
/// Quick Actions (long-press the icon). Everything they do is expressed as
/// a `pdfeditor://` URL and handed to `IncomingFileRouter`, the same path
/// Shortcuts and widgets use.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Quick Action types declared in Info.plist (`UIApplicationShortcutItems`).
    enum QuickAction: String, CaseIterable {
        case scan = "com.wappltd.PDF-Reader.scan"
        case importFiles = "com.wappltd.PDF-Reader.import"
        case ask = "com.wappltd.PDF-Reader.ask"
        case tools = "com.wappltd.PDF-Reader.tools"

        var url: URL {
            switch self {
            case .scan: URL(string: "pdfeditor://scan")!
            case .importFiles: URL(string: "pdfeditor://import")!
            case .ask: URL(string: "pdfeditor://ask")!
            case .tools: URL(string: "pdfeditor://tools")!
            }
        }
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // Cold launch from a Quick Action. The router queues the action until
        // RootView appears.
        if let item = connectionOptions.shortcutItem {
            handle(item)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(handle(shortcutItem))
    }

    @discardableResult
    private func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard let action = QuickAction(rawValue: item.type) else { return false }
        Task { @MainActor in
            IncomingFileRouter.shared.handleAppScheme(action.url)
        }
        return true
    }
}
