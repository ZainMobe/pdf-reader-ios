import SwiftUI
import UIKit

/// Sheet that renders structured data extracted from the document via
/// `DocumentExtractor`. Empty fields are hidden so the result reads cleanly.
struct ExtractSheet: View {
    let document: Document
    @State private var extractor = DocumentExtractor()
    @State private var copiedAll = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(DesignSystem.Spacing.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Extracted Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "sparkles")
                        Text("On-device")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if case .done(let data) = extractor.state {
                        Button {
                            copyAll(data)
                        } label: {
                            Label(
                                copiedAll ? "Copied" : "Copy All",
                                systemImage: copiedAll ? "checkmark" : "doc.on.doc"
                            )
                            .contentTransition(.symbolEffect(.replace))
                        }
                        .accessibilityLabel(copiedAll ? "Copied" : "Copy All")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { extractor.extract(document) }
            .onDisappear { extractor.cancel() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch extractor.state {
        case .idle, .loading:
            VStack(spacing: DesignSystem.Spacing.m) {
                ProgressView()
                Text("Analyzing document…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, DesignSystem.Spacing.xxl)
        case .done(let data):
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.l) {
                Text(data.subject.isEmpty ? document.title : data.subject)
                    .font(.title2.weight(.semibold))

                if !data.dates.isEmpty {
                    ExtractedSection(
                        title: "Dates",
                        systemImage: "calendar",
                        items: data.dates
                    )
                }
                if !data.entities.isEmpty {
                    ExtractedSection(
                        title: "People & Organizations",
                        systemImage: "person.2",
                        items: data.entities
                    )
                }
                if !data.amounts.isEmpty {
                    ExtractedSection(
                        title: "Amounts",
                        systemImage: "dollarsign.circle",
                        items: data.amounts
                    )
                }
                if !data.keyPoints.isEmpty {
                    ExtractedSection(
                        title: "Key Points",
                        systemImage: "list.bullet",
                        items: data.keyPoints
                    )
                }
                if data.dates.isEmpty && data.entities.isEmpty && data.amounts.isEmpty && data.keyPoints.isEmpty {
                    Text("Nothing structured to extract.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            ContentUnavailableView(
                "Extraction failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }

    private func copyAll(_ data: ExtractedData) {
        UIPasteboard.general.string = formatted(data)
        Haptics.success()
        withAnimation(DesignSystem.Motion.snappy) { copiedAll = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(DesignSystem.Motion.snappy) { copiedAll = false }
        }
    }

    private func formatted(_ data: ExtractedData) -> String {
        var lines: [String] = []
        let subject = data.subject.isEmpty ? document.title : data.subject
        lines.append(subject)
        lines.append("")
        appendSection(&lines, title: "Dates", items: data.dates)
        appendSection(&lines, title: "People & Organizations", items: data.entities)
        appendSection(&lines, title: "Amounts", items: data.amounts)
        appendSection(&lines, title: "Key Points", items: data.keyPoints)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendSection(_ lines: inout [String], title: String, items: [String]) {
        guard !items.isEmpty else { return }
        lines.append(title)
        for item in items {
            lines.append("• \(item)")
        }
        lines.append("")
    }
}

private struct ExtractedSection: View {
    let title: String
    let systemImage: String
    let items: [String]

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.s) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    copy()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(copied ? .green : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied \(title)" : "Copy \(title)")
            }
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.s) {
                        Text("•").foregroundStyle(.tint)
                        Text(item)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(DesignSystem.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
    }

    private func copy() {
        UIPasteboard.general.string = items.map { "• \($0)" }.joined(separator: "\n")
        Haptics.selection()
        withAnimation(DesignSystem.Motion.snappy) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(DesignSystem.Motion.snappy) { copied = false }
        }
    }
}
