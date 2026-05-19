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
            guard let pdf = PDFDocument(url: url) else {
                self.state = .failed("Couldn't open document.")
                return
            }

            // Collect text widgets across all pages.
            let textWidgetType = PDFAnnotationWidgetSubtype.text.rawValue
            var detected: [(pageIndex: Int, name: String, current: String)] = []
            for index in 0..<pdf.pageCount {
                guard let page = pdf.page(at: index) else { continue }
                for annotation in page.annotations where annotation.type == "Widget" {
                    guard annotation.widgetFieldType.rawValue == textWidgetType else { continue }
                    let name = annotation.fieldName ?? "Field \(detected.count + 1)"
                    let current = annotation.widgetStringValue ?? ""
                    detected.append((index, name, current))
                }
            }

            guard !detected.isEmpty else {
                self.state = .noFields
                return
            }

            self.state = .suggesting

            // Build prompt with document context + field names.
            let documentText = String((pdf.string ?? "").prefix(3_000))
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
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Writes accepted suggestions to disk by loading the PDF fresh, mutating
    /// matching text widgets, and saving via `PDFDocument.write(to:)`.
    func apply(to documentURL: URL) {
        state = .applying
        guard let pdf = PDFDocument(url: documentURL) else {
            state = .failed("Couldn't reopen document.")
            return
        }

        let textWidgetType = PDFAnnotationWidgetSubtype.text.rawValue
        var applied = 0
        for suggestion in suggestions where suggestion.accepted && !suggestion.suggestedValue.isEmpty {
            guard let page = pdf.page(at: suggestion.pageIndex) else { continue }
            for annotation in page.annotations where annotation.type == "Widget" {
                guard
                    annotation.widgetFieldType.rawValue == textWidgetType,
                    annotation.fieldName == suggestion.fieldName
                else { continue }
                annotation.widgetStringValue = suggestion.suggestedValue
                applied += 1
                break
            }
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
            success = pdf.write(to: coordinatedURL)
        }

        guard success else {
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
