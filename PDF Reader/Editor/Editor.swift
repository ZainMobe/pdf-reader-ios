import Foundation

/// Editor — Edit existing text/images, page management (reorder, rotate, delete, merge, split),
/// redaction, and form fields.
///
/// Owns: PDF object model mutations built on PDFKit + CoreGraphics, undo/redo stack, export.
/// Consumed by: App (entry through Tools).
/// Depends on: PDFCore, DesignSystem.
enum Editor {}
