import Foundation

/// Paywall — StoreKit 2 entitlements, subscription views, feature gating.
///
/// Owns: product configuration, transaction listening, entitlement state.
/// Consumed by: App (gates Edit, Sign, AI, non-iCloud Sync).
/// Depends on: DesignSystem.
enum Paywall {}
