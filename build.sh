#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/.build"
APP="$BUILD/Kiln.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

mkdir -p "$MACOS" "$RES"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$RES/AppIcon.icns"
fi
# Petal hover tick (CAF — NSSound does not load OGG).
if [[ -f "$ROOT/Resources/mouseclick1.caf" ]]; then
  cp "$ROOT/Resources/mouseclick1.caf" "$RES/mouseclick1.caf"
elif [[ -f "$ROOT/Resources/mouseclick1.ogg" ]] && command -v afconvert >/dev/null; then
  afconvert -f caff -d LEI16 "$ROOT/Resources/mouseclick1.ogg" "$RES/mouseclick1.caf"
fi

SOURCES=(
  "$ROOT/Sources/Core/ConversionModels.swift"
  "$ROOT/Sources/Core/ToolResolver.swift"
  "$ROOT/Sources/Core/PasteboardFileURLs.swift"
  "$ROOT/Sources/Core/ImageConverter.swift"
  "$ROOT/Sources/Core/ImageEditing.swift"
  "$ROOT/Sources/Core/ImageUpscaling.swift"
  "$ROOT/Sources/Core/FFmpegConverter.swift"
  "$ROOT/Sources/Core/AudioEditing.swift"
  "$ROOT/Sources/Core/PDFConverter.swift"
  "$ROOT/Sources/Core/PDFActions.swift"
  "$ROOT/Sources/Core/MetadataScrubber.swift"
  "$ROOT/Sources/Core/ArchiveConverter.swift"
  "$ROOT/Sources/Core/SubtitleConverter.swift"
  "$ROOT/Sources/Core/DocumentConverter.swift"
  "$ROOT/Sources/Core/SpreadsheetConverter.swift"
  "$ROOT/Sources/Core/SharingActions.swift"
  "$ROOT/Sources/Core/ConversionEngine.swift"
  "$ROOT/Sources/Core/OfficeBridge.swift"
  "$ROOT/Sources/Core/ConversionTaskStore.swift"
  "$ROOT/Sources/Core/BookmarkStore.swift"
  "$ROOT/Sources/Core/UnlockStore.swift"
  "$ROOT/Sources/Core/DragModifierSettings.swift"
  "$ROOT/Sources/App/FloatWindowController.swift"
  "$ROOT/Sources/App/Editors/Audio/AudioEditorWindowController.swift"
  "$ROOT/Sources/App/Editors/Audio/AudioEditorViews.swift"
  "$ROOT/Sources/App/Editors/Audio/AudioWaveformView.swift"
  "$ROOT/Sources/App/Editors/PDF/PDFEditorWindowController.swift"
  "$ROOT/Sources/App/Editors/PDF/SignaturePDFView.swift"
  "$ROOT/Sources/App/Editors/PDF/SignaturePad.swift"
  "$ROOT/Sources/App/Editors/PDF/PDFEditorViews.swift"
  "$ROOT/Sources/App/Editors/Image/ImageEditorWindowController.swift"
  "$ROOT/Sources/App/Editors/Image/ImageEditorViews.swift"
  "$ROOT/Sources/App/Editors/Image/ImageCropPreview.swift"
  "$ROOT/Sources/App/LiquidGlass.swift"
  "$ROOT/Sources/App/RadialMenu/FanActionPanel.swift"
  "$ROOT/Sources/App/RadialMenu/UnsupportedBannerView.swift"
  "$ROOT/Sources/App/RadialMenu/RadialFanView.swift"
  "$ROOT/Sources/App/RadialMenu/FanHubChromeView.swift"
  "$ROOT/Sources/App/RadialMenu/FanPetalsView.swift"
  "$ROOT/Sources/App/Shelf/DropOverlayController.swift"
  "$ROOT/Sources/App/Shelf/FileShelfPanel.swift"
  "$ROOT/Sources/App/Shelf/FileShelfView.swift"
  "$ROOT/Sources/App/Shelf/ShelfPreviewViews.swift"
  "$ROOT/Sources/App/Shelf/ShelfButtons.swift"
  "$ROOT/Sources/App/Shelf/GlassSectionSelector.swift"
  "$ROOT/Sources/App/DragGestureMonitor.swift"
  "$ROOT/Sources/App/MenuBarController.swift"
  "$ROOT/Sources/App/AppDelegate.swift"
  "$ROOT/Sources/App/main.swift"
)

swiftc -O \
  -module-cache-path "$BUILD/ModuleCache" \
  -target arm64-apple-macos13.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -framework AppKit \
  -framework AVFoundation \
  -framework QuartzCore \
  -framework Combine \
  -framework CoreImage \
  -framework CoreML \
  -framework ImageIO \
  -framework PDFKit \
  -framework Vision \
  -framework CoreText \
  -framework UniformTypeIdentifiers \
  -framework QuickLookThumbnailing \
  -o "$MACOS/Kiln" \
  "${SOURCES[@]}"

swiftc -module-cache-path "$BUILD/ModuleCache" "$ROOT/Scripts/compile-upscale-models.swift" \
  -framework CoreML -o "$BUILD/compile-upscale-models"
"$BUILD/compile-upscale-models" "$ROOT/Resources/Upscaling" "$RES/Upscaling"

# Allow verification/building without replacing or opening the installed app.
if [[ "${KILN_BUILD_ONLY:-0}" == "1" ]]; then
  codesign --force --deep --sign - "$APP"
  echo "Built $APP"
  exit 0
fi

# Stable codesign so macOS TCC (Desktop/Documents access) survives rebuilds.
BUNDLE_ID="io.leapstudio.clone.kiln"
IDENTITY=""
if IDENTITY_LINE=$(security find-identity -v -p codesigning 2>/dev/null | grep -E 'Apple Development|Developer ID Application' | head -1); then
  IDENTITY=$(awk '{print $2}' <<<"$IDENTITY_LINE")
elif [[ -x "$ROOT/Scripts/ensure-local-codesign.sh" ]]; then
  IDENTITY=$("$ROOT/Scripts/ensure-local-codesign.sh" || true)
fi

sign_app() {
  local target="$1"
  if [[ -n "${IDENTITY}" ]] && codesign --force --deep --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$target"; then
    return 0
  fi
  codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$target" || true
  return 1
}

if sign_app "$APP"; then
  echo "Signed with: $IDENTITY"
else
  echo "Warning: ad-hoc sign only — Desktop permission may re-prompt each rebuild."
fi

# Quit a running copy before replacing its bundle. LSUIElement apps stay
# alive across rebuilds otherwise, and rm -rf on a live .app fails the seal.
quit_if_running() {
  local name="$1"
  pgrep -x "$name" >/dev/null 2>&1 || return 0
  echo "Quitting ${name}..."
  osascript -e "tell application \"$name\" to quit" >/dev/null 2>&1 || true
  local i
  for ((i = 0; i < 30; i++)); do
    pgrep -x "$name" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  killall "$name" >/dev/null 2>&1 || true
  for ((i = 0; i < 10; i++)); do
    pgrep -x "$name" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
}

# Fixed install path — always launch this copy after rebuilds.
STABLE_APP="${HOME}/Applications/Kiln.app"
mkdir -p "${HOME}/Applications"
quit_if_running Kiln
rm -rf "$STABLE_APP"
cp -R "$APP" "$STABLE_APP"
# Re-sign after copy (copy invalidates seal).
sign_app "$STABLE_APP" >/dev/null || true


echo "--------------------------------"
echo "Built $APP"
echo "Stable: $STABLE_APP"
echo "--------------------------------"
echo "--------------------------------"

echo "Opening $STABLE_APP"
echo "--------------------------------"
open "$STABLE_APP"

echo "App running..."
echo "--------------------------------"
