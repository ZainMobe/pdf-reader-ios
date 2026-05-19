import Foundation

/// Signing — Signature capture (draw/type/import), placement on PDF, flatten on export.
///
/// Owns: signature assets, placement UI state, flattening pipeline.
/// Consumed by: App (entry through Tools).
/// Depends on: PDFCore, DesignSystem.
enum Signing {}
