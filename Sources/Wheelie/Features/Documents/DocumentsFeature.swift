import AppKit

/// Document conversions live in the inner ring: `OutputFormat` + `Converter` route documents, EPUB,
/// spreadsheets, presentations and PDF reflow to `WheelieCore/Documents`. Nothing extra on the outer ring yet.
enum DocumentsFeature: WheelieFeature {}
