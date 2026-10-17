# Wheelie

Menu-bar file converter for macOS. Drag any file and hold **Shift** — a wheel of
format targets spins up around the cursor. Drop on a petal to convert; the
result lands next to the original (`photo.png` → `photo.jpg`, never overwriting).

| Input | Wheel offers |
|---|---|
| Images (PNG, JPG, HEIC, WebP, TIFF, GIF, …) | PNG, JPG, HEIC, WebP, TIFF, PDF |
| Video (MOV, MP4, MKV, WebM, …) | MP4, MOV, WebM, GIF, MP3, M4A |
| Audio (MP3, M4A, WAV, FLAC, …) | MP3, M4A, WAV, FLAC |
| PDF | PNG, JPG (one per page), Text |

Multiple files: the wheel shows formats valid for all of them. Press Esc, drop
on the hub, or release elsewhere to dismiss it. Menu bar → **Convert Files…** opens a
clickable wheel without dragging.

## Requirements

- macOS 14+
- `brew install ffmpeg webp` (video/audio and WebP). Everything else uses
  ImageIO and PDFKit.

## Build

```bash
./scripts/bundle.sh            # build/Wheelie.app
./scripts/bundle.sh --install  # also copy to /Applications
swift test                     # converter tests
```

Headless: `Wheelie.app/Contents/MacOS/Wheelie --convert jpg file1.png file2.heic`

## Layout

- `Sources/WheelieCore` — format matrix, output naming, converters (ImageIO,
  PDFKit, ffmpeg, cwebp).
- `Sources/Wheelie` — status item, global drag detection, wheel panel.

See [NOTES.md](NOTES.md) for the reverse-engineering notes this design came from.
