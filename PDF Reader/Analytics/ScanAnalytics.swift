import Foundation
import SwiftData

enum ScanAnalytics {
    static func completed(pages: Int, source: AnalyticsSource, startedAt: Date, context: ModelContext? = nil) {
        AppAnalytics.log(.scanCompleted, [
            .source: source.rawValue,
            .pageBucket: AppAnalytics.pageBucket(pages),
            .count: pages,
            .durationMs: AppAnalytics.milliseconds(since: startedAt),
        ])
        AppAnalytics.feature(source == .toolsTab ? .toolScan : .scan, source: source.rawValue, [.count: pages])
        if let context { AnalyticsUserProperties.refreshLibrary(in: context) }
    }

    static func failed(_ error: Error, source: AnalyticsSource) {
        AppAnalytics.log(.scanFailed, [.source: source.rawValue, .errorType: AppAnalytics.errorLabel(error)])
    }
}
