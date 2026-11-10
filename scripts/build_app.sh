#!/bin/bash
# Build Read Along.app: bundled Python runtime + deps, compiled native shell, ad-hoc sign.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="ReadAlong"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
IDENTITY="${CODESIGN_IDENTITY:--}"
BUILD="$ROOT/build"
APP="$BUILD/$NAME.app"
DEPS="$BUILD/deps"
LOCK="$ROOT/scripts/requirements.lock.txt"

[ "$(uname -m)" = "arm64" ] || { echo "Read Along needs Apple Silicon (MLX)." >&2; exit 1; }
command -v uv >/dev/null || { echo "uv is required: https://docs.astral.sh/uv/" >&2; exit 1; }

clone() {
  rm -rf "$2"
  cp -Rpc "$1" "$2" 2>/dev/null || { rm -rf "$2"; cp -Rp "$1" "$2"; }
}

echo "==> Python runtime"
PY_BIN="$(uv python find 3.12 --managed-python 2>/dev/null || true)"
if [ -z "$PY_BIN" ]; then
  uv python install 3.12
  PY_BIN="$(uv python find 3.12 --managed-python)"
fi
PY_PREFIX="$(cd "$(dirname "$(dirname "$PY_BIN")")" && pwd)"

echo "==> Python packages"
STAMP="$BUILD/deps.sha256"
WANT="$(shasum -a 256 "$LOCK" | cut -d' ' -f1)"
if [ ! -d "$DEPS" ] || [ "$(cat "$STAMP" 2>/dev/null || true)" != "$WANT" ]; then
  rm -rf "$DEPS"
  uv pip install --target "$DEPS" -r "$LOCK"
  echo "$WANT" > "$STAMP"
fi
# fermion-research requires torch, but only its non-Apple-Silicon fallback uses
# it. Read Along runs Phonon on MLX, so drop 600 MB of dead weight.
rm -rf "$DEPS/torch" "$DEPS/torchgen" "$DEPS/functorch" "$DEPS"/torch-*.dist-info
# Read Along uses images only (no video), never datasets/training, and PyMuPDF
# only needs its basic text/render path. Drop the rest of the dead weight.
rm -rf "$DEPS/datasets" "$DEPS"/datasets-*.dist-info \
       "$DEPS/pyarrow" "$DEPS"/pyarrow-*.dist-info \
       "$DEPS/pandas" "$DEPS"/pandas-*.dist-info \
       "$DEPS/cv2" "$DEPS"/opencv_python-*.dist-info \
       "$DEPS/onnxruntime" "$DEPS"/onnxruntime-*.dist-info \
       "$DEPS/sympy" "$DEPS"/sympy-*.dist-info "$DEPS/isympy.py"

echo "==> Bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/backend"
cp "$ROOT/macapp/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
cp "$ROOT/macapp/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cp "$ROOT/readalong.py" "$ROOT/fermion_main.py" "$APP/Contents/Resources/backend/"
# The readalong package (split modules) must sit next to the entry shim so the
# shim's `from readalong.__main__ import main` resolves inside the bundle.
cp -Rp "$ROOT/readalong" "$APP/Contents/Resources/backend/"
# Bundled sample document served at GET /sample. ocr-pdf.pdf is the text PDF;
# ocr.jpg (a handwriting scan) was a dev scratch image and is not shipped.
[ -f "$ROOT/ocr.pdf" ] && cp "$ROOT/ocr.pdf" "$APP/Contents/Resources/backend/"
[ ! -f "$ROOT/ocr.pdf" ] && [ -f "$ROOT/ocr-pdf.pdf" ] && cp "$ROOT/ocr-pdf.pdf" "$APP/Contents/Resources/backend/"
clone "$PY_PREFIX" "$APP/Contents/Resources/backend/python"
clone "$DEPS" "$APP/Contents/Resources/backend/site-packages"

echo "==> Swift UI"
xcrun swiftc -O -target arm64-apple-macos14.0 \
  -framework Cocoa -framework AVFoundation -framework UniformTypeIdentifiers -framework SwiftUI \
  -o "$APP/Contents/MacOS/$NAME" "$ROOT"/macapp/*.swift

echo "==> Sign ($IDENTITY)"
if [ "$IDENTITY" = "-" ]; then
  # Ad-hoc: sign the app (its resource seal covers the bundled files) and the
  # one Mach-O that actually gets exec'd from inside it.
  codesign --force --sign - "$APP/Contents/Resources/backend/python/bin/python3.12"
  codesign --force --options runtime --entitlements "$ROOT/macapp/ReadAlong.entitlements" --sign - "$APP"
else
  codesign --force --deep --options runtime \
    --entitlements "$ROOT/macapp/ReadAlong.entitlements" --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

echo "Built $APP ($VERSION, build $BUILD_NUMBER)"
