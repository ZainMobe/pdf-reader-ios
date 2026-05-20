import Foundation

struct ICloudProvider: CloudStorageProvider {
    let id = "icloud"
    let displayName = "iCloud Drive"
    let iconSystemName = "icloud"
    var isInstalled: Bool { FileManager.default.ubiquityIdentityToken != nil }
    let isSupported = true
}

struct DropboxProvider: CloudStorageProvider {
    let id = "dropbox"
    let displayName = "Dropbox"
    let iconSystemName = "shippingbox"
    var isInstalled: Bool { DropboxAuthManager.shared.isSignedIn }
    var isSupported: Bool { DropboxAuthManager.shared.isConfigured }
}

struct GoogleDriveProvider: CloudStorageProvider {
    let id = "googledrive"
    let displayName = "Google Drive"
    let iconSystemName = "externaldrive.connected.to.line.below"
    let isInstalled = false
    let isSupported = false
}

struct OneDriveProvider: CloudStorageProvider {
    let id = "onedrive"
    let displayName = "OneDrive"
    let iconSystemName = "cloud"
    let isInstalled = false
    let isSupported = false
}

enum AvailableProviders {
    static let all: [any CloudStorageProvider] = [
        ICloudProvider(),
        DropboxProvider(),
        GoogleDriveProvider(),
        OneDriveProvider(),
    ]
}
