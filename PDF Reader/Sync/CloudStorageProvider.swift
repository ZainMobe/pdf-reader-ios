import Foundation

/// Abstraction for a cloud storage source the app can pull PDFs from or
/// sync metadata with. Concrete providers (iCloud, Dropbox, Drive, OneDrive)
/// expose enough metadata for the Settings UI to render and gate behind a
/// "Coming Soon" pill while SDK work happens.
///
/// File import from any installed File Provider already works through the
/// system `.fileImporter` in `LibraryHomeView`; these providers are about
/// first-class sync, not just import.
protocol CloudStorageProvider: Identifiable {
    var id: String { get }
    var displayName: String { get }
    var iconSystemName: String { get }

    /// Whether the underlying account or app is reachable on this device.
    var isInstalled: Bool { get }

    /// Whether deep sync (not just import) is wired up.
    var isSupported: Bool { get }
}
