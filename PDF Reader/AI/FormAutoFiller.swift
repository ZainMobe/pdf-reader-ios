import Foundation
import FoundationModels
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
                    scan.documentText = String((pdf.string ?? "").prefix(3_000))
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
                self.state = .noFields
                return
            }

            self.state = .suggesting

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

            let instructions = Instructions("""
                You suggest plausible values for PDF form fields based on the document's \
                context and the user's saved profile (if provided). Use profile values \
                directly when a field clearly asks for them (name, email, phone, address). \
                Only suggest other values you can reasonably infer from the document text. \
                If you can't infer a value, return an empty string for that field. \
                Match the exact field names — don't invent new fields.
                """)
            let session = LanguageModelSession(instructions: instructions)
            let prompt = Prompt("""
                Document title: \(document.title)

                Document context:
                \(documentText)\(profileBlock)

                Form fields to fill:
                \(fieldList)
                """)

            do {
                let response = try await session.respond(
                    to: prompt,
                    generating: FormSuggestionSet.self
                )

                let suggested = response.content.values
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
            } catch is CancellationError {
                return
            } catch let error as LanguageModelSession.GenerationError {
                if Task.isCancelled { return }
                self.state = .failed(Self.message(for: error))
            } catch {
                if Task.isCancelled { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private static func message(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            return "This form has too many fields for the on-device model to fill in one pass."
        case .decodingFailure:
            return "The model couldn't produce usable suggestions for this form."
        case .guardrailViolation:
            return "This document's content was blocked by on-device safety filters."
        case .unsupportedLanguageOrLocale:
            return "The on-device model doesn't support the language used in this form."
        case .assetsUnavailable:
            return "Apple Intelligence assets aren't ready yet. Try again in a few minutes."
        case .rateLimited:
            return "Too many AI requests right now. Please try again shortly."
        case .concurrentRequests:
            return "Another AI request is in progress. Try again in a moment."
        case .refusal:
            return "The model declined to suggest values for this form."
        default:
            return error.localizedDescription
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
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// Shape of the AI response. Each suggestion has the exact field name plus
/// a value the model believes fits the document context.
@Generable
struct FormSuggestionSet {
    @Guide(description: "Suggested values for each form field")
    let values: [FormFieldValue]
}

@Generable
struct FormFieldValue {
    @Guide(description: "Exact field name as provided in the prompt")
    let fieldName: String

    @Guide(description: "Suggested value, or empty string if not inferrable")
    let suggestedValue: String
}
