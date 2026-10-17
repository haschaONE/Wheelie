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

    struct BatchError: LocalizedError {
        let failed: Int, total: Int, first: String
        var errorDescription: String? { total == 1 ? first : "\(failed) of \(total) failed: \(first)" }
    }

    /// Converts files two at a time. Throws if any failed (successful outputs stay on disk).
    static func convert(_ files: [URL], to format: OutputFormat) async throws -> [URL] {
        var outputs: [URL] = []
        var errors: [String] = []
        await withTaskGroup(of: Result<[URL], Error>.self) { group in
            var pending = files[...]
            func addNext() {
                guard let file = pending.popFirst() else { return }
                group.addTask {
                    do { return .success(try await Converter.convert(file, to: format)) }
                    catch { return .failure(error) }
                }
            }
            addNext(); addNext()
            for await result in group {
                switch result {
                case .success(let urls): outputs += urls
                case .failure(let error): errors.append(error.localizedDescription)
                }
                addNext()
            }
        }
        if let first = errors.first { throw BatchError(failed: errors.count, total: files.count, first: first) }
        return outputs
    }
}
