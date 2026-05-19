import Foundation

/// Sync — Cloud storage providers behind a single protocol.
///
/// Owns: iCloud Drive provider (native), Dropbox/Google Drive/OneDrive adapters,
/// upload/download queue, conflict resolution.
/// Consumed by: Library.
/// Depends on: nothing app-specific (pure infrastructure).
enum Sync {}
