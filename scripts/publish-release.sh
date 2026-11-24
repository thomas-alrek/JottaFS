#!/bin/bash
# Publishes the release that scripts/build-release.sh built last:
#   1. commits VERSION ("Release <version>"),
#   2. tags the commit v<version> and pushes the branch and the tag,
#   3. creates a GitHub release with the changelog and the DMG attached.
#
#   scripts/publish-release.sh            # asks for confirmation
#   scripts/publish-release.sh --yes      # no confirmation
#
# Run it only after testing the DMG. Requires the GitHub CLI (gh), signed in.

set -euo pipefail

APP_NAME="JottaFS"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

ASSUME_YES=0
for argument in "$@"; do
    case "$argument" in
        --yes|-y) ASSUME_YES=1 ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *) fail "Unknown option: $argument" ;;
    esac
done

command -v gh >/dev/null || fail "The GitHub CLI (gh) is required."
gh auth status >/dev/null 2>&1 || fail "Sign in to GitHub first: gh auth login"
[[ -f VERSION ]] || fail "No VERSION file: build a release first (scripts/build-release.sh)."

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
DMG="dist/$APP_NAME-$VERSION.dmg"
CHANGELOG="dist/$APP_NAME-$VERSION-CHANGELOG.md"

[[ -f "$DMG" ]] || fail "$DMG does not exist."
[[ -f "$CHANGELOG" ]] || fail "$CHANGELOG does not exist."
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "The tag $TAG already exists."
[[ -z "$(git status --porcelain | grep -vE ' (VERSION|Casks/jottafs\.rb)$' || true)" ]] \
    || fail "The working tree has changes other than VERSION. Commit or stash them first."
xcrun stapler validate "$DMG" >/dev/null 2>&1 \
    || printf '\033[33mwarning:\033[0m %s has no notarization ticket.\n' "$DMG"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo "Release:   $APP_NAME $VERSION"
echo "Tag:       $TAG on $BRANCH ($(git rev-parse --short HEAD))"
echo "DMG:       $DMG"
echo
cat "$CHANGELOG"
echo
if [[ "$ASSUME_YES" != 1 ]]; then
    read -r -p "Commit VERSION and the Homebrew cask, tag $TAG, push and create the GitHub release? [y/N] " answer
    [[ "$answer" == [yY] ]] || { echo "Cancelled."; exit 1; }
fi

# The Homebrew cask (Casks/jottafs.rb) points at this release's DMG.
CASK="Casks/jottafs.rb"
if [[ -f "$CASK" ]]; then
    SHA="$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
    sed -i '' -E "s/^  version \"[^\"]*\"/  version \"$VERSION\"/; s/^  sha256 \"[0-9a-f]*\"/  sha256 \"$SHA\"/" "$CASK"
    grep -q "version \"$VERSION\"" "$CASK" && grep -q "sha256 \"$SHA\"" "$CASK" \
        || fail "Could not update $CASK."
fi

if [[ -n "$(git status --porcelain VERSION "$CASK")" ]]; then
    git add VERSION "$CASK"
    git commit -q -m "Release $VERSION"
fi
git tag -a "$TAG" -m "$APP_NAME $VERSION"
git push origin "$BRANCH"
git push origin "$TAG"
gh release create "$TAG" "$DMG" \
    --title "$APP_NAME $VERSION" \
    --notes-file "$CHANGELOG" \
    --verify-tag

echo "Published $APP_NAME $VERSION: $(gh release view "$TAG" --json url --jq .url)"
