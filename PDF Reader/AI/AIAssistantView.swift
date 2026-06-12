import SwiftUI
import SwiftData
import FoundationModels

/// AI — On-device Foundation Models hub.
///
/// Two entry vectors:
///   1. Pick an action (Summarize, Chat, etc.) → pick a PDF → AI sheet opens.
///   2. Pick a recent PDF → pick an action → AI sheet opens.
///
/// Free users see the same hub with lock badges on each action; taps surface
/// the paywall. When Apple Intelligence is unavailable on the device, falls
/// back to a `ContentUnavailableView` describing why.
struct AIAssistantView: View {
    private let model = SystemLanguageModel.default
    private let entitlements = EntitlementStore.shared

    @Query(sort: \Document.addedAt, order: .reverse) private var documents: [Document]

    @State private var showingPaywall = false

    // Sequential-sheet plumbing. SwiftUI can't present a second sheet while
    // the first is still dismissing, so each picker captures into an
    // intermediate `PendingLaunch?` and the `onDismiss` handler hands it
    // off to `pendingLaunch` (a `.sheet(item:)`) for the actual AI sheet.
    @State private var pickingDocForAction: AIAction?
    @State private var pickingActionForDoc: Document?
    @State private var pendingLaunch: PendingLaunch?
    @State private var capturedFromDocPicker: PendingLaunch?
    @State private var capturedFromActionPicker: PendingLaunch?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("AI")
                .navigationBarTitleDisplayMode(.large)
                .sheet(isPresented: $showingPaywall) {
                    PaywallView()
                }
                .sheet(
                    item: $pickingDocForAction,
                    onDismiss: launchFromDocPickerIfNeeded
                ) { action in
                    DocumentPickerSheet(
                        action: action,
                        documents: recents
                    ) { doc in
                        capturedFromDocPicker = PendingLaunch(action: action, document: doc)
                    }
                }
                .sheet(
                    item: $pickingActionForDoc,
                    onDismiss: launchFromActionPickerIfNeeded
                ) { doc in
                    ActionPickerSheet(document: doc) { action in
                        capturedFromActionPicker = PendingLaunch(action: action, document: doc)
                    }
                }
                .sheet(item: $pendingLaunch) { launch in
                    aiSheet(for: launch)
                }
        }
    }

    /// Documents sorted by most-recently-opened (falling back to addedAt for
    /// PDFs the user has never opened).
    private var recents: [Document] {
        documents.sorted { lhs, rhs in
            (lhs.lastOpenedAt ?? lhs.addedAt) > (rhs.lastOpenedAt ?? rhs.addedAt)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.availability {
        case .available:
            hub
        case .unavailable(.deviceNotEligible):
            unavailable(
                "Apple Intelligence isn't supported on this device.",
                systemImage: "sparkles.slash"
            )
        case .unavailable(.appleIntelligenceNotEnabled):
            unavailable(
                "Turn on Apple Intelligence in Settings to use AI features.",
                systemImage: "sparkles.slash"
            )
        case .unavailable(.modelNotReady):
            unavailable(
                "The on-device model is downloading. Try again in a few minutes.",
                systemImage: "arrow.down.circle"
            )
        case .unavailable:
            unavailable(
                "AI features are currently unavailable.",
                systemImage: "sparkles.slash"
            )
        }
    }

    // MARK: - Hub

    private var hub: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                hero
                actionsGrid
                if !recents.isEmpty {
                    recentSection
                }
                if !entitlements.isPro {
                    upsellCTA
                }
            }
            .padding(DesignSystem.Spacing.l)
            // Clear the floating Add FAB area at the bottom of the tab.
            .padding(.bottom, 100)
        }
        .background(backgroundGradient.ignoresSafeArea())
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.14), .clear],
            startPoint: .top,
            endPoint: .center
        )
    }

    private var hero: some View {
        HStack(spacing: DesignSystem.Spacing.m) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.accentColor.opacity(0.42), Color.accentColor.opacity(0.05)],
                            center: .center,
                            startRadius: 4,
                            endRadius: 44
                        )
                    )
                    .frame(width: 68, height: 68)
                Image(systemName: "sparkles")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, options: .repeat(.continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("On-device, private")
                    .font(.title3.weight(.semibold))
                Text("Powered by Apple Intelligence. Nothing leaves your iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var actionsGrid: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.s) {
            sectionHeader("What would you like to do?")
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: DesignSystem.Spacing.m),
                    GridItem(.flexible(), spacing: DesignSystem.Spacing.m)
                ],
                spacing: DesignSystem.Spacing.m
            ) {
                ForEach(AIAction.allCases) { action in
                    Button {
                        tap(action: action)
                    } label: {
                        AIActionCard(action: action, locked: !entitlements.isPro)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Recent PDFs")
                Spacer()
                Text("Tap to pick an action")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignSystem.Spacing.m) {
                    ForEach(Array(recents.prefix(12))) { doc in
                        Button {
                            tap(document: doc)
                        } label: {
                            RecentDocumentTile(document: doc)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var upsellCTA: some View {
        VStack(spacing: DesignSystem.Spacing.s) {
            Button {
                Haptics.impact(.medium)
                showingPaywall = true
            } label: {
                Label("Unlock AI Features", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystem.Spacing.s)
            }
            .buttonStyle(.glassProminent)
            Text("7-day free trial · Cancel anytime")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.4)
    }

    private func unavailable(_ message: String, systemImage: String) -> some View {
        ContentUnavailableView(
            "AI Unavailable",
            systemImage: systemImage,
            description: Text(message)
        )
    }

    // MARK: - Routing

    private func tap(action: AIAction) {
        Haptics.impact(.light)
        guard entitlements.isPro else {
            showingPaywall = true
            return
        }
        pickingDocForAction = action
    }

    private func tap(document: Document) {
        Haptics.impact(.light)
        guard entitlements.isPro else {
            showingPaywall = true
            return
        }
        pickingActionForDoc = document
    }

    private func launchFromDocPickerIfNeeded() {
        if let captured = capturedFromDocPicker {
            pendingLaunch = captured
            capturedFromDocPicker = nil
        }
    }

    private func launchFromActionPickerIfNeeded() {
        if let captured = capturedFromActionPicker {
            pendingLaunch = captured
            capturedFromActionPicker = nil
        }
    }

    @ViewBuilder
    private func aiSheet(for launch: PendingLaunch) -> some View {
        switch launch.action {
        case .summarize:
            SummarySheet(document: launch.document)
        case .chat:
            ChatSheet(document: launch.document)
        case .translate:
            TranslateSheet(document: launch.document)
        case .extract:
            ExtractSheet(document: launch.document)
        case .autoFill:
            FormFillSheet(document: launch.document) {}
        }
    }
}

// MARK: - Action model

enum AIAction: String, Identifiable, CaseIterable {
    case summarize, chat, translate, extract, autoFill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summarize: "Summarize"
        case .chat: "Chat"
        case .translate: "Translate"
        case .extract: "Extract Data"
        case .autoFill: "Auto-Fill"
        }
    }

    var subtitle: String {
        switch self {
        case .summarize: "TL;DR in seconds"
        case .chat: "Ask anything about it"
        case .translate: "11 languages"
        case .extract: "Dates, amounts, names"
        case .autoFill: "Smart form completion"
        }
    }

    var icon: String {
        switch self {
        case .summarize: "text.alignleft"
        case .chat: "bubble.left.and.bubble.right.fill"
        case .translate: "character.bubble"
        case .extract: "tablecells"
        case .autoFill: "checklist"
        }
    }

    var tint: Color {
        switch self {
        case .summarize: .blue
        case .chat: .purple
        case .translate: .green
        case .extract: .orange
        case .autoFill: .pink
        }
    }
}

private struct PendingLaunch: Identifiable {
    let id = UUID()
    let action: AIAction
    let document: Document
}

// MARK: - Action card

private struct AIActionCard: View {
    let action: AIAction
    let locked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.s) {
            iconBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(action.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .padding(DesignSystem.Spacing.m)
        .contentShape(Rectangle())
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: DesignSystem.Radius.medium))
    }

    private var iconBadge: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Circle()
                    .fill(action.tint.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: action.icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(action.tint)
            }
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Circle().fill(.tint))
                    .offset(x: 4, y: -4)
            }
        }
    }
}

// MARK: - Recent tile

private struct RecentDocumentTile: View {
    let document: Document

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            DocumentThumbnailView(
                documentID: document.id,
                documentURL: document.fileURL,
                thumbnailData: document.thumbnailData,
                placeholderIconSize: 24
            )
            .frame(width: 96, height: 124)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.small))
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            Text(document.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 96, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Document picker sheet

private struct DocumentPickerSheet: View {
    let action: AIAction
    let documents: [Document]
    let onPick: (Document) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filtered: [Document] {
        guard !searchText.isEmpty else { return documents }
        let q = searchText.lowercased()
        return documents.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if documents.isEmpty {
                    ContentUnavailableView(
                        "No PDFs Yet",
                        systemImage: "doc",
                        description: Text("Add a PDF from the Library tab to get started.")
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List {
                        ForEach(filtered) { doc in
                            Button {
                                Haptics.selection()
                                onPick(doc)
                                dismiss()
                            } label: {
                                DocumentPickerRow(document: doc, actionTint: action.tint)
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search documents"
            )
            .navigationTitle(action.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 4) {
                        Image(systemName: action.icon)
                            .imageScale(.small)
                            .foregroundStyle(action.tint)
                        Text("Pick a PDF")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption.weight(.medium))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct DocumentPickerRow: View {
    let document: Document
    let actionTint: Color

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.m) {
            DocumentThumbnailView(
                documentID: document.id,
                documentURL: document.fileURL,
                thumbnailData: document.thumbnailData,
                placeholderIconSize: 20
            )
            .frame(width: 44, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text("\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(actionTint.opacity(0.7))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Action picker sheet (entered by tapping a recent doc)

private struct ActionPickerSheet: View {
    let document: Document
    let onPick: (AIAction) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.l) {
                    documentHeader
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: DesignSystem.Spacing.m),
                            GridItem(.flexible(), spacing: DesignSystem.Spacing.m)
                        ],
                        spacing: DesignSystem.Spacing.m
                    ) {
                        ForEach(AIAction.allCases) { action in
                            Button {
                                Haptics.impact(.light)
                                onPick(action)
                                dismiss()
                            } label: {
                                AIActionCard(action: action, locked: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(DesignSystem.Spacing.l)
            }
            .navigationTitle("Choose AI Action")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var documentHeader: some View {
        HStack(spacing: DesignSystem.Spacing.m) {
            DocumentThumbnailView(
                documentID: document.id,
                documentURL: document.fileURL,
                thumbnailData: document.thumbnailData,
                placeholderIconSize: 22
            )
            .frame(width: 56, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.small))
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(DesignSystem.Spacing.m)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
    }
}

#Preview {
    AIAssistantView()
}
