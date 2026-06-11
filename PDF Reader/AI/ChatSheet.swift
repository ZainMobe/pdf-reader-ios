import SwiftUI

/// Chat-with-PDF surface. Streams responses from `DocumentChat` (which wraps
/// `LanguageModelSession`) and auto-scrolls to the latest message.
struct ChatSheet: View {
    let document: Document
    @State private var chat: DocumentChat?
    @State private var checkedContent = false
    @State private var inputText = ""
    @State private var showingClearConfirm = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool

    private static let suggestedPrompts: [SuggestedPrompt] = [
        SuggestedPrompt(
            icon: "text.alignleft",
            title: "Summarize",
            prompt: "Give me a concise summary of this document.",
            tint: .blue
        ),
        SuggestedPrompt(
            icon: "list.bullet.rectangle",
            title: "Key points",
            prompt: "What are the most important points in this document?",
            tint: .purple
        ),
        SuggestedPrompt(
            icon: "calendar",
            title: "Find dates",
            prompt: "List every date mentioned in this document and what it refers to.",
            tint: .orange
        ),
        SuggestedPrompt(
            icon: "questionmark.bubble",
            title: "Quiz me",
            prompt: "Quiz me with three short questions about this document.",
            tint: .pink
        )
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient
                VStack(spacing: 0) {
                    transcript
                    composer
                }
            }
            .navigationTitle("Chat with PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .confirmationDialog(
                "Start a new conversation?",
                isPresented: $showingClearConfirm,
                titleVisibility: .visible
            ) {
                Button("New Conversation", role: .destructive) { resetConversation() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears the current messages and starts fresh.")
            }
            .onAppear {
                if !checkedContent {
                    chat = DocumentChat(document: document)
                    checkedContent = true
                }
            }
            .onDisappear {
                chat?.cancel()
            }
            .alert(
                "Couldn't generate a reply",
                isPresented: errorBinding
            ) {
                Button("OK") { chat?.clearError() }
            } message: {
                if case .error(let message) = chat?.status {
                    Text(message)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            privacyBadge
        }
        ToolbarItem(placement: .topBarTrailing) {
            if let chat, !chat.messages.isEmpty {
                Button {
                    Haptics.selection()
                    showingClearConfirm = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New Conversation")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Done") { dismiss() }
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.16), .clear],
            startPoint: .top,
            endPoint: .center
        )
        .ignoresSafeArea()
    }

    private var privacyBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .imageScale(.small)
            Text("On-device")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: {
                if case .error = chat?.status { return true }
                return false
            },
            set: { if !$0 { chat?.clearError() } }
        )
    }

    @ViewBuilder
    private var transcript: some View {
        if !checkedContent {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if chat == nil {
            ContentUnavailableView(
                "No Text to Chat With",
                systemImage: "text.magnifyingglass",
                description: Text("This PDF doesn't contain extractable text. Try re-scanning the document so OCR can capture it.")
            )
        } else if let chat, !chat.messages.isEmpty {
            messageScroll(chat: chat)
        } else {
            emptyState
        }
    }

    private func messageScroll(chat: DocumentChat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: DesignSystem.Spacing.l) {
                    documentContextPill
                        .padding(.top, DesignSystem.Spacing.s)
                    ForEach(chat.messages) { message in
                        ChatBubble(message: message)
                            .id(message.id)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 8)),
                                removal: .opacity
                            ))
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, DesignSystem.Spacing.l)
                .padding(.bottom, DesignSystem.Spacing.m)
                .animation(DesignSystem.Motion.snappy, value: chat.messages.count)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.messages.last?.text) { _, _ in
                scrollToBottom(proxy: proxy, last: chat.messages.last)
            }
            .onChange(of: chat.messages.count) { _, _ in
                scrollToBottom(proxy: proxy, last: chat.messages.last)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, last: DocumentChat.Message?) {
        guard let last else { return }
        withAnimation(DesignSystem.Motion.snappy) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private var documentContextPill: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "doc.text.fill")
                .font(.caption2)
                .foregroundStyle(.tint)
            Text(document.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, DesignSystem.Spacing.m)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.xl) {
                heroHeader
                suggestionGrid
            }
            .padding(DesignSystem.Spacing.l)
            .padding(.top, DesignSystem.Spacing.m)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var heroHeader: some View {
        VStack(spacing: DesignSystem.Spacing.m) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.05)],
                            center: .center,
                            startRadius: 4,
                            endRadius: 60
                        )
                    )
                    .frame(width: 104, height: 104)
                Image(systemName: "sparkles")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, options: .repeat(.continuous))
            }
            Text("Ask anything about your PDF")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text("\u{201C}\(document.title)\u{201D}")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
        }
        .padding(.top, DesignSystem.Spacing.m)
    }

    private var suggestionGrid: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.s) {
            Text("Try asking…")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, DesignSystem.Spacing.xs)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: DesignSystem.Spacing.s),
                    GridItem(.flexible(), spacing: DesignSystem.Spacing.s)
                ],
                spacing: DesignSystem.Spacing.s
            ) {
                ForEach(Self.suggestedPrompts) { prompt in
                    Button {
                        Haptics.impact(.light)
                        chat?.send(prompt.prompt)
                    } label: {
                        SuggestedPromptCard(prompt: prompt)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: DesignSystem.Spacing.s) {
            inputField
            sendButton
        }
        .padding(.horizontal, DesignSystem.Spacing.m)
        .padding(.vertical, DesignSystem.Spacing.s)
        .background(.bar)
    }

    private var inputField: some View {
        TextField("Ask anything…", text: $inputText, axis: .vertical)
            .lineLimit(1...5)
            .focused($inputFocused)
            .submitLabel(.send)
            .onSubmit(send)
            .disabled(!composerEnabled)
            .padding(.horizontal, DesignSystem.Spacing.m)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
    }

    private var sendButton: some View {
        let isStreaming = chat?.status == .sending
        let active = isStreaming || canSend
        return Button {
            if isStreaming {
                Haptics.impact(.light)
                chat?.cancel()
            } else {
                send()
            }
        } label: {
            Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background {
                    Circle()
                        .fill(
                            isStreaming
                                ? AnyShapeStyle(Color.red.gradient)
                                : (canSend
                                    ? AnyShapeStyle(Color.accentColor.gradient)
                                    : AnyShapeStyle(Color.secondary.opacity(0.35)))
                        )
                }
                .contentTransition(.symbolEffect(.replace))
                .scaleEffect(active ? 1 : 0.92)
        }
        .disabled(!isStreaming && !canSend)
        .buttonStyle(.plain)
        .animation(DesignSystem.Motion.snappy, value: isStreaming)
        .animation(DesignSystem.Motion.snappy, value: canSend)
        .sensoryFeedback(.success, trigger: chat?.messages.count ?? 0)
    }

    private var canSend: Bool {
        guard let chat else { return false }
        if chat.status == .sending { return false }
        return !inputText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var composerEnabled: Bool {
        chat != nil
    }

    private func send() {
        let text = inputText
        inputText = ""
        chat?.send(text)
    }

    private func resetConversation() {
        chat?.cancel()
        chat = DocumentChat(document: document)
        inputText = ""
        Haptics.success()
    }
}

// MARK: - Suggested prompt models

private struct SuggestedPrompt: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let prompt: String
    let tint: Color
}

private struct SuggestedPromptCard: View {
    let prompt: SuggestedPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.s) {
            ZStack {
                Circle()
                    .fill(prompt.tint.opacity(0.18))
                    .frame(width: 32, height: 32)
                Image(systemName: prompt.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(prompt.tint)
            }
            Text(prompt.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(prompt.prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .padding(DesignSystem.Spacing.m)
        .contentShape(Rectangle())
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: DesignSystem.Radius.medium))
    }
}

// MARK: - Chat bubble

private struct ChatBubble: View {
    let message: DocumentChat.Message
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.s) {
            if message.role == .user {
                Spacer(minLength: 40)
                userBubble
            } else {
                assistantAvatar
                assistantContent
                Spacer(minLength: 32)
            }
        }
    }

    private var assistantAvatar: some View {
        ZStack {
            Circle()
                .fill(.tint.opacity(0.18))
                .frame(width: 28, height: 28)
            Image(systemName: "sparkles")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tint)
        }
        .padding(.top, 4)
    }

    private var userBubble: some View {
        Text(message.text)
            .textSelection(.enabled)
            .padding(.horizontal, DesignSystem.Spacing.m)
            .padding(.vertical, DesignSystem.Spacing.s + 2)
            .glassEffect(
                Glass.regular.tint(.accentColor),
                in: .rect(cornerRadius: DesignSystem.Radius.medium)
            )
    }

    private var assistantContent: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            bubbleBody
            if !message.isStreaming && !message.text.isEmpty {
                copyButton
                    .padding(.leading, DesignSystem.Spacing.xs)
            }
        }
    }

    @ViewBuilder
    private var bubbleBody: some View {
        if message.text.isEmpty && message.isStreaming {
            TypingIndicator()
                .padding(.horizontal, DesignSystem.Spacing.m)
                .padding(.vertical, DesignSystem.Spacing.s + 2)
                .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(renderedMarkdown)
                    .textSelection(.enabled)
                if message.isStreaming {
                    BlinkingCursor()
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.m)
            .padding(.vertical, DesignSystem.Spacing.s + 2)
            .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
        }
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = message.text
            Haptics.selection()
            withAnimation(DesignSystem.Motion.snappy) { didCopy = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(DesignSystem.Motion.snappy) { didCopy = false }
            }
        } label: {
            Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(didCopy ? "Copied" : "Copy reply")
    }

    private var renderedMarkdown: AttributedString {
        if let attr = try? AttributedString(
            markdown: message.text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attr
        }
        return AttributedString(message.text)
    }
}

// MARK: - Streaming indicators

private struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 7, height: 7)
                    .foregroundStyle(.secondary)
                    .opacity(animating ? 1 : 0.3)
                    .scaleEffect(animating ? 1.0 : 0.7)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever()
                            .delay(Double(index) * 0.18),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

private struct BlinkingCursor: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(.tint)
            .frame(width: 2, height: 14)
            .opacity(visible ? 1 : 0)
            .animation(.easeInOut(duration: 0.6).repeatForever(), value: visible)
            .onAppear { visible = false }
    }
}
