#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3.10 以降が必要です。"
  exit 1
fi

python3 -m venv .venv-build
.venv-build/bin/python -m pip install --upgrade pip
.venv-build/bin/python -m pip install -e '.[dev]'
.venv-build/bin/python -m PyInstaller \
  --noconfirm \
  --clean \
  --windowed \
  --name 'Kindle Capture' \
  --osx-bundle-identifier 'io.github.masoniana.kindle-capture' \
  --hidden-import ApplicationServices \
  --hidden-import AppKit \
  --hidden-import Foundation \
  --hidden-import Quartz \
  --hidden-import Vision \
  app_entry.py

PLIST='dist/Kindle Capture.app/Contents/Info.plist'
/usr/libexec/PlistBuddy -c "Add :NSScreenCaptureUsageDescription string Kindleの本文画面を画像として保存するために使用します。" "$PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :NSScreenCaptureUsageDescription Kindleの本文画面を画像として保存するために使用します。" "$PLIST"
codesign --force --deep --sign - 'dist/Kindle Capture.app'
ARCH="$(uname -m)"
ARCHIVE="dist/KindleCapture-macOS-${ARCH}.zip"
PACKAGE_DIR="$(mktemp -d "$SCRIPT_DIR/build/kindle-capture-package.XXXXXX")"
trap 'rm -rf -- "$PACKAGE_DIR"' EXIT
ditto 'dist/Kindle Capture.app' "$PACKAGE_DIR/Kindle Capture.app"
cp 'FIRST_RUN.txt' "$PACKAGE_DIR/FIRST_RUN.txt"
rm -f -- "$ARCHIVE"
ditto -c -k --sequesterRsrc "$PACKAGE_DIR" "$ARCHIVE"
echo "作成完了: $SCRIPT_DIR/dist/Kindle Capture.app"
echo "配布ZIP: $SCRIPT_DIR/$ARCHIVE"
