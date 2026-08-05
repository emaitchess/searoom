#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="${1:-$REPOSITORY_ROOT/dist/Searoom.app}"
KEYCHAIN_PROFILE="${2:-}"
ARCHIVE_PATH="$REPOSITORY_ROOT/dist/Searoom.zip"

if [[ ! -d "$APP_PATH" || -z "$KEYCHAIN_PROFILE" ]]; then
    echo "Usage: $0 [Searoom.app] <notarytool-keychain-profile>" >&2
    exit 64
fi

ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
xcrun notarytool submit "$ARCHIVE_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
rm -f "$ARCHIVE_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"

echo "Notarized $APP_PATH and refreshed $ARCHIVE_PATH with its stapled ticket"
