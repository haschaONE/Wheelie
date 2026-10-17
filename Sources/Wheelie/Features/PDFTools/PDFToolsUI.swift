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

/// Page thumbnails rendered in the background, one PDFDocument per loader task.
@MainActor
final class PageThumbnails: ObservableObject {
    @Published private(set) var images: [PageKey: CGImage] = [:]
    private var tasks: [Task<Void, Never>] = []

    func load(_ files: [URL], maxPixels: CGFloat = 360) {
        for (fileIndex, url) in files.enumerated() {
            tasks.append(Task.detached(priority: .userInitiated) { [weak self] in
                guard let doc = try? PDFSourceLoader.document(for: url) else { return }
                var batch: [(PageKey, CGImage)] = []
                for index in 0..<doc.pageCount {
                    if Task.isCancelled { return }
                    let image: CGImage? = autoreleasepool {
                        doc.page(at: index).flatMap { try? PDFPageGeometry.thumbnail($0, maxPixels: maxPixels) }
                    }
                    if let image { batch.append((PageKey(file: fileIndex, page: index), image)) }
                    if batch.count >= 6 || index == doc.pageCount - 1 {
                        let ready = batch
                        batch = []
                        await self?.add(ready)
                    }
                }
            })
        }
    }

    private func add(_ batch: [(PageKey, CGImage)]) {
        for (key, image) in batch { images[key] = image }
    }

    func cancel() {
        tasks.forEach { $0.cancel() }
        tasks = []
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
