#!/bin/bash
# Builds a signed, notarized JottaFS release and packages it as
# dist/JottaFS-<version>.dmg (drag-to-Applications installer).
#
#   scripts/build-release.sh            # bump the patch version (1.0.0 → 1.0.1)
#   scripts/build-release.sh --minor    # 1.0.4 → 1.1.0
#   scripts/build-release.sh --major    # 1.4.2 → 2.0.0
#
# The first build is 1.0.0. VERSION holds the last version built; it is
# updated only when the build succeeds. This script never tags or publishes:
# use scripts/publish-release.sh for that.
#
# Requirements (one-time setup, see docs/releasing.md):
#   - A "Developer ID Application" certificate for team $TEAM_ID.
#   - Notarization credentials stored in the keychain:
#       xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#           --apple-id <apple-id> --team-id <team-id>
#   - Permission for Terminal to control Finder (asked on first run; used to
#     lay out the DMG window).
#
# Environment:
#   NOTARY_PROFILE   keychain profile for notarytool (default: JottaFS-notary)
#   SKIP_NOTARIZE=1  build and package without notarizing (for testing only)

set -euo pipefail

TEAM_ID="PLY3DSPA3F"
NOTARY_PROFILE="${NOTARY_PROFILE:-JottaFS-notary}"
APP_NAME="JottaFS"
SCHEME="JottaFS"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build/release"
DIST="$ROOT/dist"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# MARK: Version

BUMP="patch"
for argument in "$@"; do
    case "$argument" in
        --minor) BUMP="minor" ;;
        --major) BUMP="major" ;;
        --patch) BUMP="patch" ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) fail "Unknown option: $argument" ;;
    esac
done

if [[ -f VERSION ]]; then
    PREVIOUS="$(tr -d '[:space:]' < VERSION)"
    [[ "$PREVIOUS" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || fail "VERSION is not x.y.z: $PREVIOUS"
    MAJOR="${BASH_REMATCH[1]}"; MINOR="${BASH_REMATCH[2]}"; PATCH="${BASH_REMATCH[3]}"
    case "$BUMP" in
        major) VERSION="$((MAJOR + 1)).0.0" ;;
        minor) VERSION="$MAJOR.$((MINOR + 1)).0" ;;
        patch) VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
    esac
else
    VERSION="1.0.0"
fi
BUILD_NUMBER="$(git rev-list --count HEAD)"
DMG="$DIST/$APP_NAME-$VERSION.dmg"

# MARK: Preflight

step "JottaFS $VERSION (build $BUILD_NUMBER)"
for tool in xcodebuild codesign hdiutil xcrun osascript iconutil tiffutil swiftc; do
    command -v "$tool" >/dev/null || fail "$tool is required."
done
[[ -z "$(git status --porcelain)" ]] || printf '\033[33mwarning:\033[0m the working tree has uncommitted changes.\n'
[[ ! -e "$DMG" ]] || fail "$DMG already exists."

# Developer ID signing of the app happens in the export, with a local
# certificate or Xcode's cloud-managed Developer ID certificate (an Admin with
# that access). Only signing the DMG needs a local certificate.
IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "($TEAM_ID)" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
if [[ "${SKIP_NOTARIZE:-0}" != 1 ]]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || fail "No notarization credentials in the keychain profile \"$NOTARY_PROFILE\". Run:
    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <your Apple ID> --team-id $TEAM_ID
(or run with SKIP_NOTARIZE=1 to test the build without notarizing)."
fi

# Universal binary only when the app can run on Intel Macs: macOS 26 is the
# last macOS for Intel, so a deployment target of 27 or later is arm64 only.
DEPLOYMENT_TARGET="$(xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ MACOSX_DEPLOYMENT_TARGET = / { print $2; exit }')"
if [[ "${DEPLOYMENT_TARGET%%.*}" -lt 27 ]]; then
    ARCHS="arm64 x86_64"
else
    ARCHS="arm64"
fi
echo "Deployment target macOS $DEPLOYMENT_TARGET → architectures: $ARCHS"

rm -rf "$BUILD"
mkdir -p "$BUILD" "$DIST"

# MARK: Archive

step "Archiving (Release)"
xcodebuild archive \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$BUILD/$APP_NAME.xcarchive" \
    -allowProvisioningUpdates \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    ARCHS="$ARCHS" \
    ONLY_ACTIVE_ARCH=NO \
    | grep -E "error:|warning: .*(signing|provision)|ARCHIVE (SUCCEEDED|FAILED)" || true
[[ -d "$BUILD/$APP_NAME.xcarchive/Products/Applications/$APP_NAME.app" ]] || fail "The archive failed (run the xcodebuild command above without the filter for details)."

# MARK: Export with Developer ID

step "Exporting with Developer ID signing"
cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive \
    -archivePath "$BUILD/$APP_NAME.xcarchive" \
    -exportOptionsPlist "$BUILD/ExportOptions.plist" \
    -exportPath "$BUILD/export" \
    -allowProvisioningUpdates \
    | grep -E "error:|EXPORT (SUCCEEDED|FAILED)" || true
APP="$BUILD/export/$APP_NAME.app"
[[ -d "$APP" ]] || fail "The export failed. Developer ID signing (a local certificate, or cloud-managed Developer ID access in Xcode) is required."

step "Checking the signature"
codesign --verify --deep --strict --verbose=1 "$APP"
codesign -d --verbose=2 "$APP" 2>&1 | grep -E "Authority=Developer ID Application|flags=.*runtime" \
    || fail "The app is not signed with Developer ID and the hardened runtime."
lipo -archs "$APP/Contents/MacOS/$APP_NAME"

# MARK: Notarize the app

notarize() {
    local file="$1"
    if [[ "${SKIP_NOTARIZE:-0}" == 1 ]]; then
        printf '\033[33mwarning:\033[0m SKIP_NOTARIZE=1: %s is not notarized.\n' "$(basename "$file")"
        return
    fi
    local log="$BUILD/notary-$(basename "$file").log"
    xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$log"
    grep -q "status: Accepted" "$log" || fail "Notarization of $(basename "$file") was not accepted (see: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE)."
}

step "Notarizing the app"
ditto -c -k --keepParent "$APP" "$BUILD/$APP_NAME.zip"
notarize "$BUILD/$APP_NAME.zip"
if [[ "${SKIP_NOTARIZE:-0}" != 1 ]]; then
    xcrun stapler staple "$APP"
fi

# MARK: DMG

step "Making the DMG"
STAGE="$BUILD/dmg"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
swiftc -O Tools/make-dmg-background.swift -o "$BUILD/make-dmg-background"
"$BUILD/make-dmg-background" "$BUILD/background.png" 1
"$BUILD/make-dmg-background" "$BUILD/background@2x.png" 2
tiffutil -cathidpicheck "$BUILD/background.png" "$BUILD/background@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null
cp Resources/JottaFS.icns "$STAGE/.VolumeIcon.icns"

VOLUME_NAME="$APP_NAME $VERSION"
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLUME_NAME" -fs HFS+ -format UDRW -size "${SIZE_MB}m" "$BUILD/rw.dmg"
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$BUILD/rw.dmg" | awk -F'\t' '/\/Volumes\// { print $NF; exit }')"
[[ -d "$MOUNT" ]] || fail "Could not mount the temporary DMG."

# The custom volume icon, and the installer window layout (written by Finder
# into the DMG's .DS_Store). Icon positions match Tools/make-dmg-background.swift.
SetFile -a C "$MOUNT" 2>/dev/null || xcrun SetFile -a C "$MOUNT" 2>/dev/null || true
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 548}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "$APP_NAME.app" of container window to {165, 190}
        set position of item "Applications" of container window to {495, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
sync
hdiutil detach -quiet "$MOUNT" || { sleep 2; hdiutil detach -force -quiet "$MOUNT"; }
hdiutil convert -quiet "$BUILD/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"

step "Signing and notarizing the DMG"
if [[ -n "$IDENTITY" ]]; then
    codesign --sign "$IDENTITY" --timestamp "$DMG"
else
    # A cloud-managed certificate cannot sign files outside Xcode. The app
    # inside is Developer ID signed, and the notarized, stapled DMG is what
    # Gatekeeper checks.
    echo "No local Developer ID certificate: the DMG is not signed (the app in it is)."
fi
notarize "$DMG"
if [[ "${SKIP_NOTARIZE:-0}" != 1 ]]; then
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

# MARK: Changelog

step "Writing the changelog"
LAST_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
CHANGELOG="$DIST/$APP_NAME-$VERSION-CHANGELOG.md"
NOTES="docs/release-notes/$VERSION.md"
if [[ -f "$NOTES" ]]; then
    # Hand-written release notes take precedence over the commit list.
    cp "$NOTES" "$CHANGELOG"
else
{
    echo "## JottaFS $VERSION"
    echo
    if [[ -n "$LAST_TAG" ]]; then
        echo "Changes since $LAST_TAG:"
        RANGE="$LAST_TAG..HEAD"
    else
        echo "First release."
        RANGE="HEAD"
    fi
    echo
    git log --no-merges --reverse --format='- %s (%h)' $RANGE
    echo
    echo "### Install"
    echo
    echo "1. Open \`$APP_NAME-$VERSION.dmg\` and drag JottaFS to Applications."
    echo "2. Open JottaFS and follow the steps in the app."
    echo
    echo "Requires macOS $DEPLOYMENT_TARGET or later ($ARCHS)."
} > "$CHANGELOG"
fi

echo "$VERSION" > VERSION

step "Done"
echo "DMG:       $DMG"
echo "Changelog: $CHANGELOG"
echo "Version:   $VERSION (VERSION updated; commit it with the release)"
echo
echo "Test the DMG, then publish with: scripts/publish-release.sh"
