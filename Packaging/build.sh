#!/bin/zsh
set -eu
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${1:-$PROJECT_DIR/dist}"
if [[ -e "$DEST_DIR/Toplanti.app" ]]; then
  print -u2 "Hedefte Toplanti.app var. Çalışan uygulamayı değiştirmemek için yeni bir çıktı klasörü seçin: $DEST_DIR"
  exit 1
fi
cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFT_MODULECACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
swift build -c release -debug-info-format none --disable-sandbox --disable-keychain --cache-path .build/cache --scratch-path .build

FRAMEWORK_SOURCE="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$FRAMEWORK_SOURCE" ]]; then
  print -u2 "Sparkle.framework bulunamadı: $FRAMEWORK_SOURCE"
  exit 1
fi
mkdir -p "$DEST_DIR"
STAGING_DIR="$(mktemp -d "$DEST_DIR/.meetingdesk-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP="$STAGING_DIR/Toplanti.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/MeetingDesk "$APP/Contents/MacOS/MeetingDesk"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/MeetingDesk-LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/ThirdPartyNotices.txt"
# ditto preserves the framework's version links and executable permissions.
ditto "$FRAMEWORK_SOURCE" "$APP/Contents/Frameworks/Sparkle.framework"
python3 Packaging/release.py configure --app "$APP"

IDENTITY="${CODE_SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
# Sign each executable container inside out. Downloader has its own sandbox
# entitlements; applying one --deep signature would lose this distinction.
for SERVICE in Installer Downloader; do
  SERVICE_PATH="$FRAMEWORK/Versions/B/XPCServices/$SERVICE.xpc"
  if [[ -d "$SERVICE_PATH" ]]; then
    if [[ "$SERVICE" == "Downloader" ]]; then
      codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$SERVICE_PATH"
    else
      codesign "${SIGN_ARGS[@]}" "$SERVICE_PATH"
    fi
  fi
done
codesign "${SIGN_ARGS[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
codesign "${SIGN_ARGS[@]}" "$FRAMEWORK/Versions/B/Updater.app"
codesign "${SIGN_ARGS[@]}" "$FRAMEWORK"
codesign "${SIGN_ARGS[@]}" --identifier com.altugegesari.meetingdesk "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
mv "$APP" "$DEST_DIR/Toplanti.app"
print "Hazır: $DEST_DIR/Toplanti.app"
