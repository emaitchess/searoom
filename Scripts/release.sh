#!/bin/bash
#
# Builds, signs, notarizes, staples, and optionally publishes a Searoom release.
#
#     Scripts/release.sh              # build a verified, notarized dist/Searoom.zip
#     Scripts/release.sh --publish    # also tag and create the GitHub release
#
# Configuration comes from .env.release at the repository root; copy
# .env.release.example and fill it in. That file holds no secrets: the
# notarization credential lives in the keychain, stored once with
#
#     xcrun notarytool store-credentials "<profile>" --apple-id <id> --team-id <team>
#
# and .env.release names the profile rather than repeating its password.
#
# Publishing is opt-in because tagging and creating a GitHub release are public,
# externally visible actions. Everything before that step is local and repeatable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPOSITORY_ROOT"

PUBLISH=0
for argument in "$@"; do
    case "$argument" in
        --publish) PUBLISH=1 ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $argument" >&2; exit 64 ;;
    esac
done

ENV_FILE="${RELEASE_ENV_FILE:-$REPOSITORY_ROOT/.env.release}"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

: "${CODE_SIGN_IDENTITY:?set CODE_SIGN_IDENTITY in $ENV_FILE}"
: "${NOTARY_KEYCHAIN_PROFILE:?set NOTARY_KEYCHAIN_PROFILE in $ENV_FILE}"

APP_PATH="$REPOSITORY_ROOT/dist/Searoom.app"
ARCHIVE_PATH="$REPOSITORY_ROOT/dist/Searoom.zip"
DMG_PATH="$REPOSITORY_ROOT/dist/Searoom.dmg"
VERSION="$(plutil -extract CFBundleShortVersionString raw Support/Info.plist)"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw Support/Info.plist)"
TAG="v$VERSION"

step "Preflight"
echo "Version      $VERSION (build $BUILD_NUMBER)"
echo "Identity     $CODE_SIGN_IDENTITY"
echo "Notary       $NOTARY_KEYCHAIN_PROFILE"

# Each verification captures output before matching it. Piping into `grep -q`
# lets grep exit on the first match, which can SIGPIPE the writer and, under
# `set -o pipefail`, fail the check intermittently even when it passed.
IDENTITIES="$(security find-identity -v -p codesigning)"
grep -qF "$CODE_SIGN_IDENTITY" <<<"$IDENTITIES" \
    || fail "signing identity not in the keychain: $CODE_SIGN_IDENTITY"

xcrun notarytool history --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" >/dev/null 2>&1 \
    || fail "notarytool profile '$NOTARY_KEYCHAIN_PROFILE' is missing or invalid. Store it with: xcrun notarytool store-credentials"

if [[ "$PUBLISH" == 1 ]]; then
    command -v gh >/dev/null || fail "gh is required to publish"
    gh auth status >/dev/null 2>&1 || fail "gh is not authenticated"
    [[ -z "$(git status --porcelain)" ]] || fail "working tree is dirty; commit before publishing $TAG"
    git rev-parse "$TAG" >/dev/null 2>&1 && fail "tag $TAG already exists; bump CFBundleShortVersionString"
    gh release view "$TAG" >/dev/null 2>&1 && fail "release $TAG already exists"
fi
echo "OK"

step "Test"
# XCTest is absent from some Command Line Tools installations. Report that
# honestly rather than letting it look like the suite passed.
if swift test --disable-sandbox 2>/tmp/searoom-release-test.log; then
    echo "Unit tests passed."
elif grep -q "unable to resolve module dependency: 'XCTest'" /tmp/searoom-release-test.log; then
    printf '\033[33mUnit tests DID NOT RUN: XCTest is missing from this toolchain.\033[0m\n'
    printf '\033[33mThe hardware-safe self-test below still runs. CI covers XCTest.\033[0m\n'
else
    cat /tmp/searoom-release-test.log >&2
    fail "unit tests failed"
fi

step "Build and sign"
CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" "$SCRIPT_DIR/build-app.sh"

step "Verify signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNATURE="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
grep -q 'flags=.*runtime' <<<"$SIGNATURE" \
    || fail "hardened runtime missing; notarization would be rejected"
grep -qF "Authority=$CODE_SIGN_IDENTITY" <<<"$SIGNATURE" \
    || fail "app is not signed by the expected Developer ID identity"
grep -q 'TeamIdentifier=' <<<"$SIGNATURE" \
    || fail "team identifier missing; the app is ad-hoc signed"
"$APP_PATH/Contents/MacOS/Searoom" --self-test

step "Notarize and staple"
"$SCRIPT_DIR/notarize.sh" "$APP_PATH" "$NOTARY_KEYCHAIN_PROFILE"

step "Verify the app as Gatekeeper sees it"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

step "Build and notarize the disk image"
# The zip leaves Searoom.app wherever it was expanded, usually ~/Downloads, where
# App Translocation runs quarantined apps from a randomised read-only path and
# SMAppService launch-at-login registration is unreliable. The disk image makes
# dragging to /Applications the obvious gesture.
#
# The app inside is already notarized and stapled, so it stays valid once dragged
# out. The image is signed and notarized separately so it is also valid offline.
STAGING_DIR="$(mktemp -d)"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "Searoom" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGING_DIR"

codesign --force --sign "$CODE_SIGN_IDENTITY" --timestamp "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

CHECKSUM="$(shasum -a 256 "$ARCHIVE_PATH" | cut -d' ' -f1)"
DMG_CHECKSUM="$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)"
SIZE="$(du -h "$ARCHIVE_PATH" | cut -f1 | tr -d ' ')"
DMG_SIZE="$(du -h "$DMG_PATH" | cut -f1 | tr -d ' ')"
echo "Disk image   $DMG_PATH ($DMG_SIZE)"
echo "SHA-256      $DMG_CHECKSUM"
echo "Archive      $ARCHIVE_PATH ($SIZE)"
echo "SHA-256      $CHECKSUM"

if [[ "$PUBLISH" != 1 ]]; then
    step "Done (not published)"
    echo "Re-run with --publish to tag $TAG and create the GitHub release."
    exit 0
fi

step "Publish $TAG"
PREVIOUS_TAG="$(git describe --tags --abbrev=0 "HEAD" 2>/dev/null || true)"

git tag -a "$TAG" -m "Searoom $VERSION"
git push origin "$TAG"

NOTES="Requires macOS 14 or later on Apple silicon. Both downloads are signed with a Developer ID certificate and notarized by Apple, so they open with a normal double-click rather than a Gatekeeper prompt.

\`Searoom.dmg\` is the one to take: drag Searoom to Applications. Launch at login needs the app in a stable location, and an app left in Downloads can be run from a randomised read-only path instead. \`Searoom.zip\` is there for scripted installs.

Searoom has no updater and no network client, so new versions are announced here only. Watch the repository's releases to hear about them.

SHA-256:

    Searoom.dmg  $DMG_CHECKSUM
    Searoom.zip  $CHECKSUM"

# Generated notes need an earlier tag to diff against. On the first release
# there is none, and generating from the repository root would list every commit
# ever made, so the explicit notes stand alone.
if [[ -n "$PREVIOUS_TAG" ]]; then
    gh release create "$TAG" "$DMG_PATH" "$ARCHIVE_PATH" \
        --title "Searoom $VERSION" \
        --generate-notes --notes-start-tag "$PREVIOUS_TAG" \
        --notes "$NOTES" \
        || fail "tag $TAG was pushed but the release failed. Re-run: gh release create $TAG $ARCHIVE_PATH ..."
else
    gh release create "$TAG" "$DMG_PATH" "$ARCHIVE_PATH" \
        --title "Searoom $VERSION" \
        --notes "$NOTES" \
        || fail "tag $TAG was pushed but the release failed. Delete it with: git push --delete origin $TAG && git tag -d $TAG"
fi

echo "Published: $(gh release view "$TAG" --json url -q .url)"
