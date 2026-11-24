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

## Experiments in progress (built, not yet verified)

- **Upload progress in Finder.** Findings: an `NSProgress` (`kind = .file`,
  `fileOperationKind = .uploading`, `fileURL` on the volume) published by the
  sandboxed extension shows a bar, but its updates never reach Finder (74
  byte updates arrived during a 147 MB upload; the bar jumped 0 → 100). The
  same updates from an unsandboxed process advance the bar both in
  `~/Downloads` and on the JottaCloud volume, with or without a run loop on
  the updating thread, from sandboxed processes with or without access to
  the file, and while the file is still being closed during an upload. So
  the block is specific to the FSKit extension process. `SMAppService`
  refuses unsandboxed agents for a sandboxed app ("target executable must be
  sandboxed because the app is sandboxed"), so the agent is sandboxed with a
  `mach-register` temporary exception for its service name. Built (not yet
  verified): `JottaFSProgressAgent`, a sandboxed launch agent (`ProgressAgent/`,
  `Contents/Helpers`, plist in `Contents/Library/LaunchAgents`, registered
  by the app with `SMAppService.agent`, started on demand by launchd via the
  Mach service `no.alrek.jottafs.progress`). The extension sends
  begin/update/end over XPC (`ProgressService.swift`; needs the
  `mach-lookup` temporary exception, Developer ID only) and falls back to a
  local publish if the agent is unavailable. Further findings: the agent
  receives and applies every update (logged), yet Finder's bar stays at 0;
  the same agent binary run from the shell (`--selftest`, temporary) moves
  the bar on a closed file. Every bar that moved belonged to a file that was
  already closed; every stuck bar was published while the writer was still
  in close(2) waiting for the upload. Uploads therefore run in the
  background after close returns; verified 2026-11-24 that the icon bar then
  follows the upload (e.g. 776 MB in 43 s, 301 updates via the agent).
  The owner found that misleading (Finder's copy and "done" sound finished
  before the upload). Investigation (official `jottad`, web app, live
  experiments; see the API notes): no upload can start before the complete
  MD5 is known, so Finder's dialog cannot follow the upload. Decision: close
  waits for the upload again and reports failures to Finder. Verified with a
  fresh 1 GiB file: the dialog counts the writes (to about 88 %), pauses
  during the 66 s upload, and finishes with the "done" sound once the file
  is confirmed on Jottacloud. Incident: switching the extension off and
  unmounting during that wait unmounted the volume mid-upload and hung
  Finder (recovered by force-stopping the extension). `unmount()` now waits
  for pending and running uploads (built, not yet verified). Not yet used:
  Jottacloud keeps interrupted uploads in 32 MiB blocks per MD5, so large
  uploads could resume after a connection drop. The agent
  accepts only
  `no.alrek.jottafs.extension` signed by its own team and only publishes
  for paths on the mounted volume. Upload phase timings and progress counts
  are logged (`Upload phases`, `Upload progress`).
- **Listing speed.** Finder and Quick Look re-request the same folders many
  times per second (about 1,480 listing requests in two minutes were logged),
  and folders over 2,048 entries were never cached, so a 2,258-entry folder
  was refetched (0.7–0.8 s) on every request. The directory cache now keeps
  up to 512 folders of up to 20,000 entries, treats listings as fresh for
  15 s, and serves older ones (up to 5 min) immediately while refreshing in
  the background.

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
