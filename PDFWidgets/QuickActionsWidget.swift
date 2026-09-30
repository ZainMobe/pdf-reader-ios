import SwiftUI
import WidgetKit

/// Home Screen shortcuts into the app: Scan, Import, Ask, Tools.
struct QuickActionsWidget: Widget {
    let kind = "QuickActions"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StaticProvider()) { _ in
            QuickActionsView()
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Quick Actions")
        .description("Scan, import, or ask your Library in one tap.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct StaticEntry: TimelineEntry {
    let date: Date
}

struct StaticProvider: TimelineProvider {
    func placeholder(in context: Context) -> StaticEntry { StaticEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (StaticEntry) -> Void) {
        completion(StaticEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StaticEntry>) -> Void) {
        completion(Timeline(entries: [StaticEntry(date: .now)], policy: .never))
    }
}

struct QuickActionsView: View {
    @Environment(\.widgetFamily) private var family

    private struct Action: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let url: URL
    }

    private let actions: [Action] = [
        Action(id: "scan", title: "Scan", symbol: "doc.viewfinder", url: URL(string: "pdfeditor://scan")!),
        Action(id: "import", title: "Import", symbol: "square.and.arrow.down", url: URL(string: "pdfeditor://import")!),
        Action(id: "ask", title: "Ask", symbol: "sparkle.magnifyingglass", url: URL(string: "pdfeditor://ask")!),
        Action(id: "tools", title: "Tools", symbol: "wrench.and.screwdriver", url: URL(string: "pdfeditor://tools")!),
    ]

    var body: some View {
        if family == .systemSmall {
            // Small widgets ignore Link; the whole widget is one tap target.
            VStack(spacing: 8) {
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("Scan")
                    .font(.headline)
                Text("Tap to open the scanner")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .widgetURL(URL(string: "pdfeditor://scan"))
        } else {
            grid
        }
    }

    private var grid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(actions) { action in
                Link(destination: action.url) {
                    VStack(spacing: 6) {
                        Image(systemName: action.symbol)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.tint)
                        Text(action.title)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 70)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }
}

/// Lock Screen / StandBy: one-tap scan.
struct ScanLockScreenWidget: Widget {
    let kind = "ScanLockScreen"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StaticProvider()) { _ in
            ScanAccessoryView()
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "pdfeditor://scan"))
        }
        .configurationDisplayName("Scan")
        .description("Open the scanner from your Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct ScanAccessoryView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "doc.viewfinder").font(.title3)
                VStack(alignment: .leading) {
                    Text("Scan Document").font(.headline)
                    Text("PDF Editor").font(.caption2).foregroundStyle(.secondary)
                }
            }
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "doc.viewfinder").font(.title2)
            }
        }
    }
}
