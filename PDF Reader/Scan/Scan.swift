import Foundation

/// Scan — VisionKit document scanning and Vision-framework OCR pipeline.
///
/// Owns: scan capture flow, perspective correction, OCR text layer generation, searchable PDF export.
/// Consumed by: App (entry through Tools), Library (auto-OCR on import).
/// Depends on: PDFCore, DesignSystem.
enum Scan {}
