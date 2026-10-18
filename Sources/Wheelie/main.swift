import AppKit
import WheelieCore

// Headless mode for scripting and smoke tests: Wheelie --convert <format> <file>...
switch ConvertCommand.parse(CommandLine.arguments) {
case .app:
    break
case .usageError(let message):
    // Never fall through to the menu-bar app: a script would hang on a second instance.
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
case .convert(let format, let files):
    Task.detached {
        var failed = false
        for file in files {
            do {
                for out in try await Converter.convert(file, to: format) { print(out.path) }
            } catch {
                failed = true
                FileHandle.standardError.write(Data("\(file.lastPathComponent): \(error.localizedDescription)\n".utf8))
            }
        }
        exit(failed ? 1 : 0)
    }
    dispatchMain()   // parks the main thread; the task above ends the process
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
