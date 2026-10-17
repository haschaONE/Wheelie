# Tangerine teardown (for Wheelie's design)

Analysed Tangerine 2.0.2 (`com.th.Tangerine`, Mac App Store) with
[REA](https://github.com/morluto/rea) 6.5.0 (`inspect-macho`,
`inspect-native-dispatch-metadata`) plus `otool`/`strings`. Only structure and
behaviour were studied; Wheelie contains no Tangerine code or assets.

## Architecture

- Native arm64 Swift/SwiftUI + AppKit, `LSUIElement` menu-bar app
  (`MenuBarController`, `LoginItemController` via ServiceManagement).
- Bundled helpers in `Resources/`: `Tools/ffmpeg`, `Tools/cwebp`, ExifTool (Perl,
  metadata + privacy scrub scripts), a Java runtime + Apache POI/PDFBox jar for
  PowerPoint, and esbuild-bundled JS (JSZip etc.) run in JavaScriptCore for
  Office preview and Pages writing.
- Paywall/subscriptions through RevenueCat + StoreKit (`UnlockStore`,
  `PaywallModel`, usage counters in Keychain/defaults).

## Core interaction

- `DragGestureMonitor` watches for file drags system-wide;
  `ConversionOverlayController` then shows a glass "fan" (`NativeGlassFanModel`,
  `FormatDropTarget`, petal views, highlight sound). Dropping on a petal runs a
  `ConversionTaskStore` job.
- "Float": a floating shelf window (`FloatingFileWindowController`) holding
  files with drag-out, Quick Look, AirDrop, edge-docking tabs.

## Feature set seen in type names / UI strings

Video: trim, split, speed, snapshot, compress, redaction (timed rectangles).
Audio: trim, channels, normalization, bleep/redaction, visualizer.
Images: crop, adjustments, frames, annotation, redaction, compression.
PDF: organize pages, combine, clean, OCR text, PDF↔Office (DOCX writer,
PPTX via POI), EPUB→PDF. Also QR-code detection (Vision), metadata removal.

## What Wheelie v0.1 takes from this

Same core loop (drag anywhere → radial targets → drop → convert next to
original), redesigned as a full wheel around the drag origin. Uses Homebrew
ffmpeg/cwebp instead of bundling them. No editors, shelf or paywall yet.

## v0.2: matching Tangerine's drag/drop mechanics

- Drag detection is a polling timer (idle ~12 Hz, 60 Hz while the button is
  down) over `NSEvent.pressedMouseButtons`, `NSEvent.modifierFlags` and the drag
  pasteboard changeCount captured before mouse-down — mirrors
  `DragGestureMonitor`'s `pasteboardChangeCountBeforeMouseDown`,
  `previousModifiers`, `shortcutState`, `wasEscapeDown` fields.
- Drops go to one AppKit view covering the wheel (like `ConversionOverlayView`'s
  `draggingEntered/Updated/performDragOperation`); the target petal is chosen by
  angle (`petalCenterAngle`), petals are visuals only.
- Wheelie triggers on Shift.
