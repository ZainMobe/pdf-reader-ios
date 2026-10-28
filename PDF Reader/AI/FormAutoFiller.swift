import Foundation
import PDFKit

/// On-device form auto-fill. Detects text widget annotations in a PDF and
/// asks the Foundation Models system to suggest plausible values based on
/// the document's own context.
///
/// Flow: `detect → suggest → review (in UI) → apply`.
@MainActor
@Observable
final class FormAutoFiller {
    enum State {
        case idle
        case detecting
        case suggesting
        case ready
        case noFields
        case applying
        case done(applied: Int)
        case failed(String)
    }

    struct FieldSuggestion: Identifiable {
        let id = UUID()
        let pageIndex: Int
        let fieldName: String
        var suggestedValue: String
        var accepted: Bool = true
    }

    private(set) var state: State = .idle
    var suggestions: [FieldSuggestion] = []
    private var task: Task<Void, Never>?

    func analyzeAndSuggest(_ document: Document) {
        task?.cancel()
        state = .detecting
        suggestions = []
        let url = document.fileURL
        let generator: any AIGenerator
        do {
            generator = try AIEngine.resolve()
        } catch {
            AIAnalyticsRun.unavailable(.formFill, error: error)
            state = .failed(AIError.from(error).userMessage)
            return
        }
        let backend = generator.backend
        let contextBudget = generator.textBudget(onDevice: 3_000, cloud: 40_000)

        task = Task { [weak self] in
            guard let self else { return }
            // Open, scan widgets and extract text off the main thread.
            struct Scan {
                var locked = false
                var detected: [(pageIndex: Int, name: String, current: String)] = []
                var documentText = ""
            }
            let scan: Scan? = await Task.detached(priority: .userInitiated) {
                guard let pdf = PDFDocument.opened(at: url) else { return nil }
                var scan = Scan()
                if pdf.isLocked {
                    scan.locked = true
                    return scan
                }
                let textWidgetType = PDFAnnotationWidgetSubtype.text.rawValue
                for index in 0..<pdf.pageCount {
                    guard let page = pdf.page(at: index) else { continue }
                    for annotation in page.annotations where annotation.type == "Widget" {
                        guard annotation.widgetFieldType.rawValue == textWidgetType else { continue }
                        let name = annotation.fieldName ?? "Field \(scan.detected.count + 1)"
                        let current = annotation.widgetStringValue ?? ""
                        scan.detected.append((index, name, current))
                    }
                }
                if !scan.detected.isEmpty {
                    scan.documentText = String((pdf.string ?? "").prefix(contextBudget))
                }
                return scan
            }.value
            if Task.isCancelled { return }

            guard let scan else {
                self.state = .failed("Couldn't open document.")
                return
            }
            guard !scan.locked else {
                self.state = .failed("This PDF is password-protected. Open it in the Reader and enter the password first.")
                return
            }
            let detected = scan.detected
            guard !detected.isEmpty else {
                AIAnalyticsRun.unavailable(.formFill, reason: "no_fields")
                self.state = .noFields
                return
            }

            self.state = .suggesting
            let analytics = AIAnalyticsRun(.formFill, backend: backend, [.count: AppAnalytics.countBucket(detected.count)])

            // Build prompt with document context + field names.
            let documentText = scan.documentText
            let fieldList = detected.enumerated()
                .map { idx, field in "\(idx + 1). \(field.name)\(field.current.isEmpty ? "" : " (current: \(field.current))")" }
                .joined(separator: "\n")

            let profile = UserProfile.load()
            let profileBlock = profile.hasContent
                ? """


                User profile (use these directly when a field clearly asks for them):
                \(profile.promptText)
                """
                : ""

            let instructions = """
                You suggest plausible values for PDF form fields based on the document's \
                context and the user's saved profile (if provided). Use profile values \
                directly when a field clearly asks for them (name, email, phone, address). \
                Only suggest other values you can reasonably infer from the document text. \
                If you can't infer a value, return an empty string for that field. \
                Match the exact field names; don't invent new fields.
                """
            let prompt = """
                Document title: \(document.title)

                Document context:
                \(documentText)\(profileBlock)

                Form fields to fill:
                \(fieldList)
                """

            do {
                let response = try await generator.respond(
                    instructions: instructions,
                    prompt: prompt,
                    generating: FormSuggestionSet.self
                )

                let suggested = response.values
                let mapped = detected.compactMap { field -> FieldSuggestion? in
                    let match = suggested.first { $0.fieldName == field.name }
                    return FieldSuggestion(
                        pageIndex: field.pageIndex,
                        fieldName: field.name,
                        suggestedValue: match?.suggestedValue ?? "",
                        accepted: !(match?.suggestedValue ?? "").isEmpty
                    )
                }
                self.suggestions = mapped
                self.state = .ready
                analytics.succeeded(outputChars: nil, [.count: AppAnalytics.countBucket(mapped.filter { !$0.suggestedValue.isEmpty }.count)])
            } catch is CancellationError {
                analytics.cancelled()
                return
            } catch {
                if Task.isCancelled { analytics.cancelled(); return }
                analytics.failed(error)
                self.state = .failed(Self.message(for: AIError.from(error)))
            }
        }
    }

    private static func message(for error: AIError) -> String {
        switch error {
        case .contextTooLong:
            return "This form has too many fields for the AI model to fill in one pass."
        case .decodingFailed:
            return "The model couldn't produce usable suggestions for this form."
        case .refused:
            return "The model declined to suggest values for this form."
        default:
            return error.userMessage
        }
    }

    /// Writes accepted suggestions to disk by loading the PDF fresh, mutating
    /// matching text widgets, and saving via `PDFDocument.write(to:)`.
    func apply(to documentURL: URL) {
        state = .applying
        guard let pdf = PDFDocument.opened(at: documentURL) else {
            state = .failed("Couldn't reopen document.")
            return
        }

        guard !pdf.isLocked else {
            state = .failed("This PDF is password-protected. Open it in the Reader and enter the password first.")
            return
        }

        let textWidgetType = PDFAnnotationWidgetSubtype.text.rawValue
        var applied = 0
        for suggestion in suggestions where suggestion.accepted && !suggestion.suggestedValue.isEmpty {
            guard let page = pdf.page(at: suggestion.pageIndex) else { continue }
            var wroteField = false
            // Write every widget that shares the field name (a field can have
            // several widgets on a page); count the field once.
            for annotation in page.annotations where annotation.type == "Widget" {
                guard
                    annotation.widgetFieldType.rawValue == textWidgetType,
                    annotation.fieldName == suggestion.fieldName
                else { continue }
                annotation.widgetStringValue = suggestion.suggestedValue
                wroteField = true
            }
            if wroteField { applied += 1 }
        }

        // PDFKit writes an unencrypted file by default. `opened(at:)` unlocked
        // a protected form with its stored password, so re-apply it or the
        // save would silently strip the protection.
        var writeOptions: [PDFDocumentWriteOption: Any] = [:]
        if let password = DocumentPasswordStore.password(for: documentURL) {
            writeOptions[.userPasswordOption] = password
            writeOptions[.ownerPasswordOption] = password
        }

        // Coordinate the write so a Reader window currently showing this
        // document refreshes via its NSFilePresenter and any concurrent
        // annotation save can't clobber the filled fields.
        let coordinator = NSFileCoordinator()
        var success = false
        var coordinationError: NSError?
        coordinator.coordinate(
            writingItemAt: documentURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            success = writeOptions.isEmpty
                ? pdf.write(to: coordinatedURL)
                : pdf.write(to: coordinatedURL, withOptions: writeOptions)
        }

        guard success, coordinationError == nil else {
            state = .failed("Couldn't save changes.")
            return
        }
        state = .done(applied: applied)
        AppAnalytics.log(.aiResultAction, [
            .aiAction: AnalyticsAIAction.formFill.rawValue,
            .action: "apply",
            .count: AppAnalytics.countBucket(applied),
        ])
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// Shape of the AI response. Each suggestion has the exact field name plus
/// a value the model believes fits the document context.
nonisolated struct FormSuggestionSet: AIStructured {
    let values: [FormFieldValue]

    static var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "values": [
                    "type": "array",
                    "description": "Suggested values for each form field",
                    "items": [
                        "type": "object",
                        "properties": [
                            "fieldName": ["type": "string", "description": "Exact field name as provided in the prompt"],
                            "suggestedValue": ["type": "string", "description": "Suggested value, or empty string if not inferrable"],
                        ],
                        "required": ["fieldName", "suggestedValue"],
                    ],
                ],
            ],
            "required": ["values"],
        ]
    }
}

nonisolated struct FormFieldValue: Decodable, Sendable {
    let fieldName: String

    let suggestedValue: String
}
