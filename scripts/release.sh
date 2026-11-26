#!/bin/bash
# Builds, notarizes and publishes the next JottaFS release in one command:
#
#   scripts/release.sh            # next patch version (1.0.3 → 1.0.4)
#   scripts/release.sh --minor    # 1.0.4 → 1.1.0
#   scripts/release.sh --major    # 1.4.2 → 2.0.0
#   scripts/release.sh --version  # only print the next version
#
# Before running: commit everything, and write and commit
# docs/release-notes/<next version>.md (the release's changelog).
#
# Steps:
#   1. checks the working tree is clean, the release notes exist and the
#      tag is free; runs the checks and regression tests (`make check`) and
#      requires a passed live probe (`make probe`) of a <next version> test
#      build made from the same sources;
#   2. scripts/build-release.sh: archive, Developer ID export, provisioning
#      check, notarize and staple the app and the DMG, Gatekeeper check;
#   3. removes build/release (extra app copies confuse ExtensionKit);
#   4. scripts/publish-release.sh --yes: updates the Homebrew casks
#      (Casks/jottafs.rb and Casks/jottafs@<version>.rb), commits them with
#      VERSION, tags v<version>, pushes the branch and the tag, and creates
#      the GitHub release with the DMG and the notes;
#   5. checks the published release and the casks.
#
# It stops at the first problem. Nothing is tagged or pushed if the build
# fails.

set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
    printf '\033[31merror:\033[0m %s\n' "$*" >&2
    exit 1
}
step() {
    printf '\n\033[1m==> %s\033[0m\n' "$*"
}

BUMP="--patch"
PRINT_ONLY=0
for argument in "$@"; do
    case "$argument" in
        --patch|--minor|--major) BUMP="$argument" ;;
        --version) PRINT_ONLY=1 ;;
        *) fail "Unknown option: $argument" ;;
    esac
done

# The next version, calculated like scripts/build-release.sh.
PREVIOUS="$(tr -d '[:space:]' < VERSION 2>/dev/null || true)"
if [[ -z "$PREVIOUS" ]]; then
    NEXT="1.0.0"
else
    [[ "$PREVIOUS" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || fail "VERSION is not x.y.z: $PREVIOUS"
    MAJOR="${BASH_REMATCH[1]}" MINOR="${BASH_REMATCH[2]}" PATCH="${BASH_REMATCH[3]}"
    case "$BUMP" in
        --major) NEXT="$((MAJOR + 1)).0.0" ;;
        --minor) NEXT="$MAJOR.$((MINOR + 1)).0" ;;
        *) NEXT="$MAJOR.$MINOR.$((PATCH + 1))" ;;
    esac
fi
if [[ "$PRINT_ONLY" == 1 ]]; then
    echo "$NEXT"
    exit 0
fi

NOTES="docs/release-notes/$NEXT.md"
step "Releasing JottaFS $NEXT"
[[ -z "$(git status --porcelain)" ]] || fail "The working tree has changes. Commit them first."
[[ -f "$NOTES" ]] || fail "$NOTES does not exist. Write the release notes and commit them first."
git ls-files --error-unmatch "$NOTES" >/dev/null 2>&1 || fail "$NOTES is not committed."
! git rev-parse -q --verify "refs/tags/v$NEXT" >/dev/null || fail "The tag v$NEXT already exists."
gh auth status >/dev/null 2>&1 || fail "Sign in to GitHub first: gh auth login"
[[ ! -e "dist/JottaFS-$NEXT.dmg" ]] || fail "dist/JottaFS-$NEXT.dmg already exists. Delete it to build again."

# Regression tests guard bugs that were fixed once. A failure means one is
# back: nothing is published until it is fixed, the checks pass again, and
# a new build has been installed and probed (docs/releasing.md, "Tests").
step "Running the checks and regression tests"
make check || fail "A check or regression test failed. Do not publish: tell the owner, fix the bug, run make check again, rebuild, install and probe the build, and only then release."

# The live probe (scripts/probe-volume.sh) of a test build of this version,
# from the same source files (only notes and docs may have changed since;
# whether they were committed then does not matter).
PROBE="build/probe/$NEXT.passed"
[[ -f "$PROBE" ]] || fail "No passed live probe for $NEXT. Make a test build (SKIP_NOTARIZE=1 make release, then reset VERSION), install it, run make probe VOLUME=/Volumes/<volume>, and release again."
[[ "$(sed -n 's/^sources=//p' "$PROBE")" == "$(scripts/source-hash.sh)" ]] \
    || fail "The sources changed since the probe of $NEXT. Build, install and probe again."

step "Building and notarizing"
scripts/build-release.sh "$BUMP"
rm -rf build/release
[[ "$(tr -d '[:space:]' < VERSION)" == "$NEXT" ]] || fail "The build did not produce $NEXT."

step "Publishing"
scripts/publish-release.sh --yes

step "Checking the release"
DMG="dist/JottaFS-$NEXT.dmg"
SHA="$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
ASSET="$(gh release view "v$NEXT" --json assets --jq ".assets[] | select(.name == \"JottaFS-$NEXT.dmg\") | .digest")"
[[ "$ASSET" == "sha256:$SHA" ]] || fail "The release asset's checksum ($ASSET) is not the DMG's ($SHA)."
LATEST="$(gh api repos/thomas-alrek/JottaFS/releases/latest --jq .tag_name)"
[[ "$LATEST" == "v$NEXT" ]] || fail "The latest release on GitHub is $LATEST, not v$NEXT."
grep -q "^  sha256 \"$SHA\"" Casks/jottafs.rb || fail "Casks/jottafs.rb does not have the DMG's checksum."
grep -q "^  sha256 \"$SHA\"" "Casks/jottafs@$NEXT.rb" || fail "Casks/jottafs@$NEXT.rb does not have the DMG's checksum."
if command -v brew >/dev/null; then
    # HOMEBREW_DEVELOPER only for this command, so developer mode stays off.
    HOMEBREW_DEVELOPER=1 HOMEBREW_NO_AUTO_UPDATE=1 brew style Casks/*.rb >/dev/null 2>&1 \
        || printf '\033[33mwarning:\033[0m brew style reports problems in Casks/ (run: HOMEBREW_DEVELOPER=1 brew style Casks/*.rb).\n'
fi
[[ -z "$(git status --porcelain)" ]] || printf '\033[33mwarning:\033[0m the working tree is not clean after publishing.\n'

echo
echo "Released JottaFS $NEXT: $(gh release view "v$NEXT" --json url --jq .url)"
