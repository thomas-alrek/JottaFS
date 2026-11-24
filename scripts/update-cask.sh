#!/usr/bin/env bash
# Updates the Homebrew casks for a released version (the repository is its
# own tap; see docs/releasing.md):
#
#   Casks/jottafs.rb           the latest release (version and DMG checksum)
#   Casks/jottafs@<version>.rb  a pinned cask for this version, so it can
#                               still be installed after newer releases
#
# Usage:
#   scripts/update-cask.sh <version> <sha256>           latest and pinned
#   scripts/update-cask.sh --pinned <version> <sha256>  pinned only (older versions)
#
# The pinned cask is made from Casks/jottafs.rb, so change that file to
# change all of them; existing pinned casks are not rewritten.
set -euo pipefail

cd "$(dirname "$0")/.."
CASK="Casks/jottafs.rb"

fail() {
    printf '\033[31merror:\033[0m %s\n' "$*" >&2
    exit 1
}

PINNED_ONLY=0
if [[ "${1:-}" == "--pinned" ]]; then
    PINNED_ONLY=1
    shift
fi
VERSION="${1:-}"
SHA="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Usage: $0 [--pinned] <version> <sha256>"
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || fail "The checksum must be 64 lower-case hexadecimal characters."
[[ -f "$CASK" ]] || fail "$CASK does not exist."

# Sets the version and checksum lines of a cask file.
set_release() {
    sed -i '' -E "s/^  version \"[^\"]*\"/  version \"$VERSION\"/; s/^  sha256 \"[0-9a-f]*\"/  sha256 \"$SHA\"/" "$1"
    grep -q "^  version \"$VERSION\"" "$1" && grep -q "^  sha256 \"$SHA\"" "$1" \
        || fail "Could not set the version and checksum in $1."
}

if [[ "$PINNED_ONLY" != 1 ]]; then
    set_release "$CASK"
    echo "Updated $CASK to $VERSION."
fi

PINNED="Casks/jottafs@$VERSION.rb"
if [[ -f "$PINNED" ]]; then
    echo "$PINNED exists; not changed."
    exit 0
fi
# From the latest cask: another name, no update checks (the version is
# fixed), and it cannot be installed next to the latest cask (same app).
perl -0pe '
    s/^cask "jottafs" do/cask "jottafs\@'"$VERSION"'" do/m;
    s/  livecheck do\n.*?\n  end\n/  livecheck do\n    skip "This cask installs one fixed version."\n  end\n/s;
    s/(  depends_on arch: )/  conflicts_with cask: "jottafs"\n$1/;
' "$CASK" > "$PINNED"
set_release "$PINNED"
grep -q '^cask "jottafs@' "$PINNED" && grep -q 'conflicts_with cask: "jottafs"' "$PINNED" \
    || fail "Could not make $PINNED."
echo "Created $PINNED."
