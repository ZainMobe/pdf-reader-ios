import Foundation

final class ReadingSessionTracker {
    private var startedAt: Date?
    private var pages = Set<Int>()
    private var accumulatedSeconds = 0
    private(set) var didLogOpen = false

    func markOpened() {
        didLogOpen = true
    }

    func resume() {
        guard startedAt == nil else { return }
        startedAt = Date()
    }

    func pause() {
        guard let startedAt else { return }
        accumulatedSeconds += AppAnalytics.seconds(since: startedAt)
        self.startedAt = nil
    }

    func pageViewed(_ index: Int) {
        pages.insert(index)
    }

    func finish(pageCount: Int, theme: String, displayMode: String) {
        pause()
        defer {
            accumulatedSeconds = 0
            pages.removeAll()
        }
        guard didLogOpen, accumulatedSeconds >= 2 else { return }
        let viewed = max(pages.count, 1)
        AppAnalytics.log(.readingSession, [
            .seconds: min(accumulatedSeconds, 6 * 3600),
            .pagesViewed: viewed,
            .pageBucket: AppAnalytics.pageBucket(pageCount),
            .percentRead: pageCount > 0 ? min(100, viewed * 100 / pageCount) : nil,
            .theme: theme,
            .displayMode: displayMode,
        ])
    }
}
