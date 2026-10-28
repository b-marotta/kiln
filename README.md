# Kiln

**Kiln** is a macOS menu bar utility for converting and editing files without opening a full app window. Drag a file, hold **Shift**, and work from a glass shelf at the top of the screen.

Outputs are written next to the original. Originals are never overwritten.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`)
- Optional host tools for some formats (see [Optional tools](#optional-tools))

## Install

Build and install to `/Applications`:

```bash
./build.sh
```

The script compiles the app, signs it, installs `/Applications/Kiln.app`, and launches it.

Build only (no install, no launch):

```bash
KILN_BUILD_ONLY=1 ./build.sh
```

## Usage

1. Start a drag from Finder (or another app that provides file URLs).
2. Hold **Shift** (before or during the drag) to show the shelf.
3. Drop the file. The shelf shows a Quick Look preview plus name, type, and size.
4. Choose a section and an action:
   - **Conversioni** — convert to another format
   - **Azioni** — edit in place (image, PDF, audio, documents)
   - **Tool** — pack/extract archives, strip metadata
5. Drop another file to replace the selection, or close with **Esc** / **×**.

Recent jobs appear in the menu bar menu. Share from the file card with the system share sheet.

## Features

### Convert

| Kind | Formats |
|------|---------|
| Images | PNG, JPEG, HEIC, WebP, TIFF, BMP, AVIF, SVG→raster, PDF, multi-image→PDF |
| Video | MP4, MOV, MKV, WEBM, AVI, WMV, GIF (+ extract audio) |
| Audio | MP3, M4A, WAV, FLAC, OGG, OPUS, AIFF, WMA (+ audio→MP4) |
| PDF | → PNG, JPEG, TXT, XLSX (best-effort) |
| Subtitles | SRT ↔ VTT, SRT/VTT → TXT |
| Documents | TXT / MD / RTF → PDF, HTML, TXT; HTML / DOC / DOCX → PDF |
| Spreadsheets | CSV, TSV, XLSX, ODS ↔ and → PDF |

Legacy `.xls` is detected but not readable.

### Edit — images

Available for a single static raster image (not GIF, SVG, or multipage):

- **Crop** — free, 1:1, 16:9, 4:3, 9:16
- **Compress** — quality, pixel scale, live output size; exports only when smaller
- **Adjust** — brightness, contrast, saturation, exposure, temperature, sharpen
- **OCR** — Italian / English, editable text, copy, TXT export
- **Upscale** — offline PiperSR AI upscaling at 2× / 3× / 4× / 5×

Exports a new adjacent PNG, JPEG, HEIC, or WebP when the encoder is available. Each action starts from the original file.

### Edit — PDF & documents

- Merge, split, reorder (move / rotate / duplicate / delete)
- Compress (PDF), OCR → TXT, place a drawn or imported signature
- Other documents (TXT, MD, RTF, HTML, DOC, DOCX): merge, split, reorder, sign

### Edit — audio

Opens automatically for a single audio drop:

- Trim, pitch, speed (optional preserve pitch), reverse, volume envelope
- Waveform preview (Space to play)
- Export WAV, MP3, M4A, FLAC, or AIFF

### Tools

- Strip metadata from images and PDFs
- Pack ZIP / TAR / GZIP
- Extract ZIP / TAR / GZIP / RAR (when `unrar` or `bsdtar` is present)

## Optional tools

Kiln uses system frameworks where it can. Install these for broader coverage:

```bash
brew install ffmpeg webp
```

| Tool | Used for |
|------|----------|
| `ffmpeg` / `ffprobe` | Video and audio conversion and editing |
| `cwebp` | WebP encode |
| `exiftool` | Metadata stripping (when available) |
| `unrar` | RAR extract |

## AI upscaling

**Azioni → Ingrandisci** runs [PiperSR](https://github.com/ModelPiper/PiperSR) locally through Core ML. No network call and no Python runtime.

- Native model scale is 2×; higher factors chain passes
- Alpha is preserved; output is capped at 40 megapixels
- Exports as `*-2x-pipersr.png` (and equivalents for 3×–5×)
- Model package, license, and checksums: `Resources/Upscaling/`

## Project layout

```
Sources/
  App/          Menu bar, shelf UI, editors (image / PDF / audio)
  Core/         Conversion, editing, and task plumbing
  Tools/        Smoke tests
Scripts/        Build helpers (Core ML compile, codesign)
Resources/      App icon, sounds, upscaling models
build.sh        Build, sign, install, launch
```

When you add or move Swift sources, update the `SOURCES` array in `build.sh`.

## Development

Smoke-test upscaling against a built app bundle:

```bash
swiftc -O -parse-as-library -module-cache-path .build/ModuleCache \
  Sources/Core/ConversionModels.swift Sources/Core/ToolResolver.swift \
  Sources/Core/ImageConverter.swift Sources/Core/ImageEditing.swift \
  Sources/Core/ImageUpscaling.swift Sources/Tools/smoke_upscale.swift \
  -framework AppKit -framework CoreML -framework CoreImage -framework Vision \
  -o .build/smoke_upscale
.build/smoke_upscale .build/Kiln.app/Contents/Resources/Upscaling
```

Core ML needs normal access to its temporary and cache directories.

## Acknowledgments

Image upscaling uses [PiperSR](https://github.com/ModelPiper/PiperSR) by Ben Racicot / ModelPiper. Model weights are CC BY 4.0; details and checksums are in `Resources/Upscaling/NOTICE.txt`.
