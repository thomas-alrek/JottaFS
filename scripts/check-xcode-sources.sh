#!/bin/bash
# Fails if a Swift file of the extension or JottaFSCore is missing from the
# Xcode project. SwiftPM (`swift build`, `swift test`) finds new files by
# itself, Xcode does not: a release build then fails (1.1.3 test build,
# CreationDates.swift). Run by `make check`.
set -euo pipefail
cd "$(dirname "$0")/.."
missing=0
for file in Sources/JottaFSKitExtension/*.swift Sources/JottaFSCore/*.swift; do
    name="$(basename "$file")"
    if ! grep -q "/\* $name in Sources \*/" JottaFS.xcodeproj/project.pbxproj; then
        echo "error: $file is not in a target of JottaFS.xcodeproj (add it in Xcode)." >&2
        missing=1
    fi
done
exit "$missing"
