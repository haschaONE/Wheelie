import CoreGraphics
import XCTest
@testable import WheelieCore

/// Every panel size a Float can have: icon grids for 1–16 items and list mode.
private let panelSizes: [CGSize] = {
    var sizes = (1...16).map { FloatLayout(count: $0, mode: .icons).panelSize }
    sizes += [1, 5, 20].map { FloatLayout(count: $0, mode: .list).panelSize }
    var unique: [CGSize] = []
    for size in sizes where !unique.contains(size) { unique.append(size) }
    return unique
}()

final class FloatDockingRegressionTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)   // visible frame

    /// A Float dragged towards an edge, held at any point of its width, must stay docked
    /// on the very next check (no dock → undock bounce).
    func testAttachIsNeverUndoneRightAway() {
        for size in panelSizes {
            for grab in stride(from: CGFloat(0), through: size.width, by: 4) {
                for edge in [FloatEdge.left, .right] {
                    var attached: (cursor: CGPoint, edge: FloatEdge)?
                    var x: CGFloat = 720
                    while attached == nil, x >= -50, x <= screen.maxX + 50 {
                        let cursor = CGPoint(x: x, y: 400)
                        let frame = CGRect(x: cursor.x - grab, y: 300, width: size.width, height: size.height)
                        if let found = FloatDocking.decision(cursor: cursor, frame: frame, visibleFrame: screen,
                                                             current: nil) {
                            attached = (cursor, found)
                        }
                        x += edge == .right ? 1 : -1
                    }
                    guard let attached else {
                        return XCTFail("never attached: \(size) grab \(grab) towards \(edge)")
                    }
                    XCTAssertEqual(attached.edge, edge)
                    let tab = FloatDocking.tabFrame(edge: edge, centerY: 400, visibleFrame: screen)
                    XCTAssertEqual(FloatDocking.decision(cursor: attached.cursor, frame: tab, visibleFrame: screen,
                                                         current: edge), edge,
                                   "size \(size) grab \(grab) attached at \(attached.cursor.x) then detached")
                }
            }
        }
    }

    /// The reported case: a 4-column Float grabbed 60 pt from its left side used to attach
    /// 163 pt from the right edge, then detach. Now it attaches only within detachDistance.
    func testOvershootNeedsThePointerNearTheEdge() {
        let size = FloatLayout(count: 12).panelSize
        XCTAssertEqual(size.width, 372)
        let cursor = CGPoint(x: 1277, y: 400)
        let frame = CGRect(x: cursor.x - 60, y: 300, width: size.width, height: size.height)
        XCTAssertGreaterThanOrEqual(frame.maxX, screen.maxX + size.width * FloatDocking.overshootFraction)
        XCTAssertNil(FloatDocking.decision(cursor: cursor, frame: frame, visibleFrame: screen, current: nil))
        let nearer = CGPoint(x: screen.maxX - FloatDocking.detachDistance, y: 400)
        let pushed = CGRect(x: nearer.x - 60, y: 300, width: size.width, height: size.height)
        XCTAssertEqual(FloatDocking.decision(cursor: nearer, frame: pushed, visibleFrame: screen, current: nil), .right)
    }

    /// An expanded docked Float can be held anywhere on its header and slid along the edge;
    /// it detaches only once the pointer is pulled clearly beyond its inner side.
    func testExpandedDockedFloatSlidesAlongEdge() {
        for size in panelSizes {
            for edge in [FloatEdge.left, .right] {
                let panel = FloatDocking.attachedFrame(edge: edge, centerY: 400, size: size, visibleFrame: screen)
                for x in stride(from: panel.minX, through: panel.maxX, by: 2) {
                    for dy in [-200, -3, 3, 200] as [CGFloat] {
                        let cursor = CGPoint(x: x, y: panel.maxY - 15 + dy)
                        XCTAssertEqual(FloatDocking.decision(cursor: cursor, frame: panel, visibleFrame: screen,
                                                             current: edge), edge,
                                       "size \(size) \(edge) detached at x \(x)")
                    }
                }
                let threshold = FloatDocking.detachThreshold(frame: panel, edge: edge, visibleFrame: screen)
                XCTAssertGreaterThan(threshold, size.width)
                let away = edge == .left ? screen.minX + threshold + 1 : screen.maxX - threshold - 1
                XCTAssertNil(FloatDocking.decision(cursor: CGPoint(x: away, y: 400), frame: panel, visibleFrame: screen,
                                                   current: edge))
            }
        }
        // The collapsed tab keeps the original hysteresis.
        let tab = FloatDocking.tabFrame(edge: .right, centerY: 400, visibleFrame: screen)
        XCTAssertEqual(FloatDocking.detachThreshold(frame: tab, edge: .right, visibleFrame: screen),
                       FloatDocking.detachDistance)
    }
}

final class FloatSelectionFocusTests: XCTestCase {
    private func makeGroup(_ count: Int) -> (FloatGroup, [UUID]) {
        var group = FloatGroup()
        group.add((0..<count).map { URL(fileURLWithPath: "/tmp/float-focus/\($0).txt") })
        return (group, group.items.map(\.id))
    }

    /// ⇧-arrow after a plain click extends from the clicked item, not from where an
    /// earlier ⇧-range ended.
    func testShiftArrowAfterClickExtendsFromTheClick() {
        let layout = FloatLayout(count: 10, mode: .list)
        var (group, ids) = makeGroup(10)
        func shiftDown() {
            let next = layout.index(from: group.navigationOrigin(extending: true), moving: .down)!
            group.click(ids[next], modifiers: .extend)
        }
        group.click(ids[2], modifiers: [])
        shiftDown()
        XCTAssertEqual(group.selection, [ids[2], ids[3]])
        shiftDown()
        XCTAssertEqual(group.selection, Set(ids[2...4]))   // continues from the range's end

        group.click(ids[7], modifiers: [])
        XCTAssertNil(group.focus)
        shiftDown()
        XCTAssertEqual(group.selection, [ids[7], ids[8]])
    }

    func testFocusResetsOnEveryOtherSelectionChange() {
        var (group, ids) = makeGroup(6)
        func extendTo(_ i: Int) {
            group.click(ids[0], modifiers: [])
            group.click(ids[i], modifiers: .extend)
            XCTAssertEqual(group.focus, ids[i])
        }
        extendTo(3); group.select(only: ids[5]); XCTAssertNil(group.focus)          // type-select
        extendTo(3); group.selectAll(); XCTAssertNil(group.focus)                   // ⌘A
        extendTo(3); group.clearSelection(); XCTAssertNil(group.focus)
        extendTo(3); group.click(ids[4], modifiers: .toggle); XCTAssertNil(group.focus)
        extendTo(3); group.rubberBand(hit: [ids[1]], initial: [], modifiers: []); XCTAssertNil(group.focus)
        extendTo(3); group.setSelection([ids[2]]); XCTAssertNil(group.focus)
        extendTo(3); group.remove([ids[3]]); XCTAssertNil(group.focus)
        // Without a focus, ⇧-arrows start at the anchor.
        group.click(ids[1], modifiers: [])
        XCTAssertEqual(group.navigationOrigin(extending: true), 1)
        XCTAssertEqual(group.navigationOrigin(extending: false), 1)
    }
}

final class FloatVolumeTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-float-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A file on a volume that isn't mounted (ejected disk, share not reconnected after
    /// wake or at login) is unavailable, not deleted: it stays in the Float and its snapshot.
    func testItemsOnUnmountedVolumesAreKept() {
        let url = URL(fileURLWithPath: "/Volumes/WheelieNotMounted-\(UUID().uuidString)/Clips/a.mov")
        let item = FloatItem(url: url)
        XCTAssertEqual(FloatStore.volumeURL(for: item)?.path, url.deletingLastPathComponent().deletingLastPathComponent().path)
        XCTAssertEqual(FloatStore.check(item), .unavailable)
        let restored = FloatStore.item(from: .init(path: url.path, bookmark: nil))
        XCTAssertEqual(restored?.url, url)
        XCTAssertEqual(restored?.isUnavailable, true)

        // The startup disk is always mounted: a deleted file there is gone.
        XCTAssertNil(FloatStore.item(from: .init(path: "/tmp/wheelie-gone-\(UUID().uuidString).txt", bookmark: nil)))
    }

    func testBookmarkedFileOnUnmountedVolumeIsUnavailable() throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("a.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        let item = FloatItem(url: file, bookmark: FloatStore.bookmark(for: file))
        let volume = try XCTUnwrap(FloatStore.volumeURL(for: item))
        XCTAssertTrue(FloatStore.isMountedVolume(volume))
        XCTAssertEqual(FloatStore.check(item), .present)

        try FileManager.default.removeItem(at: file)
        // Same failure (path gone, bookmark won't resolve) as after `hdiutil detach`:
        // the volume decides between "unmounted" and "deleted".
        XCTAssertEqual(FloatStore.check(item, volumeIsMounted: { _ in false }), .unavailable)
        XCTAssertEqual(FloatStore.check(item, volumeIsMounted: { _ in true }), .missing)
        XCTAssertEqual(FloatStore.check(item), .missing)
        XCTAssertFalse(FloatStore.isMountedVolume(URL(fileURLWithPath: "/Volumes/WheelieNotMounted-\(UUID().uuidString)")))
    }

    func testRefreshKeepsUnavailableItemsAndClearsTheMarkWhenBack() {
        var group = FloatGroup()
        group.add([URL(fileURLWithPath: "/Volumes/NAS/a.png"), URL(fileURLWithPath: "/tmp/b.png")])
        var offline = true
        let check: (FloatItem) -> FloatGroup.Check = { item in
            item.url.path.hasPrefix("/Volumes/NAS") && offline ? .unavailable : .present
        }
        XCTAssertTrue(group.refresh(check))
        XCTAssertEqual(group.count, 2)
        XCTAssertEqual(group.items.map(\.isUnavailable), [true, false])
        XCTAssertFalse(group.refresh(check))   // nothing new
        offline = false
        XCTAssertTrue(group.refresh(check))
        XCTAssertEqual(group.items.map(\.isUnavailable), [false, false])
        // Records still carry every item, so a save while offline loses nothing.
        XCTAssertEqual(group.items.map { FloatStore.record(for: $0).path }, ["/Volumes/NAS/a.png", "/tmp/b.png"])
    }
}

final class FloatDuplicateTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-float-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testDuplicateCopiesNextToTheOriginal() throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("report.pdf")
        FileManager.default.createFile(atPath: file.path, contents: Data("pdf".utf8))
        let copy = try FloatStore.duplicate(file)
        XCTAssertEqual(copy.lastPathComponent, "report copy.pdf")
        XCTAssertEqual(try Data(contentsOf: copy), Data("pdf".utf8))
        XCTAssertEqual(try FloatStore.duplicate(file).lastPathComponent, "report copy 2.pdf")
    }

    /// A copy that fails partway (an unreadable file inside a folder) leaves nothing behind.
    func testFailedDuplicateLeavesNoPartialCopy() throws {
        let dir = try makeTempDir()
        let folder = dir.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "c.txt"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data(name.utf8))
        }
        let locked = folder.appendingPathComponent("b.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        if FileManager.default.isReadableFile(atPath: locked.path) { throw XCTSkip("running with root privileges") }

        XCTAssertThrowsError(try FloatStore.duplicate(folder))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Folder copy").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["Folder"])
    }
}
