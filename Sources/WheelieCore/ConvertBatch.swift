import Foundation

/// An error from a job that still wrote some files. `AppServices.run` records and announces
/// `outputs` (history, Float, "Reveal results") while reporting the failure.
public protocol PartialOutputsError: Error {
    var outputs: [URL] { get }
}

/// Some files of a batch failed. The others' outputs are in `outputs` (and on disk).
public struct BatchConversionError: LocalizedError, PartialOutputsError {
    public let outputs: [URL]
    /// Each failed file with its error message, in input order.
    public let failures: [(file: URL, message: String)]
    public let total: Int

    public var errorDescription: String? {
        let first = failures.first?.message ?? "Conversion failed."
        return total == 1 ? first : "\(failures.count) of \(total) failed: \(first)"
    }
}

public enum ConvertBatch {
    /// Runs `convert` on every file, at most `maxConcurrent` at a time, and returns all
    /// outputs in input order. Throws `BatchConversionError` (carrying the successful
    /// outputs) when any file failed.
    ///
    /// Files that share a base name ("IMG_1234.HEIC" + "IMG_1234.MOV", or two "cover.jpg"
    /// saved to one folder) never run at the same time, so a backend that only checks
    /// whether a name is free (`OutputNaming.uniqueURL`) still sees the first one's file.
    public static func run(_ files: [URL], maxConcurrent: Int = 2,
                           convert: @escaping @Sendable (URL) async throws -> [URL]) async throws -> [URL] {
        var results = [[URL]?](repeating: nil, count: files.count)
        var failures: [(index: Int, message: String)] = []
        await withTaskGroup(of: (Int, Result<[URL], Error>).self) { group in
            var pending = Array(files.indices)
            var busyNames: Set<String> = []
            var running = 0

            func startEligible() {
                while running < max(1, maxConcurrent),
                      let slot = pending.firstIndex(where: { !busyNames.contains(nameKey(files[$0])) }) {
                    let index = pending.remove(at: slot)
                    let file = files[index]
                    busyNames.insert(nameKey(file))
                    running += 1
                    group.addTask {
                        do { return (index, .success(try await convert(file))) }
                        catch { return (index, .failure(error)) }
                    }
                }
            }

            startEligible()
            for await (index, result) in group {
                running -= 1
                busyNames.remove(nameKey(files[index]))
                switch result {
                case .success(let urls): results[index] = urls
                case .failure(let error): failures.append((index, error.localizedDescription))
                }
                startEligible()
            }
        }
        let outputs = results.compactMap { $0 }.flatMap { $0 }
        if !failures.isEmpty {
            let sorted = failures.sorted { $0.index < $1.index }
            throw BatchConversionError(outputs: outputs,
                                       failures: sorted.map { (files[$0.index], $0.message) },
                                       total: files.count)
        }
        return outputs
    }

    /// Output names derive from the base name; APFS/HFS+ compare names case- and
    /// normalisation-insensitively, so the key does too.
    static func nameKey(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
    }
}
