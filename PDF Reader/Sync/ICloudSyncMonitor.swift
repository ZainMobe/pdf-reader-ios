import Foundation
import SwiftUI

/// Per-document iCloud sync state surfaced to the UI.
enum ICloudSyncState: Equatable {
    /// File is fully uploaded and locally materialized.
    case synced
    /// File exists in iCloud but is only a placeholder on this device; opening
    /// will trigger a download.
    case placeholder
    /// Local file is being pushed up to iCloud.
    case uploading(progress: Double)
    /// Remote file is being pulled down to this device.
    case downloading(progress: Double)
    /// iCloud is unavailable (signed out or container provisioning failed).
    /// File lives in the local Application Support fallback.
    case localOnly

    var isInProgress: Bool {
        switch self {
        case .uploading, .downloading: true
        case .synced, .placeholder, .localOnly: false
        }
    }
}

/// Watches the iCloud ubiquity container via `NSMetadataQuery` and publishes
/// per-document upload/download status. UI components observe `states` and
/// `inProgressCount` to render badges and the "Syncing…" pill.
///
/// Started once from `LibraryHomeView` and runs for the rest of the app
/// lifecycle. A no-op when storage is local-only.
@MainActor
@Observable
final class ICloudSyncMonitor {
    static let shared = ICloudSyncMonitor()

    private(set) var states: [UUID: ICloudSyncState] = [:]
    private(set) var inProgressCount: Int = 0

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Default state for a document the query hasn't reported on yet. Defaults
    /// to optimistic `.synced` for iCloud and `.localOnly` for local storage.
    func state(for documentID: UUID) -> ICloudSyncState {
        if let known = states[documentID] { return known }
        return DocumentStorage.isUsingICloud ? .synced : .localOnly
    }

    func start() {
        guard query == nil else { return }
        guard DocumentStorage.isUsingICloud else { return }

        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(format: "%K LIKE '*.pdf'", NSMetadataItemFSNameKey)
        q.valueListAttributes = [
            NSMetadataItemFSNameKey,
            NSMetadataUbiquitousItemIsUploadedKey,
            NSMetadataUbiquitousItemIsUploadingKey,
            NSMetadataUbiquitousItemPercentUploadedKey,
            NSMetadataUbiquitousItemDownloadingStatusKey,
            NSMetadataUbiquitousItemIsDownloadingKey,
            NSMetadataUbiquitousItemPercentDownloadedKey,
        ]

        let center = NotificationCenter.default
        let refresh: @Sendable (Notification) -> Void = { _ in
            Task { @MainActor in
                ICloudSyncMonitor.shared.refreshFromQuery()
            }
        }
        observers.append(center.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: q,
            queue: .main,
            using: refresh
        ))
        observers.append(center.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: q,
            queue: .main,
            using: refresh
        ))

        q.start()
        query = q
    }

    private func refreshFromQuery() {
        guard let query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        var newStates: [UUID: ICloudSyncState] = [:]
        var inProgress = 0

        for case let item as NSMetadataItem in query.results {
            guard
                let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String,
                name.hasSuffix(".pdf")
            else { continue }
            let stem = (name as NSString).deletingPathExtension
            guard let id = UUID(uuidString: stem) else { continue }

            let isUploaded = item.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey) as? Bool ?? true
            let isUploading = item.value(forAttribute: NSMetadataUbiquitousItemIsUploadingKey) as? Bool ?? false
            let uploadPercent = item.value(forAttribute: NSMetadataUbiquitousItemPercentUploadedKey) as? Double ?? 0

            let downloadingStatus = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            let isDownloaded = downloadingStatus == NSMetadataUbiquitousItemDownloadingStatusCurrent
                || downloadingStatus == NSMetadataUbiquitousItemDownloadingStatusDownloaded
            let isDownloading = item.value(forAttribute: NSMetadataUbiquitousItemIsDownloadingKey) as? Bool ?? false
            let downloadPercent = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double ?? 0

            let state: ICloudSyncState
            if isUploading || !isUploaded {
                state = .uploading(progress: uploadPercent / 100)
                inProgress += 1
            } else if isDownloading {
                state = .downloading(progress: downloadPercent / 100)
                inProgress += 1
            } else if !isDownloaded {
                state = .placeholder
            } else {
                state = .synced
            }
            newStates[id] = state
        }

        states = newStates
        inProgressCount = inProgress
    }
}

/// Compact corner badge for `DocumentThumbnailView`. Only renders for states
/// that diverge from the happy path — fully synced documents show nothing so
/// the grid doesn't get visually noisy.
struct ICloudSyncBadge: View {
    let state: ICloudSyncState

    var body: some View {
        if let symbol {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.thinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var symbol: String? {
        switch state {
        case .synced, .localOnly: nil
        case .placeholder: "icloud.and.arrow.down"
        case .uploading: "icloud.and.arrow.up"
        case .downloading: "arrow.down.circle.dotted"
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .synced: "Synced to iCloud"
        case .localOnly: "Stored on this device"
        case .placeholder: "Not downloaded — tap to download from iCloud"
        case .uploading(let progress): "Uploading to iCloud, \(Int(progress * 100)) percent"
        case .downloading(let progress): "Downloading from iCloud, \(Int(progress * 100)) percent"
        }
    }
}
