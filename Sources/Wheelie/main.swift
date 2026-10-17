import AppKit
import WheelieCore

// Headless mode for scripting and smoke tests: Wheelie --convert <format> <file>...
let args = CommandLine.arguments
if args.count >= 4, args[1] == "--convert" {
    guard let format = OutputFormat(rawValue: args[2].lowercased()) ?? (args[2].lowercased() == "jpg" ? .jpeg : nil) else {
        FileHandle.standardError.write(Data("Unknown format \(args[2]). Options: \(OutputFormat.allCases.map(\.rawValue).joined(separator: ", "))\n".utf8))
        exit(2)
    }
    let files = args.dropFirst(3).map { URL(fileURLWithPath: $0).standardizedFileURL }
    let done = DispatchSemaphore(value: 0)
    var failed = false
    Task {
        for file in files {
            do {
                for out in try await Converter.convert(file, to: format) { print(out.path) }
            } catch {
                failed = true
                FileHandle.standardError.write(Data("\(file.lastPathComponent): \(error.localizedDescription)\n".utf8))
            }
        }
        done.signal()
    }
    done.wait()
    exit(failed ? 1 : 0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
