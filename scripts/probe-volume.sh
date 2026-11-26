#!/bin/bash
# Live write probe for a mounted JottaFS volume: checks, through the real
# extension and Jottacloud, the write bugs that have regression tests
# (Tests/JottaFSKitExtensionTests). Run it with the build to be released
# installed and a location mounted, before publishing (docs/releasing.md):
#
#   scripts/probe-volume.sh /Volumes/Arkiv          # Jotta/Archive (Norwegian: "Arkiv")
#   scripts/probe-volume.sh /Volumes/Arkiv --keep   # leave the test files
#
# Everything happens in a new folder with a unique name under
# <volume>/JottaFS-Test (created if missing). Nothing else on the volume is
# touched, and the run folder is deleted at the end (permanently, like rm)
# unless --keep is given. Exit status 0 only if every check passed.
#
# Checks:
#   1. Finder-style copies (data + extended attributes, so macOS writes
#      `._name` files) while the folder is listed constantly: size and MD5
#      right after the copy, after 20 s and after 75 s (past the 60 s
#      directory overlay). Regression: 1.1.2 showed such files as 0 bytes.
#   2. A Safari-style download: `name.download` marked with a creation date
#      and tags (both must read back), `name` written inside with a
#      quarantine attribute, moved out, folder removed.
#   3. A move from this Mac's disk onto the volume (NSFileManager), as
#      Safari and other apps do with downloads.
#   4. Setting and reading back a quarantine attribute on the volume.
#   5. Running a script, a program and an app from the volume (files must
#      be executable: before 1.2.1 apps on a Jottacloud disk did not open).

set -uo pipefail

VOLUME="${1:-}"
KEEP=0
[[ "${2:-}" == "--keep" ]] && KEEP=1
if [[ -z "$VOLUME" || ! -d "$VOLUME" ]]; then
    echo "Usage: $0 /Volumes/<JottaFS volume> [--keep]" >&2
    exit 2
fi
mount | grep -q " on $VOLUME (jottacloud" || { echo "error: $VOLUME is not a mounted JottaFS volume." >&2; exit 2; }

RUN="$VOLUME/JottaFS-Test/probe-$(date +%Y%m%d-%H%M%S)-$RANDOM"
LOCAL="$(mktemp -d "${TMPDIR:-/tmp}/jottafs-probe.XXXXXX")"
FAILURES=0
LISTER=""

pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
info() { printf '     %s\n' "$*"; }

cleanup() {
    [[ -n "$LISTER" ]] && kill "$LISTER" 2>/dev/null
    rm -rf "$LOCAL"
    if [[ "$KEEP" == 0 && -d "$RUN" ]]; then
        rm -rf "$RUN" || echo "warning: could not delete $RUN"
    fi
}
trap cleanup EXIT

size_of() { stat -f %z "$1" 2>/dev/null || echo missing; }
md5_of() { md5 -q "$1" 2>/dev/null || echo unreadable; }

mkdir -p "$VOLUME/JottaFS-Test" && mkdir "$RUN" || { echo "error: could not create $RUN" >&2; exit 1; }
echo "Probe folder: $RUN"

# --- 1. Finder-style copies while the folder is listed ----------------------

echo
echo "1. Copies with extended attributes while the folder is listed"
SIZES=(1024 1048576 5242880 20971520)
for size in "${SIZES[@]}"; do
    file="$LOCAL/copy-$size.bin"
    head -c "$size" /dev/urandom > "$file"
    xattr -w com.apple.metadata:kMDItemWhereFroms "probe" "$file"
    xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");JottaFS probe;" "$file"
done

# Lists the folder (with attributes, like Finder) every 0.2 s.
( while true; do ls -la "$RUN" >/dev/null 2>&1; sleep 0.2; done ) &
LISTER=$!

for size in "${SIZES[@]}"; do
    source="$LOCAL/copy-$size.bin"
    # cp uses copyfile(3) like Finder: data, then extended attributes.
    if ! cp "$source" "$RUN/"; then
        fail "copy of $size bytes failed"
        continue
    fi
    target="$RUN/copy-$size.bin"
    actual="$(size_of "$target")"
    if [[ "$actual" == "$size" ]]; then pass "$size bytes: size right after the copy"; else fail "$size bytes: size right after the copy is $actual"; fi
done
LAST_COPY=$(date +%s)

check_copies() {
    local label="$1"
    for size in "${SIZES[@]}"; do
        local target="$RUN/copy-$size.bin" actual
        actual="$(size_of "$target")"
        if [[ "$actual" != "$size" ]]; then
            fail "$size bytes: size $label is $actual"
            continue
        fi
        if [[ "$(md5_of "$target")" == "$(md5_of "$LOCAL/copy-$size.bin")" ]]; then
            pass "$size bytes: size and contents $label"
        else
            fail "$size bytes: contents $label differ"
        fi
    done
}

check_copies "after the copies"
sleep 20
check_copies "after 20 s"
WAIT=$((LAST_COPY + 75 - $(date +%s)))
(( WAIT > 0 )) && { info "waiting ${WAIT} s for the directory overlay to expire"; sleep "$WAIT"; }
check_copies "after 75 s"
kill "$LISTER" 2>/dev/null; LISTER=""

# --- 2. Safari-style download -------------------------------------------------

echo
echo "2. Safari-style download (name.download folder, move out, remove)"
DL="$RUN/download-test.dmg.download"
if mkdir "$DL" && head -c 3145728 /dev/urandom > "$DL/download-test.dmg"; then
    # Safari's download helper marks the bundle with a creation date and
    # tags, and refuses to move files out of a bundle whose date differs
    # ("invalid download bundle"; every Safari download failed with "Cannot
    # move file" before 1.1.3).
    MARKER=443779200   # 1984-01-24 08:00:00 UTC
    result="$(osascript -l JavaScript - "$DL" "$MARKER" <<'JXA' 2>&1
ObjC.import('Foundation')
function run(argv) {
    const error = $()
    const attributes = $.NSDictionary.dictionaryWithObjectForKey($.NSDate.dateWithTimeIntervalSince1970(Number(argv[1])), $.NSFileCreationDate)
    const ok = $.NSFileManager.defaultManager.setAttributesOfItemAtPathError(attributes, argv[0], error)
    return ok ? 'ok' : ('error ' + error.code + ' ' + ObjC.unwrap(error.localizedDescription))
}
JXA
)"
    xattr -w com.apple.metadata:_kMDItemUserTags '("Blue\n4")' "$DL" 2>/dev/null
    if [[ "$result" == "ok" && "$(stat -f %B "$DL")" == "$MARKER" ]]; then
        pass ".download folder keeps the creation date that was set"
    else
        fail ".download folder creation date: set $result, reads $(stat -f %B "$DL") instead of $MARKER"
    fi
    if [[ "$(xattr -p com.apple.metadata:_kMDItemUserTags "$DL" 2>/dev/null)" == *Blue* ]]; then
        pass ".download folder keeps its tags"
    else
        fail ".download folder lost its tags"
    fi
    xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;" "$DL/download-test.dmg" 2>/dev/null \
        || info "could not set the quarantine attribute inside the .download folder"
    expected="$(md5_of "$DL/download-test.dmg")"
    if mv "$DL/download-test.dmg" "$RUN/download-test.dmg"; then
        if [[ "$(md5_of "$RUN/download-test.dmg")" == "$expected" ]]; then pass "file moved out of the .download folder"; else fail "moved file has other contents"; fi
    else
        fail "could not move the file out of the .download folder"
    fi
    if rmdir "$DL" 2>/dev/null || rm -rf "$DL"; then pass ".download folder removed"; else fail "could not remove the .download folder"; fi
else
    fail "could not create the .download folder or write into it"
fi

# --- 3. Move from this Mac onto the volume -------------------------------------

echo
echo "3. Move from this Mac's disk onto the volume (NSFileManager)"
head -c 2097152 /dev/urandom > "$LOCAL/moved.bin"
xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;" "$LOCAL/moved.bin"
expected="$(md5_of "$LOCAL/moved.bin")"
result="$(osascript -l JavaScript - "$LOCAL/moved.bin" "$RUN/moved.bin" <<'JXA' 2>&1
ObjC.import('Foundation')
function run(argv) {
    const error = $()
    const ok = $.NSFileManager.defaultManager.moveItemAtPathToPathError(argv[0], argv[1], error)
    return ok ? 'ok' : ('error ' + error.code + ' ' + ObjC.unwrap(error.localizedDescription))
}
JXA
)"
if [[ "$result" == "ok" && "$(md5_of "$RUN/moved.bin")" == "$expected" ]]; then
    pass "moved with NSFileManager"
else
    fail "NSFileManager move: $result"
fi

# --- 4. Quarantine attribute on the volume -------------------------------------

echo
echo "4. Quarantine attribute on a file on the volume"
printf 'x' > "$RUN/quarantine.txt"
value="0083;$(printf %x "$(date +%s)");Safari;"
if xattr -w com.apple.quarantine "$value" "$RUN/quarantine.txt" 2>"$LOCAL/xattr.err"; then
    if [[ "$(xattr -p com.apple.quarantine "$RUN/quarantine.txt" 2>/dev/null)" == "$value" ]]; then
        pass "quarantine attribute set and read back"
    else
        fail "quarantine attribute set but reads back differently"
    fi
else
    fail "could not set the quarantine attribute: $(cat "$LOCAL/xattr.err")"
fi

# --- 5. Programs on the volume run ---------------------------------------------

echo
echo "5. A script, a program and an app on the volume run"
printf '#!/bin/sh\necho script-ok\n' > "$RUN/probe-script.sh"
if [[ "$("$RUN/probe-script.sh" 2>&1)" == "script-ok" ]]; then
    pass "script runs"
else
    fail "script does not run (mode $(stat -f %Sp "$RUN/probe-script.sh"))"
fi
cp /bin/echo "$RUN/probe-echo"
if [[ "$("$RUN/probe-echo" program-ok 2>&1)" == "program-ok" ]]; then
    pass "program runs"
else
    fail "program does not run (mode $(stat -f %Sp "$RUN/probe-echo"))"
fi
# A minimal app whose executable writes a marker; opened like a double-click.
APPDIR="$RUN/JottaFSProbe-$RANDOM.app"
mkdir -p "$APPDIR/Contents/MacOS"
cat > "$APPDIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>probe</string>
<key>CFBundleIdentifier</key><string>no.alrek.jottafs.probe.$RANDOM</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
printf '#!/bin/sh\ntouch "%s"\n' "$LOCAL/app-ran" > "$APPDIR/Contents/MacOS/probe"
open -W -n "$APPDIR" 2>"$LOCAL/open.err"
if [[ -f "$LOCAL/app-ran" ]]; then
    pass "app opens"
else
    fail "app does not open: $(head -c 200 "$LOCAL/open.err")"
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APPDIR" >/dev/null 2>&1

echo
if (( FAILURES == 0 )); then
    printf '\033[32mAll probe checks passed.\033[0m\n'
    # Recorded for scripts/release.sh: the installed version and the sources
    # it is assumed to be built from (a hash of the source files on disk,
    # committed or not).
    APP_VERSION="$(defaults read /Applications/JottaFS.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo unknown)"
    REPO="$(cd "$(dirname "$0")/.." && pwd)"
    mkdir -p "$REPO/build/probe"
    {
        echo "version=$APP_VERSION"
        echo "sources=$("$REPO/scripts/source-hash.sh")"
        echo "commit=$(git -C "$REPO" rev-parse HEAD)"
        echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$REPO/build/probe/$APP_VERSION.passed"
    echo "Recorded build/probe/$APP_VERSION.passed (JottaFS $APP_VERSION is installed)."
    exit 0
fi
printf '\033[31m%d probe check(s) failed.\033[0m\n' "$FAILURES"
exit 1
