import SwiftUI
import SwiftData
import RevenueCat

@main
struct PDFAIApp: App {
    private let modelContainer: ModelContainer?
    private let bootError: String?

    init() {
        // Configure RevenueCat first so the EntitlementStore singleton can
        // query Purchases.shared right after launch. API key is injected
        // into Info.plist via the active xcconfig (Config_Staging / Config_Prod).
        Self.configureRevenueCat()

        let schema = Schema([
            Document.self,
            Folder.self,
            Tag.self,
            SignatureAsset.self,
            Bookmark.self,
        ])

        // Prefer CloudKit when the iCloud capability is wired up; fall back
        // to local-only so the app still launches if the container hasn't
        // finished provisioning. Only when both fail do we land in the
        // recoverable boot-error scene.
        if let cloud = try? ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
        ) {
            modelContainer = cloud
            bootError = nil
        } else {
            do {
                modelContainer = try ModelContainer(
                    for: schema,
                    configurations: ModelConfiguration(schema: schema)
                )
                bootError = nil
            } catch {
                modelContainer = nil
                bootError = error.localizedDescription
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            if let modelContainer {
                RootView()
                    .modelContainer(modelContainer)
            } else {
                BootErrorView(message: bootError ?? "Couldn't open the document database.")
            }
        }

        // Per-document windows. Opened via `openWindow(value: document.id)`
        // from the Library and Reader.
        WindowGroup("Document", for: UUID.self) { $documentID in
            if let modelContainer {
                DocumentWindowView(documentID: documentID)
                    .modelContainer(modelContainer)
            } else {
                BootErrorView(message: bootError ?? "Couldn't open the document database.")
            }
        }
    }

    private static func configureRevenueCat() {
        guard
            let apiKey = Bundle.main.object(forInfoDictionaryKey: "REVENUECAT_API_KEY") as? String,
            !apiKey.isEmpty,
            !apiKey.contains("REPLACE_WITH")
        else {
            // Either the xcconfig isn't bound to this build configuration yet
            // or the placeholder hasn't been filled in. Paywall + entitlement
            // checks will just report "not subscribed" until this is fixed.
            return
        }

        #if STAGING
        Purchases.logLevel = .info
        #else
        Purchases.logLevel = .warn
        #endif
        Purchases.configure(withAPIKey: apiKey)
    }
}
