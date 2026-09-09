#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_PATH="$REPOSITORY_ROOT/dist/Searoom.app"
CONTENTS_PATH="$APP_PATH/Contents"
IDENTITY="${CODE_SIGN_IDENTITY:--}"

cd "$REPOSITORY_ROOT"
# -Osize trades a little runtime speed for materially smaller code; the CLI
# and dashboard are not hot-loop bound, and the packaged app is the artifact
# users keep. Debug builds are unaffected.
swift build --configuration "$CONFIGURATION" --disable-sandbox -Xswiftc -Osize
BIN_PATH="$(swift build --configuration "$CONFIGURATION" --show-bin-path --disable-sandbox)"

if [[ "$APP_PATH" != "$REPOSITORY_ROOT/dist/Searoom.app" ]]; then
    echo "Refusing to package an unexpected path: $APP_PATH" >&2
    exit 1
fi

rm -rf "$APP_PATH"
mkdir -p "$CONTENTS_PATH/MacOS" "$CONTENTS_PATH/Resources"

install -m 755 "$BIN_PATH/Searoom" "$CONTENTS_PATH/MacOS/Searoom"
# Strip symbol tables before signing: SwiftPM release ships them otherwise,
# and they cost about half the executable's size. The executable is a product,
# not a library; nothing links against its symbols.
strip "$CONTENTS_PATH/MacOS/Searoom"
install -m 644 "$REPOSITORY_ROOT/Support/Info.plist" "$CONTENTS_PATH/Info.plist"
install -m 644 "$REPOSITORY_ROOT/Brand/AppIcon.icns" "$CONTENTS_PATH/Resources/AppIcon.icns"
install -m 644 "$REPOSITORY_ROOT/LICENSE" "$CONTENTS_PATH/Resources/LICENSE.txt"
install -m 644 "$REPOSITORY_ROOT/THIRD_PARTY_NOTICES.md" "$CONTENTS_PATH/Resources/THIRD_PARTY_NOTICES.md"

RESOURCE_BUNDLE="$BIN_PATH/Searoom_Searoom.bundle"
# The CLI commands read the bundled schema, metric catalog, and agent skill
# through this bundle, so packaging it is required, not optional: a missing
# bundle must fail the build rather than ship a CLI with missing resources.
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    echo "Required resource bundle is missing: $RESOURCE_BUNDLE" >&2
    exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$CONTENTS_PATH/Resources/"
for resource in "Searoom_Searoom.bundle/Contents/Resources/telemetry-v1.schema.json" \
                "Searoom_Searoom.bundle/Contents/Resources/metrics.json" \
                "Searoom_Searoom.bundle/Contents/Resources/SKILL.md"; do
    if [[ ! -f "$CONTENTS_PATH/Resources/$resource" ]]; then
        echo "Required CLI resource missing from bundle: $resource" >&2
        exit 1
    fi
done

plutil -lint "$CONTENTS_PATH/Info.plist"
if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP_PATH"
else
    codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP_PATH"
fi
codesign --verify --deep --strict "$APP_PATH"

echo "Built $APP_PATH"
