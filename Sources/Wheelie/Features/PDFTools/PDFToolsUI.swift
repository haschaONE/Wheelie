import AppKit
import PDFKit
import SwiftUI
import WheelieCore

/// Runs blocking work (PDFKit, Vision) off the main thread; cancelling the caller cancels it.
func runDetached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(priority: .userInitiated) { try work() }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

/// Page thumbnails, rendered on demand for the cells on screen. Cells call `show(_:)` when
/// they appear and `hide(_:)` when they go away; pages that scrolled away are not rendered,
/// and the cache keeps at most `budget` bytes of thumbnails that are off screen (least
/// recently shown are dropped first), so a 2,000-page PDF doesn't hold every page as a bitmap.
@MainActor
final class PageThumbnails: ObservableObject {
    @Published private(set) var images: [PageKey: CGImage] = [:]

    /// Bytes of decoded thumbnails kept in all; on-screen ones are never dropped.
    private let budget: Int
    private var renderer: Renderer?
    /// How many cells show each page (Organize can show a page twice).
    private var onScreen: [PageKey: Int] = [:]
    /// Waiting to render; the most recently shown page goes first.
    private var queue: [PageKey] = []
    private var rendering: PageKey?
    private var lastShown: [PageKey: Int] = [:]
    private var clock = 0
    private var bytes = 0

    init(budget: Int = 64 << 20) {
        self.budget = budget
    }

    /// Starts over with these files (thumbnails at most `maxPixels` on the longer side).
    func load(_ files: [URL], maxPixels: CGFloat = 360) {
        cancel()
        renderer = Renderer(files: files, maxPixels: maxPixels)
        for key in onScreen.keys { enqueue(key) }
        next()
    }

    /// A cell showing `key` appeared.
    func show(_ key: PageKey) {
        onScreen[key, default: 0] += 1
        clock += 1
        lastShown[key] = clock
        if images[key] == nil { enqueue(key) }
        next()
    }

    /// A cell showing `key` went away.
    func hide(_ key: PageKey) {
        guard let count = onScreen[key] else { return }
        if count > 1 { onScreen[key] = count - 1 } else { onScreen[key] = nil }
        trim()
    }

    /// Stops rendering and frees the thumbnails (window closed).
    func cancel() {
        renderer?.cancel()
        renderer = nil
        queue = []
        rendering = nil
        images = [:]
        lastShown = [:]
        bytes = 0
    }

    private func enqueue(_ key: PageKey) {
        queue.removeAll { $0 == key }
        if rendering != key { queue.append(key) }
    }

    /// Renders one page at a time, skipping pages that left the screen while waiting.
    private func next() {
        guard rendering == nil, let renderer else { return }
        while let key = queue.popLast() {
            guard onScreen[key] != nil, images[key] == nil else { continue }
            rendering = key
            renderer.render(key) { [weak self] image in
                Task { @MainActor in self?.finished(key, image, from: renderer) }
            }
            return
        }
    }

    private func finished(_ key: PageKey, _ image: CGImage?, from source: Renderer) {
        guard source === renderer else { return }   // started over meanwhile
        rendering = nil
        if let image {
            if let old = images[key] { bytes -= Self.cost(old) }
            images[key] = image
            bytes += Self.cost(image)
            trim()
        }
        next()
    }

    /// Drops the least recently shown off-screen thumbnails until within the budget.
    private func trim() {
        guard bytes > budget else { return }
        let candidates = images.keys.filter { onScreen[$0] == nil }
            .sorted { (lastShown[$0] ?? 0) < (lastShown[$1] ?? 0) }
        for key in candidates {
            guard bytes > budget else { break }
            if let image = images.removeValue(forKey: key) { bytes -= Self.cost(image) }
            lastShown[key] = nil
        }
    }

    private static func cost(_ image: CGImage) -> Int { image.bytesPerRow * image.height }

    /// Opens each file once and renders its pages on one background queue.
    private final class Renderer: @unchecked Sendable {
        private let files: [URL]
        private let maxPixels: CGFloat
        private let queue = DispatchQueue(label: "wheelie.pdf.thumbnails", qos: .userInitiated)
        /// Touched only on `queue`.
        private var documents: [Int: PDFDocument?] = [:]
        private let lock = NSLock()
        private var cancelled = false

        init(files: [URL], maxPixels: CGFloat) {
            self.files = files
            self.maxPixels = maxPixels
        }

        func cancel() {
            lock.withLock { cancelled = true }
            queue.async { self.documents = [:] }
        }

        func render(_ key: PageKey, completion: @escaping @Sendable (CGImage?) -> Void) {
            queue.async {
                guard !self.lock.withLock({ self.cancelled }) else { return completion(nil) }
                let image: CGImage? = autoreleasepool {
                    guard let doc = self.document(key.file) else { return nil }
                    return doc.page(at: key.page).flatMap { try? PDFPageGeometry.thumbnail($0, maxPixels: self.maxPixels) }
                }
                completion(image)
            }
        }

        private func document(_ index: Int) -> PDFDocument? {
            if let cached = documents[index] { return cached }
            let doc = files.indices.contains(index) ? try? PDFSourceLoader.document(for: files[index]) : nil
            documents[index] = doc
            return doc
        }
    }
}

extension View {
    /// Asks `thumbnails` for the page's thumbnail while this cell is on screen.
    func showsThumbnail(_ key: PageKey, from thumbnails: PageThumbnails) -> some View {
        onAppear { thumbnails.show(key) }
            .onDisappear { thumbnails.hide(key) }
    }
}

/// A page thumbnail in a square box, turned by `rotation` degrees clockwise.
struct PageThumbnailView: View {
    let image: CGImage?
    let rotation: Int
    let side: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .background(Color.white)
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                    .rotationEffect(.degrees(Double(rotation)))
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: side * 0.72, height: side * 0.94)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .frame(width: side, height: side)
    }
}

/// Red inline error line used at the bottom of the PDF windows.
struct InlineError: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

extension View {
    /// ⌘W closes the window (menu-bar apps have no File menu to provide it).
    func closesWindowOnCommandW(_ windowID: String, perform: (() -> Void)? = nil) -> some View {
        background {
            Button("Close Window") {
                if let perform { perform() } else { AppServices.shared.closeWindow(id: windowID) }
            }
            .keyboardShortcut("w", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }
}

/// Window ids: one window per tool and file set.
enum PDFWindowID {
    static func make(_ tool: String, _ files: [URL]) -> String {
        tool + ":" + files.map(\.path).joined(separator: "|")
    }
}

/// "“name.pdf”" or "3 files".
func describeFiles(_ files: [URL], noun: String = "files") -> String {
    files.count == 1 ? "“\(files[0].lastPathComponent)”" : "\(files.count) \(noun)"
}
