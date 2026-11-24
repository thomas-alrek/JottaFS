# JottaFS Handover

Updated 2026-11-24.

## Goal

Mount a Jottacloud account as a native FSKit volume that is visible in Finder
and usable from the CLI. File reads use bounded HTTP range requests so callers
can seek without downloading whole files. Write support is a later stretch
goal; mutations stay disabled until separately designed and tested.

## Current state

Working and verified on macOS 27.3 (2026-11-24):

- The sandboxed host app (`no.alrek.jottafs`) mounts the account read-only at
  `/Volumes/JottaCloud`, exposing devices and mountpoints as
  `/<device>/<mountpoint>/`, and unmounts it again.
- Reads are correct: small files are byte-identical to known copies, an
  11.5 MB PNG reads with valid chunk CRCs, and seek reads (including across
  the 1 MiB request boundary) match a full read.
- Finder shows the volume on the Desktop, under Go → Computer and in the
  sidebar, with the custom volume icon and a size from the account's
  capacity/usage.
- OAuth credentials live as a private property list in the
  `group.no.alrek.jottafs` app-group container. Do not print, commit, or pass
  credentials through source, logs, command-line arguments, or fixtures.

Known cosmetic gap: Get Info shows the format as "Unknown (jottacloud)". This
is deferred, low priority (see below).

Write support works from the shell inside the write scope; Finder and
TextEdit checks remain (see "Write support" below).

## Write support (built and shell-tested 2026-11-24)

Design and decisions: [docs/write-support-design.md](docs/write-support-design.md).
The account holds the owner's personal data, so writes are confined to
`Jotta/Archive/JottaFS-Test` (`JottaFSWriteScope`); outside it every mutation
fails with `EPERM` before any request and items report no write bits. Deletes
go to the Jottacloud trash only. Files are staged in the extension's Caches
container (`StagingArea`) and uploaded on close/sync through
`files/v1/allocate` + `upload_url`, then verified by size and MD5. `.DS_Store`
and `._*` are refused; the volume is case-insensitive, case-preserving.

First live round (2026-11-24): the scope guard held (creating in
`Jotta/Archive` → EPERM, in `Jotta/Sync` → EACCES, moving a folder out of the
scope → EPERM); `mkdir` and folder rename (`mkDir`, `mvDir`) worked. Uploads
failed: `files/v1/allocate` answered 202, then the client gave up before
sending data (most likely the `upload_url` host was not on `jottacloud.com`;
`jotta.cloud` is now trusted too, and failures are logged with a safe cause).
`rmdir` of an empty folder failed with ENOTEMPTY because the listing parser
treated the listed folder's own root `<folder>` element as a child; fixed.
Left in the scope from that round: empty folders `sub-b`, `sub-c`, and an
incomplete `hello.txt` allocation.

Second live round (2026-11-24, after the fixes): all passed from the shell,
only inside the scope. Small, zero-byte and 12 MB uploads (each verified by
Jottacloud's size and MD5; 12 MB took 1.3 s), append, overwrite, truncate,
file rename, case-only rename, moving a file into a subfolder, folder rename,
file delete and `rmdir` (to trash), and refusal of `.DS_Store`/`._*`. After
the 60 s overlay expired the server listing matched, `big.bin` read back
byte-identical, no upload failures were logged, and read-only listings of
`Jotta` and `Jotta/Archive` (excluding `JottaFS-Test`) were unchanged from
before the tests. Still to check by hand: TextEdit save, Finder copy-in,
rename and delete, and that deleted items appear in the Jottacloud trash on
the website.

Live test plan (only inside the scope; compare a read-only listing of
`Jotta/Archive` and `Jotta` before and after): `mkdir` the scope folder;
create/write/read back/append a small file; zero-byte file; overwrite;
truncate; >10 MB file with byte-for-byte read-back; rename file and folder;
delete and check the Jottacloud trash; TextEdit save; Finder copy-in, rename
and delete; and confirm writes outside the scope fail.

## How it fits together

- **Mount resource.** The app mounts an `FSPathURLResource` for the empty
  `<group>/JottaCloudMount` directory (`JottaFSStorage.mountAnchorDirectoryURL`),
  deliberately separate from the credentials directory. The extension declares
  `FSSupportsPathURLs` only and accepts exactly that directory. A path resource
  makes the mount `local`; the earlier generic `jottafs://mount` resource was
  non-local, so Finder treated it as a server volume without a server and left
  it out of the sidebar. A mismatch between the resource kind/scheme and the
  extension's declaration makes `fskitd` fail with `EPROGUNAVAIL`
  ("RPC prog. not avail").
- **Reads.** `readRange` clamps each request to the listed file size and sends
  no request at or after EOF: Jottacloud answers 416 (not a truncated 206) for
  a range that extends past the end, which previously made reads zero-filled.
- **Attributes Finder needs.** Every item sets all six times (falling back to
  the mount time for virtual items); `getattrlist(2)` fails with EINVAL for any
  time FSKit cannot supply, and Finder then hides the volume. The volume
  reports a non-zero size (`JottacloudStorage.volumeSizes`).
- **Icon.** The root resolves `.VolumeIcon.icns` by name but never lists it,
  and a limited `FSVolume.XattrHandler` exposes only the root's
  `com.apple.FinderInfo` with `kHasCustomIcon`.
- **Unmount.** `fskitd` mounts as root, so `unmount(2)` from the user fails
  with EPERM; DiskArbitration refuses sandboxed callers
  (`kDAReturnNotPermitted`), and `FileManager.unmountVolume` fails under the
  sandbox. The app therefore asks the embedded, unsandboxed XPC service
  `JottaFSUnmountService` (`no.alrek.jottafs.unmount`, `UnmountService/`,
  protocol in `Shared/`) to call `DADiskUnmount`. The service takes no path: it
  finds the `jottacloud` mount from the anchor directory itself, and only
  accepts `no.alrek.jottafs` signed by its own team. It sets
  `XPCService.JoinExistingSession` so authd can grant the volume-unmount right
  (`is-admin`/`on-console`) in the user's login session. Unsandboxed XPC
  services are fine for Developer ID distribution, not the Mac App Store.

## Deferred

- **Format name.** Foundation and Finder look up
  `/Library/Filesystems/<f_fstypename>.fs` → `FSPersonalities` entry whose
  `FSSubType` matches `f_fssubtype` → `FSName` (as macFUSE does). An
  `FSSubType` in the FSKit extension's own personality was tested and is not
  consulted, so it was removed again. The remaining option is a
  `jottacloud.fs` bundle with `FSName = Jottacloud`, `FSSubType = 0` (the
  volume's default subtype), which needs an admin install.
- Still EINVAL from `getattrlist(2)`, apparently harmless:
  `ATTR_CMN_EXTENDED_SECURITY`/`UUID`/`GRPUUID`, `ATTR_DIR_ENTRYCOUNT`,
  `ATTR_VOL_OBJCOUNT`/`FILECOUNT`/`DIRCOUNT`/`MAXOBJCOUNT`/`QUOTA_SIZE`/
  `RESERVED_SIZE`.

## Development workflow

- Checks: `swift build --target JottaFSKitExtension` and
  `swift run jottafs-checks`. The signed app:
  `xcodebuild -project JottaFS.xcodeproj -scheme JottaFS -configuration Debug -sdk macosx build`.
- A shell cannot mount; `FSClient.mountSingleVolume` needs the host app's
  `com.apple.developer.fskit.mount` entitlement. Mount and unmount from the app.
- After rebuilding the extension: unmount, make sure no `JottaFSKitExtension`
  process remains, `pluginkit -a <appex>`, then quit System Settings (⌘Q),
  reopen File System Extensions and turn JottaFS off and on. A rebuilt
  extension can come up disabled ("Operation not permitted"; `fskitd` logs
  "Attempt to start disabled extension"); `pluginkit -e use` and the `+` in
  `pluginkit -m` do not control FSKit's enablement. A long-running System
  Settings shows a stale list, so JottaFS can appear to be missing.
- If JottaFS is still missing from File System Extensions after quitting
  System Settings: each extension rebuild re-registers it as a new module
  (`fskit_agent` logs "Removed 1 identifiers / Added 1 identifiers"), and the
  pane's list comes from the per-user `fskit_agent`, which only offers the new
  module after it restarts. The agent is SIP-protected (`launchctl kickstart`
  fails with "Operation not permitted while System Integrity Protection is
  engaged"; `killall` has no effect) and there is no CLI for FSKit
  enablement. Logging out and back in was tried and is not enough; only a
  full reboot refreshes the list. Rebuilds that do not touch the extension's
  sources may avoid this, but that has not been checked, so batch extension
  changes between test rounds.
- Inspect logs with `/usr/bin/log`; the user's shell profile defines a `log`
  function that shadows it.

## Signing and installation

- `project.pbxproj` uses `DEVELOPMENT_TEAM = PLY3DSPA3F` for all targets, and
  the working build is signed with that team's Apple Development certificate.
  Earlier notes proposed the Apriil team (`VH5235J98K`), which has no Xcode
  account or profiles; decide which team to keep before distributing.
- Bundle IDs: `no.alrek.jottafs`, `no.alrek.jottafs.extension`,
  `no.alrek.jottafs.core`, `no.alrek.jottafs.unmount`. App group:
  `group.no.alrek.jottafs`. Credentials from the old
  `group.com.jottacloudfs.mac` group are not migrated.
- The app currently runs from Xcode's DerivedData. Old `JottacloudFS` copies
  were moved to the Trash on 2026-11-24; the backup
  `~/Applications/JottacloudFS.previous-20261124` remains.

## Remaining work, in order

1. Finish the live write checks by hand: TextEdit save, Finder copy-in,
   rename and delete, and the Jottacloud trash on the website.
2. Settle the signing team and a single installed app path (outside
   DerivedData).
3. Optional: the `jottacloud.fs` format-name bundle (see Deferred).
