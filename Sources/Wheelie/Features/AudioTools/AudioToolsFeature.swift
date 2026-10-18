import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WheelieCore

/// The five audio editors. Normalize and Channels also take movies (the video is stream-copied).
enum AudioTool: String, CaseIterable {
    case trim, channels, normalize, bleep, visualizer

    var id: String { "audio.\(rawValue)" }

    var label: String {
        switch self {
        case .trim: return "Trim"
        case .channels: return "Channels"
        case .normalize: return "Normalize"
        case .bleep: return "Bleep"
        case .visualizer: return "Visualizer"
        }
    }

    var windowTitle: String {
        switch self {
        case .trim: return "Trim Audio"
        case .channels: return "Convert Audio Channels"
        case .normalize: return "Normalize Volume"
        case .bleep: return "Bleep Audio"
        case .visualizer: return "Audio Visualizer"
        }
    }

    var symbol: String {
        switch self {
        case .trim: return "timeline.selection"
        case .channels: return "hifispeaker.2"
        case .normalize: return "dial.medium"
        case .bleep: return "speaker.slash"
        case .visualizer: return "music.note.tv"
        }
    }

    var acceptsVideo: Bool { self == .channels || self == .normalize }

    var windowSize: CGSize {
        switch self {
        case .trim: return CGSize(width: 800, height: 540)
        case .channels: return CGSize(width: 800, height: 600)
        case .normalize: return CGSize(width: 800, height: 620)
        case .bleep: return CGSize(width: 840, height: 600)
        case .visualizer: return CGSize(width: 900, height: 640)
        }
    }

    func accepts(_ files: [URL]) -> Bool {
        acceptsVideo ? files.allAre(.audio, .video) : files.allAre(.audio)
    }
}

/// Outer-ring audio tools: Trim, Channels, Normalize, Bleep, Visualizer. Each opens an editor window.
enum AudioToolsFeature: WheelieFeature {
    /// Editors delete their temp folder when they close; one still open when the app quit leaves it behind.
    static func start() {
        TempWorkspace.removeLeftovers(createdBefore: Date())
    }

    static func wheelItems() -> [WheelItem] {
        AudioTool.allCases.enumerated().map { index, tool in
            WheelItem(id: tool.id, label: tool.label, symbol: tool.symbol, ring: .outer, order: 300 + index,
                      accepts: { tool.accepts($0) },
                      perform: { files in
                          AudioEditors.open(tool, files: files)
                          return .none
                      })
        }
    }

    static func menuItems() -> [NSMenuItem] {
        let parent = NSMenuItem(title: "Audio Tools", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Audio Tools")
        for tool in AudioTool.allCases {
            submenu.addItem(ClosureMenuItem("\(tool.windowTitle)…") { AudioEditors.chooseFiles(for: tool) })
        }
        parent.submenu = submenu
        return [parent]
    }
}

@MainActor
enum AudioEditors {
    static func windowID(_ tool: AudioTool, files: [URL]) -> String {
        tool.id + ":" + files.map(\.path).joined(separator: "|")
    }

    static func open(_ tool: AudioTool, files: [URL]) {
        guard !files.isEmpty else { return }
        let id = windowID(tool, files: files)
        let title = files.count == 1 ? "\(tool.windowTitle) — \(files[0].lastPathComponent)"
                                     : "\(tool.windowTitle) — \(files.count) files"
        AppServices.shared.presentWindow(id: id, title: title, size: tool.windowSize) {
            switch tool {
            case .trim: TrimEditorView(model: TrimEditorModel(tool: tool, files: files, windowID: id))
            case .channels: ChannelsEditorView(model: ChannelsEditorModel(tool: tool, files: files, windowID: id))
            case .normalize: NormalizeEditorView(model: NormalizeEditorModel(tool: tool, files: files, windowID: id))
            case .bleep: BleepEditorView(model: BleepEditorModel(tool: tool, files: files, windowID: id))
            case .visualizer: VisualizerEditorView(model: VisualizerEditorModel(tool: tool, files: files, windowID: id))
            }
        }
        if let window = AppServices.shared.window(id: id) {
            window.contentMinSize = CGSize(width: 700, height: tool.windowSize.height - 60)
        }
    }

    /// Menu path: pick files, then open the editor.
    static func chooseFiles(for tool: AudioTool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = tool.acceptsVideo ? [.audio, .movie] : [.audio]
        panel.message = "Choose files for \(tool.windowTitle)"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        guard tool.accepts(panel.urls) else {
            let alert = NSAlert()
            alert.messageText = tool.acceptsVideo ? "Choose audio or video files." : "Choose audio files."
            alert.runModal()
            return
        }
        open(tool, files: panel.urls)
    }
}
