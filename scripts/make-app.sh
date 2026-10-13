#!/bin/zsh
# Builds a double-clickable EndTranslate.app (release) into build/.
#   scripts/make-app.sh            → build/EndTranslate.app
#   scripts/make-app.sh --install  → also copies it to ~/Applications and registers it
#                                    with Launch Services (shows up in "Open With" for PDFs)
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/EndTranslate"
APP="build/EndTranslate.app"
mkdir -p build

if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns ]]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/EndTranslate"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp -R Sources/EndTranslate/Resources/Renderer "$APP/Contents/Resources/Renderer"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

if [[ ! -f "$APP/Contents/Resources/Renderer/index.html" ]]; then
  echo "Error: missing Renderer resources in $APP" >&2
  exit 1
fi

codesign --force --sign - "$APP" >/dev/null
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/EndTranslate.app"
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  echo "installed $DEST"
fi
