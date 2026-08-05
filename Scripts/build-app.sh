#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_PATH="$REPOSITORY_ROOT/dist/Searoom.app"
CONTENTS_PATH="$APP_PATH/Contents"
IDENTITY="${CODE_SIGN_IDENTITY:--}"

cd "$REPOSITORY_ROOT"
swift build --configuration "$CONFIGURATION" --disable-sandbox
BIN_PATH="$(swift build --configuration "$CONFIGURATION" --show-bin-path --disable-sandbox)"

if [[ "$APP_PATH" != "$REPOSITORY_ROOT/dist/Searoom.app" ]]; then
    echo "Refusing to package an unexpected path: $APP_PATH" >&2
    exit 1
fi

rm -rf "$APP_PATH"
mkdir -p "$CONTENTS_PATH/MacOS" "$CONTENTS_PATH/Resources"

install -m 755 "$BIN_PATH/Searoom" "$CONTENTS_PATH/MacOS/Searoom"
install -m 644 "$REPOSITORY_ROOT/Support/Info.plist" "$CONTENTS_PATH/Info.plist"
install -m 644 "$REPOSITORY_ROOT/Brand/AppIcon.icns" "$CONTENTS_PATH/Resources/AppIcon.icns"
install -m 644 "$REPOSITORY_ROOT/LICENSE" "$CONTENTS_PATH/Resources/LICENSE.txt"
install -m 644 "$REPOSITORY_ROOT/THIRD_PARTY_NOTICES.md" "$CONTENTS_PATH/Resources/THIRD_PARTY_NOTICES.md"

RESOURCE_BUNDLE="$BIN_PATH/Searoom_Searoom.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$CONTENTS_PATH/Resources/"
fi

plutil -lint "$CONTENTS_PATH/Info.plist"
if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP_PATH"
else
    codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP_PATH"
fi
codesign --verify --deep --strict "$APP_PATH"

echo "Built $APP_PATH"
