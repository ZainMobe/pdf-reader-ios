import SwiftUI

/// Chat-with-PDF surface. Streams responses from `DocumentChat` (which wraps
/// `LanguageModelSession`) and auto-scrolls to the latest message.
struct ChatSheet: View {
    let document: Document
    @State private var chat: DocumentChat?
    @State private var checkedContent = false
    @State private var inputText = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                Divider()
                composer
            }
            .navigationTitle("Chat")
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
                    Button("Done") { dismiss() }
                }
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: DesignSystem.Spacing.m) {
                        ForEach(chat.messages) { message in
                            ChatBubble(message: message).id(message.id)
                        }
                    }
                    .padding(DesignSystem.Spacing.l)
                }
                .onChange(of: chat.messages.last?.text) { _, _ in
                    if let last = chat.messages.last {
                        withAnimation(DesignSystem.Motion.snappy) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        } else {
            VStack(spacing: DesignSystem.Spacing.m) {
                Image(systemName: "message")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Ask anything about “\(document.title)”")
                    .font(.headline)
                Text("Answers are generated on this device — your document never leaves it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(DesignSystem.Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: DesignSystem.Spacing.s) {
            TextField("Ask anything…", text: $inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .disabled(!composerEnabled)
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(DesignSystem.Spacing.m)
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
}

private struct ChatBubble: View {
    let message: DocumentChat.Message

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: DesignSystem.Spacing.xs) {
                Text(message.text.isEmpty && message.isStreaming ? "…" : message.text)
                    .textSelection(.enabled)
                    .padding(DesignSystem.Spacing.m)
                    .glassEffect(
                        message.role == .user
                            ? Glass.regular.tint(.accentColor)
                            : .regular,
                        in: .rect(cornerRadius: DesignSystem.Radius.medium)
                    )
                if message.isStreaming && !message.text.isEmpty {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}
