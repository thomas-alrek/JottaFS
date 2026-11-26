#!/bin/bash
# Prints a hash of the app's source files as they are on disk (tracked and
# untracked, not ignored), committed or not. scripts/probe-volume.sh records
# it with a passed probe; scripts/release.sh compares it, so a release is
# built from the sources that were probed.
set -euo pipefail
cd "$(dirname "$0")/.."
git ls-files -co --exclude-standard -- Sources HostApp FinderExtension JottaFSService JottaFS.xcodeproj Package.swift \
    | LC_ALL=C sort \
    | while IFS= read -r file; do [[ -f "$file" ]] && printf '%s  %s\n' "$(shasum -a 256 < "$file" | cut -d ' ' -f 1)" "$file"; done \
    | shasum -a 256 | cut -d ' ' -f 1
