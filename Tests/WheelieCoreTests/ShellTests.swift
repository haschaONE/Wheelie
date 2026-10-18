import Foundation
import XCTest
@testable import WheelieCore

final class ShellSettingsTests: XCTestCase {
    func testKeysMatchAppSettingsKeys() {
        // Mirrors Sources/Wheelie/Plugin/AppServices.swift `SettingsKey`.
        XCTAssertEqual(ShellSettings.Key.wheelEnabled, "wheelOnDrag")
        XCTAssertEqual(ShellSettings.Key.triggerModifier, "triggerModifier")
        XCTAssertEqual(ShellSettings.Key.outputLocation, "outputLocation")
        XCTAssertEqual(ShellSettings.Key.customOutputFolder, "customOutputFolder")
        XCTAssertEqual(ShellSettings.Key.playSounds, "playSounds")
        XCTAssertEqual(ShellSettings.Key.addResultsToFloat, "addResultsToFloat")
        XCTAssertEqual(ShellSettings.Key.revealResults, "revealResults")
        XCTAssertEqual(ShellSettings.Key.terminalApp, "terminalApp")
        XCTAssertEqual(ShellSettings.Key.didShowWelcome, "shell.didShowWelcome")
    }

    func testRegisteredDefaults() throws {
        let suite = "wheelie.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Unregistered: callers' fallbacks apply.
        XCTAssertTrue(ShellSettings.bool(ShellSettings.Key.playSounds, in: defaults, default: true))
        XCTAssertFalse(defaults.bool(forKey: ShellSettings.Key.playSounds))

        defaults.register(defaults: ShellSettings.registrationDefaults())
        XCTAssertTrue(defaults.bool(forKey: ShellSettings.Key.wheelEnabled))
        XCTAssertTrue(defaults.bool(forKey: ShellSettings.Key.playSounds))
        XCTAssertFalse(defaults.bool(forKey: ShellSettings.Key.revealResults))
        XCTAssertFalse(defaults.bool(forKey: ShellSettings.Key.addResultsToFloat))
        XCTAssertFalse(defaults.bool(forKey: ShellSettings.Key.didShowWelcome))
        XCTAssertEqual(defaults.string(forKey: ShellSettings.Key.triggerModifier), "shift")
        XCTAssertEqual(defaults.string(forKey: ShellSettings.Key.outputLocation), "original")
        XCTAssertEqual(defaults.string(forKey: ShellSettings.Key.terminalApp), "com.apple.Terminal")
        XCTAssertNil(defaults.string(forKey: ShellSettings.Key.customOutputFolder))

        // A written value wins over the registered default.
        defaults.set(false, forKey: ShellSettings.Key.playSounds)
        XCTAssertFalse(ShellSettings.bool(ShellSettings.Key.playSounds, in: defaults, default: true))
    }

    func testTriggerModifierResolution() {
        XCTAssertEqual(TriggerModifier(setting: nil), .shift)
        XCTAssertEqual(TriggerModifier(setting: ""), .shift)
        XCTAssertEqual(TriggerModifier(setting: "hyper"), .shift)
        XCTAssertEqual(TriggerModifier(setting: "control"), .control)
        XCTAssertEqual(TriggerModifier(setting: "option"), .option)
        XCTAssertEqual(TriggerModifier(setting: "command"), .command)
        XCTAssertEqual(TriggerModifier.allCases.map(\.rawValue), ["shift", "control", "option", "command"])
        XCTAssertEqual(TriggerModifier.shift.label, "⇧ Shift")
        XCTAssertEqual(TriggerModifier.command.keyCap, "⌘ command")
        XCTAssertEqual(TriggerModifier.allCases.filter(\.affectsFinderDrops), [.option, .command])
    }

    func testOutputLocationResolution() {
        let downloads = URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true)
        XCTAssertEqual(OutputLocation(setting: nil), .original)
        XCTAssertEqual(OutputLocation(setting: "desktop"), .original)
        XCTAssertEqual(OutputLocation(setting: "downloads"), .downloads)
        XCTAssertEqual(OutputLocation(setting: "custom"), .custom)

        XCTAssertNil(OutputLocation.original.directory(customPath: "/tmp/x", downloads: downloads))
        XCTAssertEqual(OutputLocation.downloads.directory(customPath: nil, downloads: downloads), downloads)
        XCTAssertNil(OutputLocation.custom.directory(customPath: nil, downloads: downloads))
        XCTAssertNil(OutputLocation.custom.directory(customPath: "   ", downloads: downloads))
        XCTAssertEqual(OutputLocation.custom.directory(customPath: "/Volumes/Work/Out", downloads: downloads)?.path,
                       "/Volumes/Work/Out")
        XCTAssertEqual(OutputLocation.custom.directory(customPath: "~/Converted", downloads: downloads)?.path,
                       NSHomeDirectory() + "/Converted")
        XCTAssertEqual(OutputLocation.allCases.map(\.title), ["Next to the original", "In Downloads", "In a folder…"])
    }

    func testDisplayPathAndFolderCheck() throws {
        XCTAssertEqual(OutputLocation.displayPath("/Users/bob/Pictures", home: "/Users/bob"), "~/Pictures")
        XCTAssertEqual(OutputLocation.displayPath("/Users/bob", home: "/Users/bob"), "~")
        XCTAssertEqual(OutputLocation.displayPath("/Users/bobby/Pictures", home: "/Users/bob"), "/Users/bobby/Pictures")
        XCTAssertEqual(OutputLocation.displayPath("/Volumes/X", home: "/Users/bob"), "/Volumes/X")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        XCTAssertTrue(OutputLocation.isUsableFolder(dir))
        XCTAssertFalse(OutputLocation.isUsableFolder(file))
        XCTAssertFalse(OutputLocation.isUsableFolder(dir.appendingPathComponent("missing")))
    }
}

final class OutputDirectorySettingTests: XCTestCase {
    override func tearDown() {
        OutputNaming.preferredDirectory = nil
        super.tearDown()
    }

    /// A custom "Save to" folder that disappears (deleted, or an unplugged drive) must not
    /// send every result to a dead path: outputs go next to the original until it's back.
    func testMissingCustomFolderFallsBackToNextToTheOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-out-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("src", isDirectory: true)
        let custom = root.appendingPathComponent("Converted", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = sources.appendingPathComponent("photo.png")

        OutputNaming.preferredDirectory = custom                     // set, but the folder doesn't exist
        XCTAssertEqual(OutputNaming.configuredDirectory, custom)
        XCTAssertNil(OutputNaming.preferredDirectory)
        XCTAssertEqual(OutputNaming.uniqueURL(for: source, ext: "jpg").deletingLastPathComponent().path, sources.path)

        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)   // drive reconnected
        XCTAssertEqual(OutputNaming.preferredDirectory, custom)
        XCTAssertEqual(OutputNaming.uniqueURL(for: source, ext: "jpg").deletingLastPathComponent().path, custom.path)

        // A file where the folder should be isn't usable either.
        let fileDir = root.appendingPathComponent("NotAFolder")
        FileManager.default.createFile(atPath: fileDir.path, contents: Data())
        OutputNaming.preferredDirectory = fileDir
        XCTAssertNil(OutputNaming.preferredDirectory)
    }

    /// The app rewrites the setting on the main thread while background jobs read it; that
    /// must not race (an unsynchronised URL global crashed with a use-after-free).
    func testConcurrentWritesAndReadsAreSafe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-race-\(UUID().uuidString)")
        let a = root.appendingPathComponent("A", isDirectory: true)
        let b = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("x.png")

        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for i in 0..<4_000 {
                if worker == 0 {
                    // Fresh URL objects each time, so stores really release the old value.
                    OutputNaming.preferredDirectory = URL(fileURLWithPath: (i % 2 == 0 ? a : b).path, isDirectory: true)
                } else if i % 50 == 0 {
                    _ = OutputNaming.uniqueURL(for: source, ext: "jpg")
                } else {
                    _ = OutputNaming.configuredDirectory?.appendingPathComponent("y").path
                }
            }
        }
        let final = try XCTUnwrap(OutputNaming.preferredDirectory)
        XCTAssertTrue([a.path, b.path].contains(final.path))
    }
}

final class TerminalCatalogTests: XCTestCase {
    func testKnownTerminals() {
        XCTAssertEqual(TerminalCatalog.known.map(\.name),
                       ["Terminal", "iTerm2", "Warp", "Ghostty", "kitty", "Alacritty", "WezTerm"])
        XCTAssertEqual(Set(TerminalCatalog.known.map(\.bundleID)).count, TerminalCatalog.known.count)
        XCTAssertEqual(TerminalCatalog.known.first?.bundleID, TerminalCatalog.defaultBundleID)
        XCTAssertEqual(TerminalCatalog.app(for: "com.googlecode.iterm2").name, "iTerm2")
        XCTAssertEqual(TerminalCatalog.app(for: "COM.MITCHELLH.GHOSTTY").name, "Ghostty")
        XCTAssertEqual(TerminalCatalog.app(for: "com.example.MyTerm").name, "MyTerm")
    }

    func testChoicesListInstalledPlusSelection() {
        let installed: Set<String> = ["com.apple.Terminal", "net.kovidgoyal.kitty", "com.googlecode.iterm2"]
        let isInstalled = { installed.contains($0) }

        let rows = TerminalCatalog.choices(selected: "com.apple.Terminal", isInstalled: isInstalled)
        XCTAssertEqual(rows.map(\.app.name), ["Terminal", "iTerm2", "kitty"])   // catalog order
        XCTAssertTrue(rows.allSatisfy(\.isInstalled))

        // A saved choice that was uninstalled stays visible, flagged.
        let withMissing = TerminalCatalog.choices(selected: "dev.warp.Warp-Stable", isInstalled: isInstalled)
        XCTAssertEqual(withMissing.map(\.app.name), ["Terminal", "iTerm2", "kitty", "Warp"])
        XCTAssertEqual(withMissing.last?.isInstalled, false)

        XCTAssertEqual(TerminalCatalog.notInstalled(isInstalled: isInstalled).map(\.name),
                       ["Warp", "Ghostty", "Alacritty", "WezTerm"])

        let nothing = TerminalCatalog.choices(selected: nil, isInstalled: { _ in false })
        XCTAssertEqual(nothing.map(\.app.bundleID), ["com.apple.Terminal"])
    }

    /// The Terminal petal opens exactly the saved app and throws when it's missing; Settings
    /// must say so instead of promising a fallback to Terminal that never happens.
    func testMissingSelectionNoteMatchesPetalBehaviour() {
        let isInstalled = { (id: String) in id == "com.apple.Terminal" || id == "com.github.wez.wezterm" }
        XCTAssertNil(TerminalCatalog.missingSelectionNote(selected: "com.github.wez.wezterm", isInstalled: isInstalled))
        XCTAssertNil(TerminalCatalog.missingSelectionNote(selected: nil, isInstalled: isInstalled))
        XCTAssertNil(TerminalCatalog.missingSelectionNote(selected: "", isInstalled: isInstalled))
        let note = TerminalCatalog.missingSelectionNote(selected: "net.kovidgoyal.kitty", isInstalled: isInstalled)
        XCTAssertEqual(note, "kitty isn't installed, so the Terminal petal can't open it. Choose an installed terminal above.")
        XCTAssertFalse(note?.contains("opens instead") ?? true)
    }

    /// The petal's error names the app the same way the Settings list does (one catalog).
    func testPetalErrorNamesComeFromTheSettingsCatalog() {
        XCTAssertEqual(TerminalApps.defaultBundleID, TerminalCatalog.defaultBundleID)
        for app in TerminalCatalog.known {
            XCTAssertEqual(TerminalApps.name(for: app.bundleID), app.name)
        }
        XCTAssertEqual(FileActionError.appMissing(TerminalApps.name(for: "net.kovidgoyal.kitty")).localizedDescription
                        .hasPrefix("kitty isn"), true)
    }
}

final class ToolCatalogTests: XCTestCase {
    func testCatalogCoversWheelieTools() {
        // Only tools a feature runs: Extract uses /usr/bin/tar, so no 7zz / unar.
        XCTAssertEqual(ToolCatalog.all.map(\.name), ["ffmpeg", "ffprobe", "cwebp", "exiftool", "soffice"])
        XCTAssertEqual(ToolCatalog.essentials.map(\.name), ["ffmpeg", "ffprobe", "cwebp"])
        XCTAssertEqual(ToolCatalog.all.first { $0.name == "exiftool" }?.importance, .optional)
        XCTAssertTrue(ToolCatalog.all.first { $0.name == "soffice" }?.isCask == true)
    }

    /// LibreOffice in ~/Applications works for conversion, so Settings must find it too.
    func testLibreOfficeInUserApplicationsIsFound() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let userCopy = home + "/Applications/LibreOffice.app/Contents/MacOS/soffice"
        XCTAssertEqual(ToolCatalog.libreOfficeAppPaths(home: "/Users/x"),
                       ["/Applications/LibreOffice.app/Contents/MacOS/soffice",
                        "/Users/x/Applications/LibreOffice.app/Contents/MacOS/soffice"])
        let statuses = ToolCatalog.check(locate: { _ in nil }, isExecutable: { $0 == userCopy })
        XCTAssertEqual(statuses.first { $0.requirement.name == "soffice" }?.path?.path, userCopy)
        XCTAssertFalse(ToolCatalog.installCommand(for: statuses)?.contains("libreoffice") ?? true)
    }

    func testCheckUsesLocateThenExtraPaths() {
        let statuses = ToolCatalog.check(locate: { $0 == "ffmpeg" ? URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg") : nil },
                                         isExecutable: { $0 == "/Applications/LibreOffice.app/Contents/MacOS/soffice" })
        let found = Dictionary(uniqueKeysWithValues: statuses.map { ($0.requirement.name, $0.path?.path) })
        XCTAssertEqual(found["ffmpeg"], "/opt/homebrew/bin/ffmpeg")
        XCTAssertEqual(found["soffice"], "/Applications/LibreOffice.app/Contents/MacOS/soffice")
        XCTAssertEqual(found["ffprobe"], .some(nil))
        XCTAssertEqual(statuses.filter(\.isFound).count, 2)
    }

    func testInstallCommand() {
        let none = ToolCatalog.check(locate: { _ in nil }, isExecutable: { _ in false })
        XCTAssertEqual(ToolCatalog.installCommand(for: none),
                       "brew install ffmpeg webp exiftool && brew install --cask libreoffice")

        let essentials = ToolCatalog.check(ToolCatalog.essentials, locate: { _ in nil })
        XCTAssertEqual(ToolCatalog.installCommand(for: essentials), "brew install ffmpeg webp")

        let onlyWebPMissing = ToolCatalog.check(ToolCatalog.essentials,
                                                locate: { $0 == "cwebp" ? nil : URL(fileURLWithPath: "/usr/local/bin/\($0)") })
        XCTAssertEqual(ToolCatalog.installCommand(for: onlyWebPMissing), "brew install webp")

        let all = ToolCatalog.check(locate: { URL(fileURLWithPath: "/opt/homebrew/bin/\($0)") })
        XCTAssertNil(ToolCatalog.installCommand(for: all))
    }

    func testHomebrewPath() {
        XCTAssertEqual(ToolCatalog.homebrewPath(isExecutable: { $0 == "/usr/local/bin/brew" }), "/usr/local/bin/brew")
        XCTAssertNil(ToolCatalog.homebrewPath(isExecutable: { _ in false }))
    }
}

final class JobBoardTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    private let src = URL(fileURLWithPath: "/tmp/movie.mov")
    private let out = URL(fileURLWithPath: "/tmp/movie.mp4")

    func testQuickJobNeverShows() {
        var board = JobBoard()
        let id = UUID()
        board.start(id: id, title: "MP4", sources: [src], at: at(0))
        XCTAssertFalse(board.isPanelVisible)
        XCTAssertEqual(board.nextDeadline(), at(1.2))
        board.advance(to: at(1.0))
        XCTAssertFalse(board.isPanelVisible)

        board.outputsProduced([out])
        let finished = board.finish(id: id, error: nil, at: at(1.1))
        XCTAssertEqual(finished?.state, .succeeded)
        XCTAssertEqual(finished?.outputs, [out])
        XCTAssertEqual(finished?.feedback, .success)   // still chimes
        XCTAssertTrue(board.entries.isEmpty)
        XCTAssertFalse(board.isPanelVisible)
        XCTAssertNil(board.nextDeadline())
    }

    func testLongJobShowsThenAutoHides() {
        var board = JobBoard()
        let id = UUID()
        board.start(id: id, title: "MP4", sources: [src], at: at(0))
        board.advance(to: at(1.2))
        XCTAssertTrue(board.isPanelVisible)
        XCTAssertEqual(board.visibleEntries.map(\.id), [id])
        XCTAssertTrue(board.visibleEntries[0].isRunning)
        XCTAssertNil(board.nextDeadline())             // nothing scheduled while it runs

        board.outputsProduced([out])
        let finished = board.finish(id: id, error: nil, at: at(3))
        XCTAssertEqual(finished?.outputs, [out])
        XCTAssertEqual(board.visibleEntries.first?.state, .succeeded)
        XCTAssertEqual(board.visibleEntries.first?.revealTargets, [out])
        XCTAssertEqual(board.nextDeadline(), at(7))     // 4 s success linger

        board.advance(to: at(6.9))
        XCTAssertTrue(board.isPanelVisible)
        board.advance(to: at(7))
        XCTAssertFalse(board.isPanelVisible)
        XCTAssertTrue(board.entries.isEmpty)
        XCTAssertNil(board.nextDeadline())
    }

    func testFailureLingersLongerAndSignalsFailure() {
        var board = JobBoard()
        let id = UUID()
        board.start(id: id, title: "Compress", sources: [src], at: at(0))
        board.advance(to: at(2))
        board.outputsProduced([out])                    // partial batch output, but the job failed
        let finished = board.finish(id: id, error: "ffmpeg exited with 1", at: at(5))
        XCTAssertEqual(finished?.state, .failed("ffmpeg exited with 1"))
        XCTAssertEqual(finished?.error, "ffmpeg exited with 1")
        XCTAssertEqual(finished?.outputs, [])
        XCTAssertEqual(finished?.feedback, .failure)
        XCTAssertEqual(finished?.revealTargets, [src])
        XCTAssertEqual(board.nextDeadline(), at(13))    // 8 s failure linger
        board.advance(to: at(12.9))
        XCTAssertTrue(board.isPanelVisible)
        board.advance(to: at(13))
        XCTAssertFalse(board.isPanelVisible)
    }

    func testFinishRevealsJobThatOutlivedTheDelayEvenIfTimerWasLate() {
        var board = JobBoard()
        let id = UUID()
        board.start(id: id, title: "GIF", sources: [src], at: at(0))
        board.finish(id: id, error: nil, at: at(1.5))   // no advance in between
        XCTAssertTrue(board.isPanelVisible)
        XCTAssertEqual(board.visibleEntries.first?.state, .succeeded)
    }

    func testOutputsGoToTheJobThatFinishesNext() {
        var board = JobBoard()
        let a = UUID(), b = UUID()
        board.start(id: a, title: "A", sources: [src], at: at(0))
        board.start(id: b, title: "B", sources: [src], at: at(0.5))
        board.advance(to: at(2))
        board.outputsProduced([out])
        board.finish(id: b, error: nil, at: at(3))
        let finishedA = board.finish(id: a, error: nil, at: at(4))
        XCTAssertEqual(board.entry(id: b)?.outputs, [out])
        XCTAssertEqual(finishedA?.outputs, [])
        XCTAssertNil(finishedA?.feedback)               // e.g. an editor window opened: no chime
    }

    func testUnknownFinishClearsPendingOutputs() {
        var board = JobBoard()
        board.outputsProduced([out])
        XCTAssertNil(board.finish(id: UUID(), error: nil, at: at(0)))
        let id = UUID()
        board.start(id: id, title: "A", sources: [src], at: at(1))
        XCTAssertEqual(board.finish(id: id, error: nil, at: at(5))?.outputs, [])
    }

    func testNewJobsJoinAVisiblePanelImmediately() {
        var board = JobBoard()
        let a = UUID(), b = UUID()
        board.start(id: a, title: "A", sources: [src], at: at(0))
        board.advance(to: at(1.3))
        board.start(id: b, title: "B", sources: [src], at: at(2))
        XCTAssertEqual(board.visibleEntries.map(\.id), [a, b])
        XCTAssertEqual(board.runningCount, 2)
        // B finishing quickly still shows its result because it was on screen.
        board.finish(id: b, error: nil, at: at(2.2))
        XCTAssertEqual(board.visibleEntries.map(\.id), [a, b])
    }

    func testHoverKeepsFinishedEntriesThenGivesGrace() {
        var board = JobBoard()
        let id = UUID()
        board.start(id: id, title: "A", sources: [src], at: at(0))
        board.advance(to: at(1.2))
        board.finish(id: id, error: nil, at: at(2))
        board.setHovering(true, at: at(5))
        board.advance(to: at(30))
        XCTAssertTrue(board.isPanelVisible)
        XCTAssertNil(board.nextDeadline())
        board.setHovering(false, at: at(30))
        XCTAssertEqual(board.nextDeadline(), at(31.5))
        board.advance(to: at(31.4))
        XCTAssertTrue(board.isPanelVisible)
        board.advance(to: at(31.5))
        XCTAssertFalse(board.isPanelVisible)
        XCTAssertFalse(board.isHovering)
    }

    func testDismissOnlyRemovesFinishedEntries() {
        var board = JobBoard()
        let running = UUID(), done = UUID()
        board.start(id: running, title: "A", sources: [src], at: at(0))
        board.start(id: done, title: "B", sources: [src], at: at(0))
        board.advance(to: at(1.5))
        board.finish(id: done, error: nil, at: at(2))
        board.dismiss(id: running)
        board.dismiss(id: done)
        XCTAssertEqual(board.entries.map(\.id), [running])
    }

    func testDuplicateStartIgnoredAndFinishedCapped() {
        var board = JobBoard(timing: JobBoard.Timing(maxFinished: 3))
        let first = UUID()
        board.start(id: first, title: "A", sources: [src], at: at(0))
        board.start(id: first, title: "A again", sources: [], at: at(0.5))
        XCTAssertEqual(board.entries.count, 1)
        XCTAssertEqual(board.entries[0].title, "A")

        var ids = [first]
        for i in 1..<6 {
            let id = UUID()
            ids.append(id)
            board.start(id: id, title: "Job \(i)", sources: [src], at: at(0))
        }
        board.advance(to: at(2))
        for (i, id) in ids.enumerated() { board.finish(id: id, error: nil, at: at(3 + Double(i) * 0.1)) }
        XCTAssertEqual(board.entries.map(\.id), Array(ids.suffix(3)))
    }

    /// Move To… cancelled in its folder picker (outcome .none) after the HUD appeared must not
    /// turn into a green "Done" row.
    func testJobWithoutResultLeavesInsteadOfShowingDone() {
        var board = JobBoard()
        let id = UUID()
        board.start(id: id, title: "Move To…", sources: [src], at: at(0))
        board.advance(to: at(5))
        XCTAssertTrue(board.isPanelVisible)
        let finished = board.finishWithoutResult(id: id, at: at(6))
        XCTAssertEqual(finished?.state, .succeeded)
        XCTAssertNil(finished?.feedback)
        XCTAssertTrue(board.entries.isEmpty)
        XCTAssertFalse(board.isPanelVisible)
        XCTAssertNil(board.nextDeadline())
        XCTAssertNil(board.finishWithoutResult(id: id, at: at(7)))

        // Other entries stay on screen.
        let a = UUID(), b = UUID()
        board.start(id: a, title: "A", sources: [src], at: at(10))
        board.start(id: b, title: "B", sources: [src], at: at(10))
        board.advance(to: at(12))
        board.finishWithoutResult(id: b, at: at(13))
        XCTAssertEqual(board.visibleEntries.map(\.id), [a])
        XCTAssertTrue(board.visibleEntries[0].isRunning)
    }

    func testSourceSummary() {
        var board = JobBoard()
        let one = UUID(), many = UUID(), none = UUID()
        board.start(id: one, title: "A", sources: [src], at: at(0))
        board.start(id: many, title: "B", sources: [src, out, src], at: at(0))
        board.start(id: none, title: "C", sources: [], at: at(0))
        XCTAssertEqual(board.entry(id: one)?.sourceSummary, "movie.mov")
        XCTAssertEqual(board.entry(id: many)?.sourceSummary, "3 files")
        XCTAssertEqual(board.entry(id: none)?.sourceSummary, "")
    }
}

final class ToneSynthTests: XCTestCase {
    func testRenderedSoundsAreCleanAndBounded() {
        for sampleRate in [44_100.0, 48_000.0] {
            for sound in WheelieSound.allCases {
                let spec = sound.spec()
                let samples = ToneSynth.render(spec, sampleRate: sampleRate)
                let label = "\(sound) @ \(sampleRate)"

                XCTAssertEqual(samples.count, Int((spec.duration * sampleRate).rounded(.up)), label)
                XCTAssertEqual(samples.count, spec.frameCount(sampleRate: sampleRate), label)
                XCTAssertTrue(samples.allSatisfy(\.isFinite), label)

                let peak = samples.map(abs).max() ?? 0
                XCTAssertLessThanOrEqual(peak, 1, label)
                XCTAssertEqual(Double(peak), spec.peak, accuracy: 1e-4, label)

                // Starts and ends on silence (no clicks), and has died away by the end.
                XCTAssertLessThan(abs(samples.first ?? 1), 1e-4, label)
                XCTAssertLessThan(abs(samples.last ?? 1), 1e-4, label)
                let tail = samples.suffix(max(samples.count / 10, 1)).map(abs).max() ?? 1
                XCTAssertLessThan(tail, peak * 0.1, label)
            }
        }
    }

    func testDurations() {
        XCTAssertLessThanOrEqual(WheelieSound.tick.spec().duration, 0.05)   // must never smear across petals
        XCTAssertGreaterThan(WheelieSound.success.spec().duration, 0.3)
        XCTAssertLessThan(WheelieSound.success.spec().duration, 1)
        XCTAssertLessThan(WheelieSound.failure.spec().duration, 1)
        for pitch in WheelieSound.tickPitches {
            XCTAssertFalse(ToneSynth.render(WheelieSound.tick.spec(pitch: pitch), sampleRate: 48_000).isEmpty)
        }
    }

    func testFrequencyIsAccurate() {
        // A steady 440 Hz tone crosses zero twice per cycle.
        let spec = SoundSpec(tones: [Tone(frequency: 440, duration: 1, attack: 0.01, decay: 100)], peak: 0.5)
        let samples = ToneSynth.render(spec, sampleRate: 48_000)
        var crossings = 0
        for i in 1..<samples.count where (samples[i - 1] < 0) != (samples[i] < 0) { crossings += 1 }
        XCTAssertEqual(Double(crossings), 880, accuracy: 4)
    }

    func testDegenerateInputs() {
        XCTAssertEqual(ToneSynth.render(SoundSpec(tones: [], peak: 0.5), sampleRate: 48_000), [])
        XCTAssertEqual(ToneSynth.render(WheelieSound.tick.spec(), sampleRate: 0), [])
        XCTAssertEqual(SoundSpec(tones: [], peak: 3).peak, 1)
        XCTAssertEqual(SoundSpec(tones: [], peak: -1).peak, 0)
    }
}
