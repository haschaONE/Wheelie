import Foundation

/// A place to build an output file out of sight, so a run that is cut short (an error,
/// a cancel, or the app quitting mid-write) never leaves a half-written file under the
/// final name. The file only appears under its real name once it is complete and checked.
///
/// The staging folder is the volume's "items being replaced" folder (the system clears it),
/// or a hidden folder next to the output when the volume has none.
final class StagedOutput {
    /// Folder that holds the work in progress; removed by `commit` and `discard`.
    let directory: URL
    private let fileManager: FileManager

    /// Prepares a staging folder on the same volume as `destination` (so the final move is a rename).
    init(near destination: URL, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let parent = destination.deletingLastPathComponent()
        if let dir = try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: parent, create: true) {
            directory = dir
        } else {
            let hidden = parent.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial",
                                                       isDirectory: true)
            do {
                try fileManager.createDirectory(at: hidden, withIntermediateDirectories: false)
            } catch {
                throw PDFToolsError("Could not write to “\(parent.lastPathComponent)”: \(error.localizedDescription)")
            }
            directory = hidden
        }
    }

    deinit { discard() }

    /// A file inside the staging folder.
    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Moves the staged `file` to `destination()` and removes the staging folder. Never
    /// replaces an existing file: when the name was taken meanwhile, `destination` is asked
    /// again (pass `OutputNaming.uniqueURL` to get the next free name). Returns the final URL.
    func commit(_ file: URL, to destination: () -> URL) throws -> URL {
        defer { discard() }
        var lastError: Error?
        for _ in 0..<3 {
            let target = destination()
            do {
                try fileManager.moveItem(at: file, to: target)
                return target
            } catch {
                lastError = error
                // Only retry when something now sits at the target; anything else is final.
                guard (try? fileManager.attributesOfItem(atPath: target.path)) != nil else { break }
            }
        }
        throw PDFToolsError("Could not save the file: \(lastError?.localizedDescription ?? "unknown error")")
    }

    /// Removes the staging folder and everything in it.
    func discard() {
        try? fileManager.removeItem(at: directory)
    }
}
