#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="$ROOT/outputs"
APP="$OUTPUT/横截.app"
ZIP="$OUTPUT/横截-0.8.0-arm64.zip"

cd "$ROOT"
swift build -c release --product HengJie --arch arm64

rm -rf "$APP" "$OUTPUT"/*.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/arm64-apple-macosx/release/HengJie" "$APP/Contents/MacOS/HengJie"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/README.md" "$OUTPUT/横截-使用说明.md"
cp "$ROOT/KNOWN_COMPATIBILITY.md" "$OUTPUT/横截-兼容性清单.md"
chmod +x "$APP/Contents/MacOS/HengJie"

codesign \
  --force \
  --deep \
  --sign - \
  --identifier com.wonderlab.hengjie \
  --requirements '=designated => identifier "com.wonderlab.hengjie"' \
  "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "已生成：$APP"
echo "压缩包：$ZIP"
