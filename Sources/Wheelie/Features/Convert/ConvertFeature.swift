import Foundation
import WheelieCore

/// Inner ring: one petal per output format valid for the dragged files.
enum ConvertFeature: WheelieFeature {
    static func wheelItems() -> [WheelItem] {
        OutputFormat.allCases.enumerated().map { index, format in item(format, order: index) }
    }

    /// Petals in usefulness order for these files (the order `targets(for:)` ranks them).
    static func wheelItems(for files: [URL]) -> [WheelItem] {
        OutputFormat.targets(for: files).enumerated().map { index, format in item(format, order: index) }
    }

    private static func item(_ format: OutputFormat, order: Int) -> WheelItem {
        WheelItem(id: "convert.\(format.rawValue)", label: format.label, symbol: format.symbol,
                  ring: .inner, order: order,
                  accepts: { OutputFormat.targets(for: $0).contains(format) },
                  perform: { files in .outputs(try await convert(files, to: format)) })
    }

    /// Converts files two at a time (same-named files one after another, so they get distinct
    /// output names). When some fail, throws `BatchConversionError`, which carries the other
    /// files' outputs so they still reach history, Float and "Reveal results".
    static func convert(_ files: [URL], to format: OutputFormat) async throws -> [URL] {
        try await ConvertBatch.run(files, maxConcurrent: 2) { file in
            try await Converter.convert(file, to: format)
        }
    }
}
