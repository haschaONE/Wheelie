import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import WheelieCore

final class FileActionsTests: XCTestCase {
    func testPathListJoinsStandardizedPaths() {
        let urls = [URL(fileURLWithPath: "/Users/me/My Files/a.png"),
                    URL(fileURLWithPath: "/tmp/x/../folder", isDirectory: true)]
        XCTAssertEqual(FileActions.pathList(urls), "/Users/me/My Files/a.png\n/tmp/folder")
        XCTAssertEqual(FileActions.pathList([]), "")
    }

    func testCountPhrase() throws {
        let dir = try fileActionsTempDir()
        let a = try touch(dir, "a.txt"), b = try touch(dir, "b.txt")
        let f = try mkdir(dir, "Folder"), g = try mkdir(dir, "Other")
        XCTAssertEqual(FileActions.countPhrase([a]), "1 file")
        XCTAssertEqual(FileActions.countPhrase([a, b]), "2 files")
        XCTAssertEqual(FileActions.countPhrase([f]), "1 folder")
        XCTAssertEqual(FileActions.countPhrase([f, g]), "2 folders")
        XCTAssertEqual(FileActions.countPhrase([a, f]), "2 items")
    }

    func testTerminalFolders() throws {
        let dir = try fileActionsTempDir()
        let file = try touch(dir, "a.txt"), other = try touch(dir, "b.txt")
        let folder = try mkdir(dir, "Sub")
        let app = try mkdir(dir, "Tool.app")
        try mkdir(app, "Contents")
        let folders = FileActions.terminalFolders(for: [file, other, folder, app])
        XCTAssertEqual(folders.map(\.lastPathComponent), [dir.lastPathComponent, "Sub"])
    }

    func testStableHash() {
        let a = [URL(fileURLWithPath: "/a.png"), URL(fileURLWithPath: "/b.png")]
        XCTAssertEqual(FileActions.stableHash(a), FileActions.stableHash(a))
        XCTAssertNotEqual(FileActions.stableHash(a), FileActions.stableHash(a.reversed()))
        XCTAssertFalse(FileActions.stableHash(a).isEmpty)
    }

    func testSplitName() {
        XCTAssertTrue(FileActions.splitName("photo.png") == ("photo", "png"))
        XCTAssertTrue(FileActions.splitName("backup.tar.gz") == ("backup", "tar.gz"))
        XCTAssertTrue(FileActions.splitName("Folder") == ("Folder", ""))
        XCTAssertTrue(FileActions.splitName(".zshrc") == (".zshrc", ""))
        XCTAssertTrue(FileActions.splitName(".tar.gz") == (".tar", "gz"))
    }

    func testUniqueNamesNeverReuseTakenPaths() throws {
        let dir = try fileActionsTempDir()
        XCTAssertEqual(FileActions.uniqueURL(named: "photo.png", in: dir).lastPathComponent, "photo.png")
        try touch(dir, "photo.png")
        XCTAssertEqual(FileActions.uniqueURL(named: "photo.png", in: dir).lastPathComponent, "photo 2.png")
        try touch(dir, "photo 2.png")
        XCTAssertEqual(FileActions.uniqueURL(named: "photo.png", in: dir).lastPathComponent, "photo 3.png")

        try touch(dir, "backup.tar.gz")
        XCTAssertEqual(FileActions.uniqueURL(named: "backup.tar.gz", in: dir).lastPathComponent, "backup 2.tar.gz")

        try mkdir(dir, "v1.2")
        XCTAssertEqual(FileActions.uniqueFolderURL(named: "v1.2", in: dir).lastPathComponent, "v1.2 2")
        XCTAssertEqual(FileActions.uniqueFolderURL(named: "fresh", in: dir).lastPathComponent, "fresh")

        // A dangling symlink still occupies the name.
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("gone").path,
                                                   withDestinationPath: "/nonexistent/wheelie")
        XCTAssertEqual(FileActions.uniqueFolderURL(named: "gone", in: dir).lastPathComponent, "gone 2")
    }

    // MARK: Move

    func testMoveRenamesOnClashAndNeverOverwrites() throws {
        let dir = try fileActionsTempDir()
        let dest = try mkdir(dir, "Dest")
        try Data("old".utf8).write(to: dest.appendingPathComponent("a.txt"))
        let a = dir.appendingPathComponent("a.txt")
        try Data("new".utf8).write(to: a)
        let folder = try mkdir(dir, "Stuff")
        try touch(folder, "inner.txt")

        let moved = try FileActions.move([a, folder], to: dest)
        XCTAssertEqual(moved.map(\.lastPathComponent), ["a 2.txt", "Stuff"])
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("a.txt"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("a 2.txt"), encoding: .utf8), "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Stuff/inner.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testMoveRefusesDestinationInsideMovedFolder() throws {
        let dir = try fileActionsTempDir()
        let folder = try mkdir(dir, "Project")
        let sub = try mkdir(folder, "Sub")
        let file = try touch(dir, "file.txt")
        for destination in [folder, sub] {
            XCTAssertThrowsError(try FileActions.move([file, folder], to: destination)) { error in
                XCTAssertEqual(error as? FileActionError, .destinationInsideSource("Project"))
                XCTAssertEqual(error.localizedDescription, "Choose a destination outside “Project”.")
            }
        }
        // Through a symlinked path to the same folder.
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sub)
        XCTAssertThrowsError(try FileActions.move([folder], to: link)) { error in
            XCTAssertEqual(error as? FileActionError, .destinationInsideSource("Project"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "nothing moved after refusal")
    }

    func testMoveValidatesDestination() throws {
        let dir = try fileActionsTempDir()
        let file = try touch(dir, "file.txt")
        let other = try touch(dir, "other.txt")
        XCTAssertThrowsError(try FileActions.move([file], to: other)) {
            XCTAssertEqual($0 as? FileActionError, .destinationNotFolder)
        }
        XCTAssertThrowsError(try FileActions.move([file], to: dir.appendingPathComponent("missing"))) {
            XCTAssertEqual($0 as? FileActionError, .destinationNotFolder)
        }
        XCTAssertThrowsError(try FileActions.move([URL(string: "https://example.com/a.txt")!], to: dir)) {
            XCTAssertEqual($0 as? FileActionError, .notLocal(verb: "be moved"))
        }
        XCTAssertThrowsError(try FileActions.move([file], to: dir)) {
            XCTAssertEqual($0 as? FileActionError, .alreadyInDestination(dir.lastPathComponent))
        }
    }

    // MARK: Archives

    func testArchiveFormatDetection() {
        let cases: [(String, ArchiveFormat?, String)] = [
            ("a.zip", .zip, "a"), ("A.ZIP", .zip, "A"),
            ("photos.tar", .tar, "photos"), ("photos.tar.gz", .tar, "photos"), ("photos.tgz", .tar, "photos"),
            ("photos.tar.bz2", .tar, "photos"), ("photos.tbz", .tar, "photos"), ("photos.tbz2", .tar, "photos"),
            ("photos.tar.xz", .tar, "photos"), ("photos.txz", .tar, "photos"),
            ("notes.txt.gz", .gzip, "notes.txt"), ("a.7z", .sevenZip, "a"), ("a.rar", .rar, "a"),
            ("photo.png", nil, "photo"), (".zip", nil, ""), ("zip", nil, "zip"),
        ]
        for (name, format, base) in cases {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            XCTAssertEqual(ArchiveFormat(url: url), format, name)
            if format != nil { XCTAssertEqual(ArchiveFormat.baseName(of: url), base, name) }
        }
    }

    func testCanExtractDependsOnTools() {
        XCTAssertTrue(ArchiveExtractor.canExtract(URL(fileURLWithPath: "/tmp/a.zip")))
        XCTAssertTrue(ArchiveExtractor.canExtract(URL(fileURLWithPath: "/tmp/a.tar.gz")))
        XCTAssertTrue(ArchiveExtractor.canExtract(URL(fileURLWithPath: "/tmp/a.gz")))
        XCTAssertFalse(ArchiveExtractor.canExtract(URL(fileURLWithPath: "/tmp/a.png")))
        XCTAssertFalse(ArchiveExtractor.canExtract(URL(string: "https://example.com/a.zip")!))
        // bsdtar (libarchive) reads 7z and rar itself.
        XCTAssertTrue(ArchiveExtractor.canExtract(URL(fileURLWithPath: "/tmp/a.7z")))
        XCTAssertTrue(ArchiveExtractor.canExtract(URL(fileURLWithPath: "/tmp/a.rar")))
    }

    /// Zip with `link -> <outside>` followed by `link/pwned.txt`: an extractor that writes through
    /// the link drops pwned.txt outside before any after-the-fact check can run.
    func testZipCannotWriteThroughSymlinkEntry() async throws {
        let dir = try fileActionsTempDir()
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("evil.zip")
        try await Tools.run("/usr/bin/python3", ["-I", "-c", """
        import zipfile, stat, sys
        z = zipfile.ZipFile(sys.argv[1], 'w')
        i = zipfile.ZipInfo('link'); i.create_system = 3; i.external_attr = (stat.S_IFLNK | 0o777) << 16
        z.writestr(i, sys.argv[2])
        z.writestr('link/pwned.txt', 'gotcha')
        z.close()
        """, zip.path, outside.path])
        do {
            _ = try await ArchiveExtractor.extract(zip, to: dir)
            XCTFail("expected refusal")
        } catch {
            XCTAssertTrue(error is ArchiveError, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("pwned.txt").path))
    }

    /// `name.tar` holding `name/link -> ../other` is fine inside staging, but once `name/` is
    /// unwrapped as the output the link would point outside it.
    func testSiblingLinkEscapingUnwrappedFolderIsRefused() async throws {
        let dir = try fileActionsTempDir()
        let src = dir.appendingPathComponent("src", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: src.appendingPathComponent("bundle"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("bundle/link").path, withDestinationPath: "../other")
        let tar = dir.appendingPathComponent("bundle.tar")
        try await Tools.run("/usr/bin/tar", ["-c", "-f", tar.path, "-C", src.path, "bundle"])
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        do {
            _ = try await ArchiveExtractor.extract(tar, to: out)
            XCTFail("expected refusal")
        } catch {
            XCTAssertEqual(error as? ArchiveError, .linkEscapes("link"))
        }
    }

    func testQuarantineIsPropagatedAndArchiveXattrsIgnored() async throws {
        let dir = try fileActionsTempDir()
        let src = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("App"), withIntermediateDirectories: true)
        let inner = src.appendingPathComponent("App/run.sh")
        try Data("echo hi".utf8).write(to: inner)
        // An xattr stored inside the archive must not be restored.
        try await Tools.run("/usr/bin/xattr", ["-w", "com.example.planted", "1", inner.path])
        let zip = dir.appendingPathComponent("download.zip")
        try await Tools.run("/usr/bin/tar", ["--format", "zip", "-c", "-f", zip.path, "-C", src.path, "App"])
        let flag = "0083;00000000;Safari;"
        try await Tools.run("/usr/bin/xattr", ["-w", "com.apple.quarantine", flag, zip.path])

        let out = try await ArchiveExtractor.extract(zip, to: dir)
        for path in [out.path, out.appendingPathComponent("App").path, out.appendingPathComponent("App/run.sh").path] {
            let value = try await Tools.capture("/usr/bin/xattr", ["-p", "com.apple.quarantine", path]).stdout
            XCTAssertEqual(value.trimmingCharacters(in: .whitespacesAndNewlines), flag, path)
        }
        let names = try await Tools.capture("/usr/bin/xattr", [out.appendingPathComponent("App/run.sh").path]).stdout
        XCTAssertFalse(names.contains("com.example.planted"))
    }

    /// Read-only files and folders the owner can't even list must still get the flag
    /// (and keep their modes); otherwise an app inside could dodge Gatekeeper.
    func testQuarantineReachesLockedItems() async throws {
        let dir = try fileActionsTempDir()
        let tar = dir.appendingPathComponent("locked.tar")
        try await Tools.run("/usr/bin/python3", ["-I", "-c", """
        import tarfile, io, sys
        t = tarfile.open(sys.argv[1], 'w')
        def add(name, mode, data=None):
            i = tarfile.TarInfo(name); i.mode = mode
            if data is None:
                i.type = tarfile.DIRTYPE; t.addfile(i)
            else:
                i.size = len(data); t.addfile(i, io.BytesIO(data))
        add('top', 0o755)
        add('top/sealed', 0o755)
        add('top/sealed/run.sh', 0o444, b'echo hi')
        add('top/readonly.txt', 0o444, b'x')
        t.close()
        # Lock the folder after its contents so extraction itself still works.
        """, tar.path])
        let flag = "0083;00000000;Safari;"
        try await Tools.run("/usr/bin/xattr", ["-w", "com.apple.quarantine", flag, tar.path])
        let out = try await ArchiveExtractor.extract(tar, to: dir)
        let sealed = out.appendingPathComponent("top/sealed")
        // Lock the folder now (no access for anyone) and run the flagging pass again on it.
        XCTAssertEqual(chmod(sealed.path, 0o000), 0)
        let readonly = out.appendingPathComponent("top/readonly.txt").path
        XCTAssertEqual(chmod(readonly, 0o644), 0)
        try await Tools.run("/usr/bin/xattr", ["-d", "com.apple.quarantine", readonly])
        XCTAssertEqual(chmod(readonly, 0o444), 0)
        try ArchiveExtractor.propagateQuarantine(from: tar, to: out)
        var info = stat()
        XCTAssertEqual(lstat(sealed.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0, "mode restored")
        XCTAssertEqual(lstat(readonly, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o444, "mode restored")
        XCTAssertEqual(chmod(sealed.path, 0o755), 0)
        for path in ["top/readonly.txt", "top/sealed", "top/sealed/run.sh"] {
            let value = try await Tools.capture("/usr/bin/xattr", ["-p", "com.apple.quarantine", out.appendingPathComponent(path).path]).stdout
            XCTAssertEqual(value.trimmingCharacters(in: .whitespacesAndNewlines), flag, path)
        }
    }

    func testExtract7z() async throws {
        let dir = try fileActionsTempDir()
        let src = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("seven".utf8).write(to: src.appendingPathComponent("a.txt"))
        let archive = dir.appendingPathComponent("pack.7z")
        try await Tools.run("/usr/bin/tar", ["--format", "7zip", "-c", "-f", archive.path, "-C", src.path, "a.txt"])
        let out = try await ArchiveExtractor.extract(archive, to: dir)
        XCTAssertEqual(out.lastPathComponent, "pack")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("a.txt")), "seven")
    }

    func testSafeEntryPaths() {
        for safe in ["a.txt", "dir/", "dir/sub/file", "./a", "a..b", "..hidden", "dir/..x",
                     "~$Budget.xlsx", "~notes.txt", "~dir/x", "dir/~"] {
            XCTAssertTrue(ArchiveExtractor.isSafeEntryPath(safe), safe)
        }
        for unsafe in ["../a", "dir/../../a", "/etc/passwd", "a/..", "..", "..\\evil.txt", "~/x", "~", "~/"] {
            XCTAssertFalse(ArchiveExtractor.isSafeEntryPath(unsafe), unsafe)
        }
    }

    func testExtractZipIntoNewFolder() async throws {
        let dir = try fileActionsTempDir()
        let src = try mkdir(dir, "src")
        try sampleTree(in: src)
        let out = try mkdir(dir, "out")
        let zip = out.appendingPathComponent("bundle.zip")
        try await Tools.run("/usr/bin/ditto", ["-c", "-k", src.path, zip.path])

        let first = try await ArchiveExtractor.extract(zip)
        XCTAssertEqual(first.lastPathComponent, "bundle")
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("a.txt"), encoding: .utf8), "alpha")
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("sub/b.txt"), encoding: .utf8), "beta")

        let second = try await ArchiveExtractor.extract(zip)
        XCTAssertEqual(second.lastPathComponent, "bundle 2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path), "archive is kept")
        XCTAssertEqual(try stagingLeftovers(in: out), [])
    }

    func testExtractZipWithSingleMatchingFolderIsNotDoubleNested() async throws {
        let dir = try fileActionsTempDir()
        let project = try mkdir(dir, "Project")
        try sampleTree(in: project)
        let out = try mkdir(dir, "out")
        let zip = out.appendingPathComponent("Project.zip")
        try await Tools.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", project.path, zip.path])

        let folder = try await ArchiveExtractor.extract(zip)
        XCTAssertEqual(folder.lastPathComponent, "Project")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sub/b.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Project").path))
        XCTAssertEqual(try stagingLeftovers(in: out), [])
    }

    func testExtractTarFamily() async throws {
        let dir = try fileActionsTempDir()
        let src = try mkdir(dir, "src")
        try sampleTree(in: src)
        for ext in ["tar.gz", "tgz", "tar.bz2", "tar.xz", "tar"] {
            let out = try mkdir(dir, "out-\(ext)")
            let archive = out.appendingPathComponent("photos.\(ext)")
            // bsdtar picks the compression from the suffix with -a.
            try await Tools.run("/usr/bin/tar", ["-c", "-a", "-f", archive.path, "-C", src.path, "a.txt", "sub"])
            let folder = try await ArchiveExtractor.extract(archive)
            XCTAssertEqual(folder.lastPathComponent, "photos", ext)
            XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("sub/b.txt"), encoding: .utf8), "beta", ext)
            XCTAssertEqual(try stagingLeftovers(in: out), [], ext)
        }
    }

    func testExtractToCustomDirectory() async throws {
        let dir = try fileActionsTempDir()
        let src = try mkdir(dir, "src")
        try sampleTree(in: src)
        let archive = dir.appendingPathComponent("pack.tgz")
        try await Tools.run("/usr/bin/tar", ["-c", "-z", "-f", archive.path, "-C", src.path, "a.txt"])
        let target = try mkdir(dir, "Elsewhere")
        let folder = try await ArchiveExtractor.extract(archive, to: target)
        XCTAssertEqual(folder.deletingLastPathComponent().lastPathComponent, "Elsewhere")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.txt").path))
    }

    func testExtractSingleGzipFile() async throws {
        let dir = try fileActionsTempDir()
        let notes = dir.appendingPathComponent("notes.txt")
        try Data("hello gzip".utf8).write(to: notes)
        let gz = dir.appendingPathComponent("notes.txt.gz")
        try await ArchiveExtractor.runToFile("/usr/bin/gzip", ["-c", notes.path], output: gz)

        let out = try await ArchiveExtractor.extract(gz)
        XCTAssertEqual(out.lastPathComponent, "notes 2.txt", "original notes.txt is not overwritten")
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "hello gzip")
        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "hello gzip")
        XCTAssertEqual(try stagingLeftovers(in: dir), [])
    }

    func testRejectsZipWithTraversalEntries() async throws {
        let dir = try fileActionsTempDir()
        let out = try mkdir(dir, "out")
        let zip = out.appendingPathComponent("evil.zip")
        try makeStoredZip(at: zip, entries: [("ok.txt", Data("fine".utf8)), ("../escaped.txt", Data("evil".utf8))])

        do {
            _ = try await ArchiveExtractor.extract(zip)
            XCTFail("expected traversal rejection")
        } catch {
            XCTAssertEqual(error as? ArchiveError, .unsafeEntry("../escaped.txt"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("escaped.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("evil").path))
        XCTAssertEqual(try stagingLeftovers(in: out), [])
    }

    func testRejectsTarWithTraversalOrAbsoluteEntries() async throws {
        let dir = try fileActionsTempDir()
        let work = try mkdir(dir, "work")
        let inner = try mkdir(work, "inner")
        try Data("evil".utf8).write(to: work.appendingPathComponent("escape.txt"))
        let out = try mkdir(dir, "out")
        let dotdot = out.appendingPathComponent("dotdot.tar")
        try await Tools.run("/usr/bin/tar", ["-c", "-P", "-f", dotdot.path, "-C", inner.path, "../escape.txt"])
        let absolute = out.appendingPathComponent("absolute.tar")
        try await Tools.run("/usr/bin/tar", ["-c", "-P", "-f", absolute.path, work.appendingPathComponent("escape.txt").path])

        for archive in [dotdot, absolute] {
            do {
                _ = try await ArchiveExtractor.extract(archive)
                XCTFail("expected rejection of \(archive.lastPathComponent)")
            } catch {
                guard case .unsafeEntry? = error as? ArchiveError else { return XCTFail("\(error)") }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("escape.txt").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted(),
                       ["absolute.tar", "dotdot.tar"])
    }

    func testRejectsSymlinksPointingOutside() async throws {
        let dir = try fileActionsTempDir()
        for (name, target) in [("absolute", "/etc"), ("relative", "../../outside")] {
            let src = try mkdir(dir, "src-\(name)")
            let pack = try mkdir(src, "pack")
            try touch(pack, "a.txt")
            try FileManager.default.createSymbolicLink(atPath: pack.appendingPathComponent("link").path,
                                                       withDestinationPath: target)
            let out = try mkdir(dir, "out-\(name)")
            let archive = out.appendingPathComponent("\(name).tar.gz")
            try await Tools.run("/usr/bin/tar", ["-c", "-z", "-f", archive.path, "-C", src.path, "pack"])
            do {
                _ = try await ArchiveExtractor.extract(archive)
                XCTFail("expected link rejection for \(name)")
            } catch {
                XCTAssertEqual(error as? ArchiveError, .linkEscapes("pack/link"), name)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["\(name).tar.gz"], name)
        }
    }

    func testAllowsSymlinksInsideArchive() async throws {
        let dir = try fileActionsTempDir()
        let src = try mkdir(dir, "src")
        try sampleTree(in: src)
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("sub/up").path,
                                                   withDestinationPath: "../a.txt")
        let archive = dir.appendingPathComponent("links.tar")
        try await Tools.run("/usr/bin/tar", ["-c", "-f", archive.path, "-C", src.path, "a.txt", "sub"])
        let folder = try await ArchiveExtractor.extract(archive)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("sub/up"), encoding: .utf8), "alpha")
    }

    func testRejectsEmptyArchive() async throws {
        let dir = try fileActionsTempDir()
        let archive = dir.appendingPathComponent("empty.tar")
        try await Tools.run("/usr/bin/tar", ["-c", "-f", archive.path, "-T", "/dev/null"])
        do {
            _ = try await ArchiveExtractor.extract(archive)
            XCTFail("expected empty-archive error")
        } catch {
            XCTAssertEqual(error as? ArchiveError, .empty)
        }
        XCTAssertEqual(try stagingLeftovers(in: dir), [])
    }

    /// Windows Explorer / 7-Zip: `Bericht/Übersicht.txt` stored in CP437/CP850 (Ü = 0x9A, ß = 0xE1)
    /// without the UTF-8 flag. bsdtar can't create those raw bytes as names, so we retry as CP437.
    func testExtractsWindowsZipWithOEMCodePageNames() async throws {
        let dir = try fileActionsTempDir()
        let out = try mkdir(dir, "out")
        let zip = out.appendingPathComponent("windows.zip")
        try makeStoredZip(at: zip, rawEntries: [
            (Data("Bericht/".utf8) + Data([0x9A]) + Data("bersicht.txt".utf8), Data("ue".utf8)),
            (Data("Bericht/Gro".utf8) + Data([0xE1]) + Data("e.txt".utf8), Data("sz".utf8)),
            (Data("Bericht/plain.txt".utf8), Data("plain".utf8)),
            // Top level too: in the C locale `tar -t` lists this as `\232ber.txt`.
            (Data([0x9A]) + Data("ber.txt".utf8), Data("top".utf8)),
        ])
        let folder = try await ArchiveExtractor.extract(zip)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .map(\.precomposedStringWithCanonicalMapping).sorted(), ["Bericht", "Über.txt"])
        let bericht = folder.appendingPathComponent("Bericht")
        let names = try FileManager.default.contentsOfDirectory(atPath: bericht.path)
            .map(\.precomposedStringWithCanonicalMapping).sorted()
        XCTAssertEqual(names, ["Große.txt", "plain.txt", "Übersicht.txt"])
        XCTAssertEqual(try String(contentsOf: bericht.appendingPathComponent("Übersicht.txt"), encoding: .utf8), "ue")
        XCTAssertEqual(try stagingLeftovers(in: out), [])
    }

    /// macOS (ditto, Finder) stores UTF-8 names without the flag: they must not become CP437 mojibake.
    func testZipWithUnflaggedUTF8NamesKeepsThem() async throws {
        let dir = try fileActionsTempDir()
        let out = try mkdir(dir, "out")
        let zip = out.appendingPathComponent("mac.zip")
        try makeStoredZip(at: zip, rawEntries: [(Data("Übersicht.txt".utf8), Data("ue".utf8)),
                                                (Data("b.txt".utf8), Data("b".utf8))])
        let folder = try await ArchiveExtractor.extract(zip)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .map(\.precomposedStringWithCanonicalMapping).sorted()
        XCTAssertEqual(names, ["b.txt", "Übersicht.txt"])
    }

    /// bsdtar's listing escapes (C locale): `\\`, C escapes and `\ooo` octal bytes.
    func testListingEscapesAreDecoded() {
        XCTAssertEqual(ArchiveExtractor.unescapeListing(#"\303\234bersicht.txt"#), "Übersicht.txt")
        XCTAssertEqual(ArchiveExtractor.unescapeListing(#"a\\b"#), #"a\b"#)
        XCTAssertEqual(ArchiveExtractor.unescapeListing(#"new\nline\ttab\177"#), "new\nline\ttab\u{7F}")
        XCTAssertEqual(ArchiveExtractor.unescapeListing(#"\232ber"#), "\u{FFFD}ber")
        XCTAssertEqual(ArchiveExtractor.unescapeListing(#"plain\9\"#), #"plain\9\"#)
        XCTAssertFalse(ArchiveExtractor.isSafeEntryPath(ArchiveExtractor.unescapeListing(#"..\\evil.txt"#)))
        XCTAssertTrue(ArchiveExtractor.isSafeEntryPath(ArchiveExtractor.unescapeListing(#"\303\234ber/a.txt"#)))
    }

    /// `y -> .` lets `notes.txt -> y/y/y/../../../x` look harmless lexically (depth 3 then 0), but the
    /// kernel resolves each `y` first, so the dangling link points three levels up.
    func testDanglingLinkEscapingThroughDotLinksIsRefused() async throws {
        let dir = try fileActionsTempDir()
        let out = try mkdir(dir, "out")
        let tar = out.appendingPathComponent("evil.tar")
        try await makeTar(at: tar, [("l", "y", 0o755, "."),
                                    ("l", "notes.txt", 0o755, "y/y/y/../../../escape-proof.txt")])
        do {
            _ = try await ArchiveExtractor.extract(tar)
            XCTFail("expected link rejection")
        } catch {
            XCTAssertEqual(error as? ArchiveError, .linkEscapes("notes.txt"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["evil.tar"])
    }

    func testResolvesInsideFollowsLinksStepByStep() throws {
        let fm = FileManager.default
        let dir = try fileActionsTempDir()
        let root = try mkdir(dir, "bundle")
        try touch(root, "a.txt")
        try mkdir(root, "sub")
        for (name, target) in [("y", "."), ("loop1", "loop2"), ("loop2", "loop1"), ("inside", "y/y/a.txt"),
                               ("dangling", "sub/missing/new.txt"), ("viaSub", "sub/../y/a.txt"),
                               ("outByName", "y/../bundle/a.txt"), ("up", "y/y/y/../../../x"),
                               ("missingUp", "nothing/../../x")] {
            try fm.createSymbolicLink(atPath: root.appendingPathComponent(name).path, withDestinationPath: target)
        }
        let resolved = try XCTUnwrap(realpath(root.path, nil))
        let real = String(cString: resolved)
        free(resolved)
        for good in ["y", "inside", "dangling", "viaSub", "a.txt", "sub"] {
            XCTAssertTrue(ArchiveExtractor.resolvesInside(good, root: real), good)
        }
        // `outByName` stays inside only by leaving the folder and coming back by its current name.
        for bad in ["loop1", "outByName", "up", "missingUp"] {
            XCTAssertFalse(ArchiveExtractor.resolvesInside(bad, root: real), bad)
        }
        XCTAssertThrowsError(try ArchiveExtractor.verifyContained(root)) { error in
            guard case .linkEscapes? = error as? ArchiveError else { return XCTFail("\(error)") }
        }
    }

    /// Once a component is missing, the walk can't follow later names through links, so a `..`
    /// after it must be refused: with `y -> .`, `nope/../y/..` passes a lexical count (depth 1, 0,
    /// 1, 0) yet leaves the folder as soon as `nope` exists. Plain names after a gap stay allowed.
    func testDotDotAfterMissingComponentIsRefused() throws {
        let fm = FileManager.default
        let dir = try fileActionsTempDir()
        let root = try mkdir(dir, "bundle")
        try mkdir(root, "sub")
        for (name, target) in [("y", "."), ("climb", "nope/../../outside"), ("viaDotLink", "nope/../y/../x"),
                               ("popInside", "nope/../a.txt"), ("plain", "nope/x"), ("plainDeep", "sub/nope/x/y")] {
            try fm.createSymbolicLink(atPath: root.appendingPathComponent(name).path, withDestinationPath: target)
        }
        let resolved = try XCTUnwrap(realpath(root.path, nil))
        let real = String(cString: resolved)
        free(resolved)
        for good in ["plain", "plainDeep", "y"] {
            XCTAssertTrue(ArchiveExtractor.resolvesInside(good, root: real), good)
        }
        for bad in ["climb", "viaDotLink", "popInside"] {
            XCTAssertFalse(ArchiveExtractor.resolvesInside(bad, root: real), bad)
        }

        // Each case on its own through verifyContained (the lexical check alone passes viaDotLink).
        for (target, allowed) in [("nope/../../outside", false), ("nope/../y/../x", false), ("nope/x", true)] {
            let single = try mkdir(dir, "single-\(UUID().uuidString)")
            try fm.createSymbolicLink(atPath: single.appendingPathComponent("y").path, withDestinationPath: ".")
            try fm.createSymbolicLink(atPath: single.appendingPathComponent("a").path, withDestinationPath: target)
            if allowed {
                XCTAssertNoThrow(try ArchiveExtractor.verifyContained(single), target)
            } else {
                XCTAssertThrowsError(try ArchiveExtractor.verifyContained(single), target) { error in
                    XCTAssertEqual(error as? ArchiveError, .linkEscapes("a"), target)
                }
            }
        }
    }

    /// End to end: a dangling link that only escapes through a dot-link after its missing part.
    func testDanglingLinkWithDotDotAfterMissingPartIsRefused() async throws {
        let dir = try fileActionsTempDir()
        let out = try mkdir(dir, "out")
        let tar = out.appendingPathComponent("evil.tar")
        try await makeTar(at: tar, [("l", "y", 0o755, "."),
                                    ("l", "notes.txt", 0o755, "nope/../y/../escape-proof.txt")])
        do {
            _ = try await ArchiveExtractor.extract(tar)
            XCTFail("expected link rejection")
        } catch {
            XCTAssertEqual(error as? ArchiveError, .linkEscapes("notes.txt"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["evil.tar"])
    }

    /// An escaping link next to a read-only folder: the refusal must still remove staging, which holds
    /// unchecked, unflagged content.
    func testRefusedArchiveWithReadOnlyFolderLeavesNoStaging() async throws {
        let dir = try fileActionsTempDir()
        let out = try mkdir(dir, "out")
        let tar = out.appendingPathComponent("payload.tar")
        try await makeTar(at: tar, [("d", "Payload.app", 0o555, ""),
                                    ("f", "Payload.app/run.sh", 0o755, "echo hi"),
                                    ("l", "l", 0o755, "/etc")])
        do {
            _ = try await ArchiveExtractor.extract(tar)
            XCTFail("expected link rejection")
        } catch {
            XCTAssertEqual(error as? ArchiveError, .linkEscapes("l"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["payload.tar"])
    }

    /// bsdtar applies folder modes last, so `sealed/` (mode 000) is unlistable when the check runs.
    func testLinkInsideUnreadableFolderIsRefused() async throws {
        let dir = try fileActionsTempDir()
        let out = try mkdir(dir, "out")
        let tar = out.appendingPathComponent("sealed.tar")
        try await makeTar(at: tar, [("d", "sealed", 0o000, ""), ("l", "sealed/home", 0o755, "/Users")])
        do {
            _ = try await ArchiveExtractor.extract(tar)
            XCTFail("expected link rejection")
        } catch {
            XCTAssertEqual(error as? ArchiveError, .linkEscapes("sealed/home"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["sealed.tar"])
    }

    /// A harmless unreadable folder is fine and keeps its mode.
    func testUnreadableFolderWithoutLinksStillExtracts() async throws {
        let dir = try fileActionsTempDir()
        let tar = dir.appendingPathComponent("locked.tar")
        try await makeTar(at: tar, [("d", "sealed", 0o000, ""), ("f", "sealed/a.txt", 0o644, "a"),
                                    ("f", "b.txt", 0o644, "b")])
        let folder = try await ArchiveExtractor.extract(tar)
        var info = stat()
        XCTAssertEqual(lstat(folder.appendingPathComponent("sealed").path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0)
        XCTAssertEqual(chmod(folder.appendingPathComponent("sealed").path, 0o755), 0)
        XCTAssertEqual(try stagingLeftovers(in: dir), [])
    }

    func testPasswordProtectedZipSaysSo() async throws {
        let dir = try fileActionsTempDir()
        let out = try mkdir(dir, "out")
        let secret = try touch(dir, "s.txt")
        try Data("secret".utf8).write(to: secret)
        let zip = out.appendingPathComponent("enc.zip")
        try await Tools.run("/usr/bin/zip", ["-q", "-j", "-P", "pw", zip.path, secret.path])
        do {
            _ = try await ArchiveExtractor.extract(zip)
            XCTFail("expected encryption error")
        } catch {
            XCTAssertEqual(error as? ArchiveError, .encrypted)
            XCTAssertLessThan(error.localizedDescription.count, 200)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["enc.zip"])
    }

    func testToolOutputInErrorsIsCapped() {
        let flood = String(repeating: "Enter passphrase:", count: 10_000) + " the end"
        let short = ArchiveExtractor.brief(flood)
        XCTAssertEqual(short.count, 300)
        XCTAssertTrue(short.hasSuffix(" the end"))
        XCTAssertEqual(ArchiveExtractor.brief("tar: bad"), "tar: bad")
        guard case .unreadable(let detail) = ArchiveExtractor.tarError(String(repeating: "x", count: 5000) + "\nfailed") else {
            return XCTFail("expected unreadable")
        }
        XCTAssertLessThanOrEqual(detail.count, 300)
        let leftover = ArchiveError.cleanupFailed(folder: ".wheelie-extract-X", reason: "The archive is empty.")
        XCTAssertTrue(leftover.localizedDescription.hasPrefix("The archive is empty."))
        XCTAssertTrue(leftover.localizedDescription.contains(".wheelie-extract-X"))
    }

    func testTopLevelTildeNamesExtract() async throws {
        let dir = try fileActionsTempDir()
        let out = try mkdir(dir, "out")
        let zip = out.appendingPathComponent("budget.zip")
        try makeStoredZip(at: zip, entries: [("~$Budget.xlsx", Data("lock".utf8)), ("Budget.xlsx", Data("b".utf8)),
                                             ("~notes.txt", Data("n".utf8))])
        let folder = try await ArchiveExtractor.extract(zip)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
                       ["Budget.xlsx", "~$Budget.xlsx", "~notes.txt"])
    }

    /// gunzip exits 2 ("trailing garbage ignored") for a complete stream followed by block padding.
    func testGzipWithTrailingPaddingExtracts() async throws {
        let dir = try fileActionsTempDir()
        let notes = dir.appendingPathComponent("notes.txt")
        try Data("hello padded gzip".utf8).write(to: notes)
        let gz = dir.appendingPathComponent("padded.txt.gz")
        try await ArchiveExtractor.runToFile("/usr/bin/gzip", ["-c", notes.path], output: gz)
        let compressed = try Data(contentsOf: gz)
        try (compressed + Data(count: 512)).write(to: gz)

        let out = try await ArchiveExtractor.extract(gz)
        XCTAssertEqual(out.lastPathComponent, "padded.txt")
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "hello padded gzip")
        XCTAssertEqual(try stagingLeftovers(in: dir), [])

        // A truncated stream is still an error.
        let truncated = dir.appendingPathComponent("cut.txt.gz")
        try compressed.prefix(compressed.count / 2).write(to: truncated)
        do {
            _ = try await ArchiveExtractor.extract(truncated)
            XCTFail("expected failure")
        } catch {
            guard case .unreadable? = error as? ArchiveError else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("cut.txt").path))
        XCTAssertEqual(try stagingLeftovers(in: dir), [])
    }

    // MARK: QR codes

    func testOpenableURL() {
        XCTAssertEqual(QRCodeReader.openableURL("https://example.com/a?b=1")?.host, "example.com")
        XCTAssertEqual(QRCodeReader.openableURL("  mailto:hi@example.com ")?.scheme, "mailto")
        XCTAssertEqual(QRCodeReader.openableURL("www.example.com")?.absoluteString, "https://www.example.com")
        XCTAssertNil(QRCodeReader.openableURL("WIFI:S:home;T:WPA;P:secret;;"))
        XCTAssertNil(QRCodeReader.openableURL("file:///etc/passwd"))
        XCTAssertNil(QRCodeReader.openableURL("javascript:alert(1)"))
        XCTAssertNil(QRCodeReader.openableURL("https://"))
        XCTAssertNil(QRCodeReader.openableURL("just some text"))
    }

    func testDetectsQRCodesInImage() throws {
        let dir = try fileActionsTempDir()
        let png = dir.appendingPathComponent("codes.png")
        let image = try canvas(width: 520, height: 1000) { ctx in
            ctx.draw(try qrImage("https://example.com/top"), in: CGRect(x: 60, y: 560, width: 400, height: 400))
            ctx.draw(try qrImage("second code"), in: CGRect(x: 60, y: 40, width: 400, height: 400))
        }
        try writePNG(image, to: png)

        let report = QRCodeReader.scan([png])
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.scanned, 1)
        XCTAssertEqual(report.results.map(\.payload), ["https://example.com/top", "second code"])
        XCTAssertEqual(report.results.first?.symbology, "QR")
        XCTAssertNil(report.results.first?.page)
        XCTAssertEqual(report.results.first?.location, "codes.png")
        XCTAssertEqual(report.results.first?.link?.host, "example.com")
        XCTAssertNil(report.results.last?.link)
    }

    func testDetectsQRCodesOnEveryPDFPage() throws {
        let dir = try fileActionsTempDir()
        let pdf = dir.appendingPathComponent("tickets.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &box, nil))
        for text in ["page one", "page two"] {
            ctx.beginPDFPage(nil)
            // 150 pt is 300 px at the 2x render scale.
            ctx.draw(try qrImage(text), in: CGRect(x: 230, y: 320, width: 150, height: 150))
            ctx.endPDFPage()
        }
        ctx.closePDF()

        var progress: [Int] = []
        let report = QRCodeReader.scan([pdf]) { done, total in
            XCTAssertEqual(total, 2)
            progress.append(done)
        }
        XCTAssertEqual(progress, [1, 2])
        XCTAssertEqual(report.results.map(\.payload), ["page one", "page two"])
        XCTAssertEqual(report.results.map(\.page), [1, 2])
        XCTAssertEqual(report.results.last?.location, "tickets.pdf, page 2")
    }

    func testNoCodesAndUnreadableFiles() throws {
        let dir = try fileActionsTempDir()
        let blank = dir.appendingPathComponent("blank.png")
        try writePNG(try canvas(width: 200, height: 200) { _ in }, to: blank)
        let broken = dir.appendingPathComponent("broken.jpg")
        try Data("not an image".utf8).write(to: broken)
        let report = QRCodeReader.scan([blank, broken])
        XCTAssertEqual(report.results, [])
        XCTAssertEqual(report.failures.map(\.source), [broken])
    }

    /// The wheel's SF Symbols (FileActionsFeature) must exist on this system.
    func testWheelSymbolsExist() {
        for name in ["link", "doc.on.doc", "folder", "airplayaudio", "terminal", "archivebox", "qrcode.viewfinder",
                     "qrcode", "barcode", "checkmark", "exclamationmark.triangle"] {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
        }
    }
}

// MARK: Helpers

private func fileActionsTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-fileactions-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@discardableResult
private func touch(_ dir: URL, _ name: String) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try Data().write(to: url)
    return url
}

@discardableResult
private func mkdir(_ dir: URL, _ name: String) throws -> URL {
    let url = dir.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// `a.txt` ("alpha") and `sub/b.txt` ("beta").
private func sampleTree(in dir: URL) throws {
    try Data("alpha".utf8).write(to: dir.appendingPathComponent("a.txt"))
    let sub = try mkdir(dir, "sub")
    try Data("beta".utf8).write(to: sub.appendingPathComponent("b.txt"))
}

/// Plain tar built with Python's tarfile, so entries can carry any mode or link target.
/// Each entry: ("d" | "f" | "l", name, mode, file contents or link target).
private func makeTar(at url: URL, _ entries: [(kind: String, name: String, mode: Int, payload: String)]) async throws {
    let args = entries.flatMap { [$0.kind, $0.name, String($0.mode, radix: 8), $0.payload] }
    try await Tools.run("/usr/bin/python3", ["-I", "-c", """
    import tarfile, io, sys
    t = tarfile.open(sys.argv[1], 'w', format=tarfile.PAX_FORMAT)
    a = sys.argv[2:]
    for k in range(0, len(a), 4):
        kind, name, mode, payload = a[k:k + 4]
        i = tarfile.TarInfo(name); i.mode = int(mode, 8)
        if kind == 'd':
            i.type = tarfile.DIRTYPE; t.addfile(i)
        elif kind == 'l':
            i.type = tarfile.SYMTYPE; i.linkname = payload; t.addfile(i)
        else:
            data = payload.encode(); i.size = len(data); t.addfile(i, io.BytesIO(data))
    t.close()
    """, url.path] + args)
}

private func stagingLeftovers(in dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".wheelie-extract-") }
}

/// Minimal uncompressed zip, so entry names can be anything (including `../`).
private func makeStoredZip(at url: URL, entries: [(String, Data)]) throws {
    try makeStoredZip(at: url, rawEntries: entries.map { (Data($0.0.utf8), $0.1) })
}

/// Same with raw name bytes and no UTF-8 flag (bit 11), like Windows Explorer and 7-Zip write
/// names that fit the OEM code page, and like macOS ditto writes UTF-8 names.
private func makeStoredZip(at url: URL, rawEntries entries: [(Data, Data)]) throws {
    var out = Data(), central = Data()
    func u16(_ v: Int, _ d: inout Data) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
    func u32(_ v: UInt32, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    for (nameData, data) in entries {
        let crc = crc32(data), offset = UInt32(out.count)
        u32(0x0403_4b50, &out); u16(20, &out); u16(0, &out); u16(0, &out); u16(0, &out); u16(0x21, &out)
        u32(crc, &out); u32(UInt32(data.count), &out); u32(UInt32(data.count), &out)
        u16(nameData.count, &out); u16(0, &out)
        out.append(nameData); out.append(data)

        u32(0x0201_4b50, &central); u16(20, &central); u16(20, &central); u16(0, &central); u16(0, &central)
        u16(0, &central); u16(0x21, &central)
        u32(crc, &central); u32(UInt32(data.count), &central); u32(UInt32(data.count), &central)
        u16(nameData.count, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
        u32(0, &central); u32(offset, &central)
        central.append(nameData)
    }
    let centralOffset = UInt32(out.count)
    out.append(central)
    u32(0x0605_4b50, &out); u16(0, &out); u16(0, &out); u16(entries.count, &out); u16(entries.count, &out)
    u32(UInt32(central.count), &out); u32(centralOffset, &out); u16(0, &out)
    try out.write(to: url)
}

private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
    }
    return ~crc
}

private struct FixtureError: Error {}

/// A crisp QR code CGImage (CIFilter output scaled up by whole pixels).
private func qrImage(_ text: String) throws -> CGImage {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
          let image = CIContext().createCGImage(output, from: output.extent) else { throw FixtureError() }
    return image
}

/// White RGB canvas, drawn by `draw`.
private func canvas(width: Int, height: Int, _ draw: (CGContext) throws -> Void) throws -> CGImage {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw FixtureError() }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.interpolationQuality = .none
    try draw(ctx)
    guard let image = ctx.makeImage() else { throw FixtureError() }
    return image
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw FixtureError()
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw FixtureError() }
}
