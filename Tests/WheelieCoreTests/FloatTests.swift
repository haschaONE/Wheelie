import CoreGraphics
import XCTest
@testable import WheelieCore

final class FloatLayoutTests: XCTestCase {
    func testColumnsGrowWithCount() {
        XCTAssertEqual([0, 1, 2, 4, 5, 9, 10, 16, 40].map(FloatLayout.columns(for:)), [2, 2, 2, 2, 3, 3, 4, 4, 4])
        XCTAssertEqual(FloatLayout(count: 0).rows, 1)
        XCTAssertEqual(FloatLayout(count: 3).rows, 2)
        XCTAssertEqual(FloatLayout(count: 10).rows, 3)
        XCTAssertEqual(FloatLayout(count: 17).rows, 5)
    }

    func testPanelSizeGrowsThenScrolls() {
        let one = FloatLayout(count: 1).panelSize
        let five = FloatLayout(count: 5).panelSize
        let sixteen = FloatLayout(count: 16)
        let fifty = FloatLayout(count: 50)
        XCTAssertGreaterThan(five.width, one.width)
        XCTAssertGreaterThan(five.height, one.height)
        XCTAssertFalse(sixteen.scrolls)
        XCTAssertTrue(fifty.scrolls)
        XCTAssertEqual(fifty.panelSize, sixteen.panelSize, "beyond 4×4 the panel stops growing and scrolls")
        XCTAssertGreaterThan(fifty.contentSize.height, fifty.viewportSize.height)
        // Panel = viewport + header + margins.
        let layout = FloatLayout(count: 7)
        XCTAssertEqual(layout.panelSize.width, layout.viewportSize.width + 2 * FloatLayout.margin)
        XCTAssertEqual(layout.panelSize.height,
                       layout.viewportSize.height + FloatLayout.headerHeight + FloatLayout.margin)
    }

    func testItemFramesAndHitTesting() {
        let layout = FloatLayout(count: 5)   // 3 columns, 2 rows
        XCTAssertEqual(layout.columns, 3)
        let first = layout.frame(at: 0)
        let fourth = layout.frame(at: 3)
        XCTAssertEqual(first.origin, CGPoint(x: FloatLayout.contentInset, y: FloatLayout.contentInset))
        XCTAssertEqual(fourth.minX, first.minX)
        XCTAssertEqual(fourth.minY, first.maxY + FloatLayout.spacing)
        XCTAssertEqual(layout.index(at: CGPoint(x: first.midX, y: first.midY)), 0)
        XCTAssertEqual(layout.index(at: CGPoint(x: fourth.midX, y: fourth.midY)), 3)
        // Gap between tiles and the empty sixth cell are misses.
        XCTAssertNil(layout.index(at: CGPoint(x: first.maxX + FloatLayout.spacing / 2, y: first.midY)))
        let sixth = layout.frame(at: 5)
        XCTAssertNil(layout.index(at: CGPoint(x: sixth.midX, y: sixth.midY)))
        XCTAssertNil(layout.index(at: CGPoint(x: 1, y: 1)))
    }

    func testRubberBandIndexes() {
        let layout = FloatLayout(count: 9)   // 3×3
        let a = layout.frame(at: 0), e = layout.frame(at: 4)
        let band = CGRect(x: a.midX, y: a.midY, width: e.midX - a.midX, height: e.midY - a.midY)
        XCTAssertEqual(layout.indexes(in: band), [0, 1, 3, 4])
        XCTAssertEqual(layout.indexes(in: .zero.offsetBy(dx: -50, dy: -50)), [])
    }

    func testKeyboardNavigation() {
        let layout = FloatLayout(count: 5)   // 3 + 2
        XCTAssertEqual(layout.index(from: nil, moving: .right), 0)
        XCTAssertEqual(layout.index(from: nil, moving: .left), 4)
        XCTAssertEqual(layout.index(from: 0, moving: .left), 0)
        XCTAssertEqual(layout.index(from: 1, moving: .down), 4)
        XCTAssertEqual(layout.index(from: 2, moving: .down), 4, "no cell below: jump to the last item")
        XCTAssertEqual(layout.index(from: 4, moving: .up), 1)
        XCTAssertEqual(layout.index(from: 4, moving: .down), 4)
        XCTAssertNil(FloatLayout(count: 0).index(from: nil, moving: .down))
    }

    func testInsertionIndex() {
        let layout = FloatLayout(count: 4)   // 2×2
        let first = layout.frame(at: 0), second = layout.frame(at: 1), third = layout.frame(at: 2)
        XCTAssertEqual(layout.insertionIndex(at: CGPoint(x: first.minX + 5, y: first.midY)), 0)
        XCTAssertEqual(layout.insertionIndex(at: CGPoint(x: first.maxX - 5, y: first.midY)), 1)
        XCTAssertEqual(layout.insertionIndex(at: CGPoint(x: second.maxX - 5, y: second.midY)), 2)
        XCTAssertEqual(layout.insertionIndex(at: CGPoint(x: third.minX + 2, y: third.midY)), 2)
        XCTAssertEqual(layout.insertionIndex(at: CGPoint(x: 9999, y: 9999)), 4)
        let list = FloatLayout(count: 3, mode: .list)
        let row = list.frame(at: 1)
        XCTAssertEqual(list.insertionIndex(at: CGPoint(x: row.midX, y: row.minY + 2)), 1)
        XCTAssertEqual(list.insertionIndex(at: CGPoint(x: row.midX, y: row.maxY - 2)), 2)
    }

    func testListMode() {
        let list = FloatLayout(count: 20, mode: .list)
        XCTAssertEqual(list.columns, 1)
        XCTAssertEqual(list.rows, 20)
        XCTAssertEqual(list.visibleRows, FloatLayout.maxVisibleListRows)
        XCTAssertTrue(list.scrolls)
        XCTAssertEqual(list.panelSize.width, FloatLayout.listWidth)
        XCTAssertEqual(list.frame(at: 1).minY, list.frame(at: 0).maxY)
    }
}

final class FloatDockingTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)   // visible frame

    func testAttachWhenPointerReachesEdge() {
        let frame = CGRect(x: 300, y: 300, width: 200, height: 150)
        XCTAssertNil(FloatDocking.decision(cursor: CGPoint(x: 700, y: 400), frame: frame, visibleFrame: screen, current: nil))
        XCTAssertEqual(FloatDocking.decision(cursor: CGPoint(x: 10, y: 400), frame: frame, visibleFrame: screen,
                                             current: nil), .left)
        XCTAssertEqual(FloatDocking.decision(cursor: CGPoint(x: 1435, y: 400), frame: frame, visibleFrame: screen,
                                             current: nil), .right)
    }

    func testAttachWhenFramePushedPastEdge() {
        // Pointer still well inside, but the Float is shoved half off the right edge.
        let pushed = CGRect(x: 1340, y: 300, width: 200, height: 150)
        XCTAssertEqual(FloatDocking.decision(cursor: CGPoint(x: 1380, y: 400), frame: pushed, visibleFrame: screen,
                                             current: nil), .right)
        // Merely touching the edge is not enough.
        let flush = CGRect(x: 0, y: 300, width: 200, height: 150)
        XCTAssertNil(FloatDocking.decision(cursor: CGPoint(x: 100, y: 400), frame: flush, visibleFrame: screen,
                                           current: nil))
    }

    func testDockedFloatDetachesOnlyWhenPulledAway() {
        let tab = FloatDocking.tabFrame(edge: .left, centerY: 400, visibleFrame: screen)
        // Sliding along the edge, even a bit outwards, stays attached (hysteresis).
        XCTAssertEqual(FloatDocking.decision(cursor: CGPoint(x: 60, y: 100), frame: tab, visibleFrame: screen,
                                             current: .left), .left)
        XCTAssertEqual(FloatDocking.decision(cursor: CGPoint(x: FloatDocking.detachDistance, y: 400), frame: tab,
                                             visibleFrame: screen, current: .left), .left)
        XCTAssertNil(FloatDocking.decision(cursor: CGPoint(x: FloatDocking.detachDistance + 1, y: 400), frame: tab,
                                           visibleFrame: screen, current: .left))
        XCTAssertNil(FloatDocking.decision(cursor: CGPoint(x: 1000, y: 400), frame: tab, visibleFrame: screen,
                                           current: .right))
    }

    func testSharedDisplayEdgesDontDock() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
        XCTAssertEqual(FloatDocking.outerEdges(of: main, others: [main, right], at: 400), [.left])
        XCTAssertEqual(FloatDocking.outerEdges(of: right, others: [main, right], at: 400), [.right])
        // Below the smaller display the big one's left edge is free again.
        XCTAssertEqual(FloatDocking.outerEdges(of: right, others: [main, right], at: -100), [.left, .right])
        XCTAssertEqual(FloatDocking.outerEdges(of: main, others: [main], at: 400), [.left, .right])

        let frame = CGRect(x: 1300, y: 300, width: 200, height: 150)
        XCTAssertNil(FloatDocking.decision(cursor: CGPoint(x: 1435, y: 400), frame: frame, visibleFrame: screen,
                                           current: nil, allowed: [.left]))
        XCTAssertEqual(FloatDocking.collapseEdge(for: frame, visibleFrame: screen, allowed: [.left]), .left)
        XCTAssertEqual(FloatDocking.collapseEdge(for: frame, visibleFrame: screen, allowed: [.left, .right]), .right)
    }

    func testTabFrameIsFlushAndOnScreen() {
        let right = FloatDocking.tabFrame(edge: .right, centerY: 400, visibleFrame: screen)
        XCTAssertEqual(right.maxX, screen.maxX)
        XCTAssertEqual(right.midY, 400)
        XCTAssertEqual(right.size, FloatDocking.tabSize)
        let left = FloatDocking.tabFrame(edge: .left, centerY: 5000, visibleFrame: screen)
        XCTAssertEqual(left.minX, screen.minX)
        XCTAssertEqual(left.maxY, screen.maxY - FloatDocking.verticalInset)
        let low = FloatDocking.tabFrame(edge: .left, centerY: -100, visibleFrame: screen)
        XCTAssertEqual(low.minY, screen.minY + FloatDocking.verticalInset)

        // Second display to the right with a menu bar offset.
        let other = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        XCTAssertEqual(FloatDocking.tabFrame(edge: .left, centerY: 500, visibleFrame: other).minX, 1440)
    }

    func testExpandedDockedFrame() {
        let size = CGSize(width: 290, height: 470)
        let frame = FloatDocking.attachedFrame(edge: .right, centerY: 860, size: size, visibleFrame: screen)
        XCTAssertEqual(frame.maxX, screen.maxX)
        XCTAssertEqual(frame.size, size)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY)
    }

    func testNearestEdgeClampAndCascade() {
        XCTAssertEqual(FloatDocking.nearestEdge(of: CGRect(x: 100, y: 0, width: 200, height: 100), in: screen), .left)
        XCTAssertEqual(FloatDocking.nearestEdge(of: CGRect(x: 1000, y: 0, width: 200, height: 100), in: screen), .right)

        let clamped = FloatDocking.clamp(CGRect(x: -50, y: 800, width: 200, height: 150), to: screen)
        XCTAssertEqual(clamped.origin, CGPoint(x: 0, y: screen.maxY - 150))

        let centered = FloatDocking.frame(centeredOn: CGPoint(x: 720, y: 400), size: CGSize(width: 200, height: 100),
                                          visibleFrame: screen)
        XCTAssertEqual(centered, CGRect(x: 620, y: 350, width: 200, height: 100))
        let next = FloatDocking.cascade(centered, avoiding: [centered], visibleFrame: screen)
        XCTAssertNotEqual(next.origin, centered.origin)
        XCTAssertEqual(FloatDocking.cascade(centered, avoiding: [], visibleFrame: screen), centered)

        let detached = FloatDocking.detachedFrame(cursor: CGPoint(x: 500, y: 500), size: CGSize(width: 200, height: 150),
                                                  headerHeight: 30)
        XCTAssertEqual(detached.midX, 500)
        XCTAssertEqual(detached.maxY, 515)
    }
}

final class FloatGroupTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/tmp/float/a.png")
    private let b = URL(fileURLWithPath: "/tmp/float/b.pdf")
    private let c = URL(fileURLWithPath: "/tmp/float/c.mov")
    private let d = URL(fileURLWithPath: "/tmp/float/Docs")

    func testSameFileIsAddedOnce() {
        var group = FloatGroup()
        let first = group.add([a, b, a])
        XCTAssertEqual(first.added.count, 2)
        XCTAssertEqual(first.existing.count, 0)

        let again = group.add([URL(fileURLWithPath: "/tmp/float/sub/../a.png"), c])
        XCTAssertEqual(again.added.map(\.url), [c])
        XCTAssertEqual(again.existing, [group.items[0].id])
        XCTAssertEqual(group.count, 3)

        // Same name in decomposed Unicode (as some apps hand it over) is the same file.
        var unicode = FloatGroup()
        unicode.add([URL(fileURLWithPath: "/tmp/caf\u{E9}.txt")])
        unicode.add([URL(fileURLWithPath: "/tmp/cafe\u{301}.txt")])
        XCTAssertEqual(unicode.count, 1)

        // Non-file URLs are ignored.
        group.add([URL(string: "https://example.com/x.png")!])
        XCTAssertEqual(group.count, 3)
        XCTAssertTrue(group.contains(URL(fileURLWithPath: "/tmp/float/./b.pdf")))
    }

    func testClickSelection() {
        var group = FloatGroup()
        group.add([a, b, c, d])
        let ids = group.items.map(\.id)
        group.click(ids[1], modifiers: [])
        XCTAssertEqual(group.selection, [ids[1]])
        group.click(ids[3], modifiers: .extend)
        XCTAssertEqual(group.selection, Set(ids[1...3]))
        group.click(ids[2], modifiers: .toggle)
        XCTAssertEqual(group.selection, [ids[1], ids[3]])
        group.click(ids[0], modifiers: [.toggle, .extend])   // ⌘⇧ adds the range from the anchor
        XCTAssertEqual(group.selection, Set(ids))
        group.click(ids[0], modifiers: [])
        XCTAssertEqual(group.selectedURLs, [a])
        group.selectAll()
        XCTAssertEqual(group.selectedURLs, [a, b, c, d])
        group.remove([ids[0], ids[1]])
        XCTAssertEqual(group.selectedURLs, [c, d])
        group.clearSelection()
        XCTAssertTrue(group.selection.isEmpty)
    }

    func testRubberBandSelection() {
        var group = FloatGroup()
        group.add([a, b, c, d])
        let ids = group.items.map(\.id)
        let initial: Set<UUID> = [ids[0], ids[1]]
        group.rubberBand(hit: [ids[1], ids[2]], initial: initial, modifiers: [])
        XCTAssertEqual(group.selection, [ids[1], ids[2]])
        group.rubberBand(hit: [ids[1], ids[2]], initial: initial, modifiers: .extend)
        XCTAssertEqual(group.selection, [ids[0], ids[1], ids[2]])
        group.rubberBand(hit: [ids[1], ids[2]], initial: initial, modifiers: .toggle)
        XCTAssertEqual(group.selection, [ids[0], ids[2]])
    }

    func testReorderAndTypeSelect() {
        var group = FloatGroup()
        group.add([a, b, c, d])
        let ids = group.items.map(\.id)
        group.move([ids[0]], to: 3)
        XCTAssertEqual(group.allURLs, [b, c, a, d])
        group.move([ids[3], ids[1]], to: 0)
        XCTAssertEqual(group.allURLs, [b, d, c, a])
        XCTAssertEqual(group.firstItem(matching: "do")?.url, d)
        XCTAssertEqual(group.firstItem(matching: "C")?.url, c)
        XCTAssertNil(group.firstItem(matching: "zz"))
    }

    func testRefreshFollowsMovesAndDropsMissing() {
        var group = FloatGroup()
        group.add([a, b, c])
        let moved = URL(fileURLWithPath: "/tmp/float/renamed.png")
        group.selectAll()
        let changed = group.refresh { item in
            switch item.url {
            case self.a: return .moved(moved, bookmark: Data([1]))
            case self.b: return .missing
            default: return .present
            }
        }
        XCTAssertTrue(changed)
        XCTAssertEqual(group.allURLs, [moved, c])
        XCTAssertEqual(group.items[0].bookmark, Data([1]))
        XCTAssertEqual(group.selection.count, 2)
        XCTAssertFalse(group.refresh { _ in .present })
        // A file moved onto one we already hold collapses into one item.
        XCTAssertTrue(group.refresh { $0.url == moved ? .moved(self.c, bookmark: nil) : .present })
        XCTAssertEqual(group.allURLs, [c])
    }
}

final class FloatStoreTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-float-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeFile(_ name: String, in dir: URL) -> URL {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("float".utf8))
        return url
    }

    func testSnapshotRoundTrip() throws {
        let snapshots = [
            FloatSnapshot(id: UUID(), frame: CGRect(x: 10, y: 20, width: 196, height: 148),
                          items: [.init(path: "/tmp/a.png", bookmark: Data([1, 2, 3])), .init(path: "/tmp/b", bookmark: nil)]),
            FloatSnapshot(id: UUID(), frame: CGRect(x: 500, y: 300, width: 272, height: 200), edge: .right,
                          dockCenterY: 412.5, displayID: 69_733_632, viewMode: .list,
                          items: [.init(path: "/tmp/c.mov", bookmark: nil)]),
        ]
        XCTAssertEqual(FloatStore.decode(try FloatStore.encode(snapshots)), snapshots)
        XCTAssertEqual(FloatStore.decode(Data("not json".utf8)), [])

        let suite = "wheelie.float.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        FloatStore.save(snapshots, to: defaults)
        XCTAssertEqual(FloatStore.load(from: defaults), snapshots)
        FloatStore.save([], to: defaults)
        XCTAssertNil(defaults.data(forKey: FloatStore.defaultsKey))
        XCTAssertEqual(FloatStore.load(from: defaults), [])
    }

    func testItemsRestoreThroughBookmarks() throws {
        let dir = try makeTempDir()
        let file = makeFile("photo.png", in: dir)
        let item = FloatItem(url: file, bookmark: FloatStore.bookmark(for: file))
        XCTAssertNotNil(item.bookmark)
        let record = FloatStore.record(for: item)
        XCTAssertEqual(record.path, file.path)

        // Still there.
        XCTAssertEqual(FloatStore.item(from: record)?.url.standardizedFileURL.path, file.standardizedFileURL.path)
        XCTAssertEqual(FloatStore.check(item), .present)

        // Renamed: the bookmark finds it.
        let renamed = dir.appendingPathComponent("renamed.png")
        try FileManager.default.moveItem(at: file, to: renamed)
        guard case .moved(let url, _) = FloatStore.check(item) else {
            return XCTFail("expected the bookmark to follow the rename")
        }
        XCTAssertEqual(url.resolvingSymlinksInPath().path, renamed.resolvingSymlinksInPath().path)
        XCTAssertEqual(FloatStore.item(from: record)?.url.resolvingSymlinksInPath().path,
                       renamed.resolvingSymlinksInPath().path)

        // Deleted: gone, and a record without a bookmark can't come back either.
        try FileManager.default.removeItem(at: renamed)
        XCTAssertEqual(FloatStore.check(item), .missing)
        XCTAssertNil(FloatStore.item(from: record))
        XCTAssertNil(FloatStore.item(from: .init(path: file.path, bookmark: nil)))
    }

    func testRefreshAgainstRealFiles() throws {
        let dir = try makeTempDir()
        let keep = makeFile("keep.txt", in: dir)
        let move = makeFile("move.txt", in: dir)
        let delete = makeFile("delete.txt", in: dir)
        var group = FloatGroup()
        group.add([keep, move, delete], bookmark: FloatStore.bookmark(for:))
        let moved = dir.appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at: move, to: moved)
        try FileManager.default.removeItem(at: delete)
        XCTAssertTrue(group.refresh { FloatStore.check($0) })
        XCTAssertEqual(group.allURLs.map { $0.resolvingSymlinksInPath().lastPathComponent }, ["keep.txt", "moved.txt"])
    }

    func testTrashDetection() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(FloatStore.isInTrash(home.appendingPathComponent(".Trash/old.png")))
        XCTAssertTrue(FloatStore.isInTrash(URL(fileURLWithPath: "/Volumes/Disk/.Trashes/501/old.png")))
        XCTAssertFalse(FloatStore.isInTrash(home.appendingPathComponent("Desktop/new.png")))
        XCTAssertFalse(FloatStore.isInTrash(URL(fileURLWithPath: "/tmp/Trash/new.png")))
    }

    func testDuplicateNaming() throws {
        let dir = try makeTempDir()
        let file = makeFile("report.pdf", in: dir)
        XCTAssertEqual(FloatStore.duplicateURL(for: file).lastPathComponent, "report copy.pdf")
        _ = makeFile("report copy.pdf", in: dir)
        XCTAssertEqual(FloatStore.duplicateURL(for: file).lastPathComponent, "report copy 2.pdf")
        let folder = dir.appendingPathComponent("v1.2")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(FloatStore.duplicateURL(for: folder).lastPathComponent, "v1.2 copy")
        XCTAssertEqual(FloatStore.duplicateURL(for: dir.appendingPathComponent("Makefile")).lastPathComponent,
                       "Makefile copy")
    }
}
