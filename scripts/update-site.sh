#!/usr/bin/env bash
# Points the website's download links (site/index.html) at a released DMG:
#
#   https://github.com/thomas-alrek/JottaFS/releases/download/v<version>/JottaFS-<version>.dmg
#
# Usage: scripts/update-site.sh <version>
#
# scripts/publish-release.sh runs it and commits the page with the release.
set -euo pipefail

cd "$(dirname "$0")/.."
PAGE="site/index.html"

fail() {
    printf '\033[31merror:\033[0m %s\n' "$*" >&2
    exit 1
}

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Usage: $0 <version>"
[[ -f "$PAGE" ]] || fail "$PAGE does not exist."

BASE="https://github.com/thomas-alrek/JottaFS/releases/download"
PATTERN="$BASE/v[0-9]+\.[0-9]+\.[0-9]+/JottaFS-[0-9]+\.[0-9]+\.[0-9]+\.dmg"
URL="$BASE/v$VERSION/JottaFS-$VERSION.dmg"

grep -qE "$PATTERN" "$PAGE" || fail "$PAGE has no DMG download link."
sed -i '' -E "s#$PATTERN#$URL#g" "$PAGE"
if grep -oE "$BASE/[^\"]+" "$PAGE" | grep -vqxF "$URL"; then
    fail "$PAGE still has a download link that is not $URL."
fi
echo "Updated the download links in $PAGE to $VERSION."
