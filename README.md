# Kiln

Independent macOS menu-bar file converter (clean-room). Capabilities tracked against `../REA-REPORT-Tangerine.md` §8 / `../PROGRESS.md`. Not a derivative of Tangerine’s code or assets.

## Features (v0.3)

- Menu-bar agent (`LSUIElement`) + top-of-screen Liquid Glass file shelf
- Drag a file and press Shift (or hold Shift before dragging) to reveal the drop zone
- Drop to see a Quick Look thumbnail, name, extension and size; select Conversioni / Azioni / Tool, then click an action bubble
- The shelf stays open after the drop; drop another file to replace the selection, or close with Esc / ×
- Command and Control no longer open the radial menu
- Images: PNG / JPEG / HEIC / WebP / TIFF / BMP / AVIF / SVG→raster / PDF / strip metadata
- Image actions (one static raster image): interactive crop (free / 1:1 / 16:9 / 4:3 / 9:16), compression with quality / pixel scale / actual output size, brightness / contrast / saturation / exposure / temperature / sharpening, local Italian/English OCR with editable text / copy / TXT export, and offline PiperSR AI upscaling with 2× / 3× / 4× / 5× factors
- Image editor exports a new adjacent PNG or JPEG (white background for JPEG); originals stay unchanged. Each action works from the original. Compression exports only when smaller. GIF, SVG and multipage images are excluded from editing.
- Video via `ffmpeg`: MP4 / MOV / MKV / AVI / WMV / GIF (+ audio extract)
- Audio via `ffmpeg`: MP3 / M4A / WAV / FLAC / OGG / OPUS / AIFF / WMA
- PDF: images→PDF, PDF→PNG/JPEG/TXT, PDF→XLSX (best-effort)
- Archives: ZIP / TAR / GZIP pack + extract; RAR extract if `unrar`/`bsdtar` available
- Subtitles: SRT↔VTT, →TXT
- Text docs: TXT / MD / RTF → PDF / HTML / TXT
- Spreadsheets: CSV / TSV / XLSX / ODS ↔ + PDF (native Swift; no bundled POI)
- File actions: Reveal, Copy path, AirDrop, Terminal, Float

## Source organization

UI code lives in `Sources/App`, grouped by feature:

- `Editors/PDF`: PDF editor controller, signature placement, signature capture and supporting views.
- `Editors/Audio`: audio editor controller, waveform and supporting controls.
- `Editors/Image`: image editor controller, crop preview and supporting controls.
- `Shelf`: drop overlay, file shelf, previews, action buttons and section selector.
- `RadialMenu`: panel lifecycle, radial layout, hub, petals and unsupported-file banner.

Controllers coordinate their feature; dedicated view files own drawing and input handling.
Small supporting controls stay grouped by feature. Shared glass controls remain in
`Sources/App/LiquidGlass.swift`. Conversion and editing operations remain in `Sources/Core`.

`build.sh` lists source files explicitly: update its `SOURCES` array when adding or moving Swift files.

## Build / run

```bash
./build.sh
open ~/Applications/Kiln.app
```

Host tools (optional): `ffmpeg`, `ffprobe`, `cwebp` (`brew install ffmpeg webp`), `exiftool`, `unrar` (RAR extract).

## Image upscaling

Choose **Azioni → Ingrandisci**, then **2×**, **3×**, **4×** or **5×**.
PiperSR is natively 2×: 2× uses one inference pass, 3×/4× use two, and 5× uses three.
For 3× and 5×, the final overlapping output tiles are resized with Lanczos directly to the
requested dimensions, without allocating a full 4×/8× intermediate for the last pass.
Each choice processes the original image. Hold the eye button to compare with the original;
press/drag on the preview for the detail lens. Export writes a new adjacent PNG named
`*-2x-pipersr.png`, `*-3x-pipersr.png`, `*-4x-pipersr.png` or `*-5x-pipersr.png`,
preserving alpha and leaving the original unchanged.
The editor shows processing progress and elapsed time; changing factor/action cancels the previous job.
Output is limited to 40 MP to bound full-image memory (input limits depend on the chosen factor).
Processing uses overlapping reflected tiles, with RGB inference and separately interpolated alpha.
All inference is local. Repeated passes can amplify artifacts; larger output does not guarantee more detail.

Only PiperSR's model package is included in `Resources/Upscaling`; `build.sh` compiles it with Core ML
and removes obsolete Real-ESRGAN resources from previous builds.
No Python runtime or first-use network download is required. Attribution, source revision and hashes
are recorded in `Resources/Upscaling/NOTICE.txt`, alongside the model license.

For a build without installation or launch: `KILN_BUILD_ONLY=1 ./build.sh`.
Core ML compilation/inference must be allowed access to its normal temporary and cache folders.

Focused inference verification (from `Kiln`):

```bash
swiftc -O -parse-as-library -module-cache-path .build/ModuleCache \
  Sources/Core/ConversionModels.swift Sources/Core/ToolResolver.swift \
  Sources/Core/ImageConverter.swift Sources/Core/ImageEditing.swift \
  Sources/Core/ImageUpscaling.swift Sources/Tools/smoke_upscale.swift \
  -framework AppKit -framework CoreML -framework CoreImage -framework Vision \
  -o .build/smoke_upscale
.build/smoke_upscale .build/Kiln.app/Contents/Resources/Upscaling
```

## Non-goals

- Tangerine branding / code / bundled Tools
- Byte-identical output
- Full DOCX/Pages/PPTX/EPUB (deferred; see `OfficeBridge`)
