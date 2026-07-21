#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="$ROOT/outputs"
APP="$OUTPUT/横截.app"
ZIP="$OUTPUT/横截-0.11.0-arm64.zip"

cd "$ROOT"
swift build -c release --product HengJie --arch arm64

rm -rf "$APP" "$OUTPUT"/*.zip(N)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/arm64-apple-macosx/release/HengJie" "$APP/Contents/MacOS/HengJie"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/README.md" "$OUTPUT/横截-使用说明.md"
cp "$ROOT/KNOWN_COMPATIBILITY.md" "$OUTPUT/横截-兼容性清单.md"
chmod +x "$APP/Contents/MacOS/HengJie"

SIGNING_MODE="${SIGNING_MODE:-adhoc}"

if [[ "$SIGNING_MODE" == "notarized" ]]; then
  : "${DEVELOPER_ID_APPLICATION:?notarized 构建需要 DEVELOPER_ID_APPLICATION}"
  codesign --force --deep --options runtime --sign "$DEVELOPER_ID_APPLICATION" \
    --identifier com.wonderlab.hengjie "$APP"
else
  codesign \
  --force \
  --deep \
  --sign - \
  --identifier com.wonderlab.hengjie \
  --requirements '=designated => identifier "com.wonderlab.hengjie"' \
  "$APP"
fi

if [[ "$SIGNING_MODE" == "notarized" ]]; then
  : "${NOTARY_PROFILE:?notarized 构建需要 NOTARY_PROFILE}"
  NOTARY_ZIP="$OUTPUT/.横截-notary.zip"
  rm -f "$NOTARY_ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$NOTARY_ZIP"
  xcrun stapler staple "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"

echo "已生成：$APP"
echo "压缩包：$ZIP"
