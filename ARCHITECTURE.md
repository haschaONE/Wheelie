# Wheelie architecture (read before adding a feature)

Menu-bar app. Hold the trigger modifier (Shift by default) while dragging files →
a two-ring wheel opens under the cursor:

- **Inner ring**: output formats (`ConvertFeature`, built from `OutputFormat`).
- **Outer ring**: tools and file actions from every other feature.

Drop on a petal (or click it in "Open Files…" mode) → `WheelItem.perform(files)`.

## Plugging in

Each feature owns `Sources/Wheelie/Features/<Name>/` and is registered in
`Plugin/Features.swift` (already done for all planned features):

```swift
enum VideoToolsFeature: WheelieFeature {
    static func wheelItems() -> [WheelItem] { [...] }   // petals
    static func menuItems() -> [NSMenuItem] { [...] }   // optional, use ClosureMenuItem
    static func start() { ... }                          // optional, runs at launch
}
```

`WheelItem` (`Plugin/WheelItem.swift`): `id` ("video.trim"), `label` (short, ≤ 12
chars fits best), `symbol` (SF Symbol), `ring` (.outer for tools), `order`,
`accepts(files)` (cheap!), `perform(files) async throws -> WheelOutcome`:

- `.outputs([URL])` — files written. Recorded in history, posted as `.wheelieOutputsProduced`.
- `.message("Copied 3 paths")` — shown in the hub.
- `.none` — e.g. you opened an editor window.

Throw an `Error` with a good `localizedDescription` on failure; the hub shows it.

## Shared services (`Plugin/AppServices.swift`)

- `AppServices.shared.presentWindow(id:title:size:) { SwiftUI view }` — editor windows.
  Use an id like `"video.trim:" + file.path` so re-opening focuses the existing one.
- `AppServices.shared.run(title, sources:) { ... return .outputs(urls) }` — call this
  from an editor's Export button so the job shows in history / progress UI.
- Notifications: `.wheelieOutputsProduced`, `.wheelieJobStarted`, `.wheelieJobFinished`,
  `.wheelieHighlightChanged`.
- `SettingsKey.*` — UserDefaults keys; `AppServices.shared.applySettings()` after changes.

## Core library (`Sources/WheelieCore`) — put testable logic here

- `FileKind(url:)` — .image/.video/.audio/.pdf/.unknown (Documents feature may extend).
- `OutputNaming.uniqueURL(for:ext:suffix:)` — ALWAYS use for output paths: never
  overwrite, respects the "Save to" setting. E.g. `uniqueURL(for: src, ext: "mp4", suffix: " trimmed")`.
- `Tools.run(name, args)` / `Tools.capture(name, args) -> (stdout, stderr)` — run
  Homebrew tools (`ffmpeg`, `ffprobe`, `cwebp`, ...). Always pass `-nostdin` to ffmpeg.
- `Converter` — format conversion.

Put feature logic in `Sources/WheelieCore/<Name>/` (ffmpeg argument builders,
PDF/image operations…) with tests in `Tests/WheelieCoreTests/<Name>Tests.swift`.
UI goes in `Sources/Wheelie/Features/<Name>/`. Generate test fixtures at runtime
(ffmpeg `lavfi`, CoreGraphics, PDFKit) in a temp dir.

## Rules

- Never overwrite or modify the original file; write new files via `OutputNaming`.
- Launch ffmpeg/ffprobe only via `Tools.run`/`Tools.capture`, or pass the arguments through
  `Tools.hardenFFmpegInputs` first (demuxer allowlist + local-only protocols for every input).
- No third-party Swift packages. Apple frameworks + Homebrew CLI tools only
  (check with `Tools.locate`, throw `ToolError.missing` if absent).
- Swift 5 language mode, macOS 14+. UI code is `@MainActor`.
- Editor windows: SwiftUI, live preview, clear primary "Export"/"Save" button,
  sensible defaults, keyboard shortcuts (⌘↩ export, Esc/⌘W close).
- Build: `swift build`; test: `swift test`; bundle: `./scripts/bundle.sh`.
