# JottaFS Handover

Updated 2026-11-24.

## Goal

Mount a Jottacloud account as a native FSKit volume that is visible in Finder
and usable from the CLI. File reads must use bounded HTTP range requests so
callers can seek without downloading each whole file first. Write support is a
later stretch goal; mutations remain disabled until separately designed and
tested.

## Current state

- The project is a Swift macOS host app plus an FSKit extension. The extension
  exposes discovered devices and mountpoints read-only under
  `/<device>/<mountpoint>/`.
- The host app stores OAuth credentials as a private property list in the
  `group.no.alrek.jottafs` app-group container. Do not print, commit, or
  pass credentials through source, logs, command-line arguments, or fixtures.
- The renamed app (`no.alrek.jottafs`) mounts and reads correctly from the CLI
  (verified 2026-11-24 at `/Volumes/Jottacloud`, see below). The volume name is
  now `JottaFSStorage.volumeName = "JottaCloud"`; verified mounting at
  `/Volumes/JottaCloud` with byte-identical reads.
- Finder visibility is still unresolved: the mount has no `nobrowse` option
  and Foundation reports it as mounted/browsable, but Finder has omitted it.
- Unmount: `fskitd` mounts the volume as root (`statfs.f_owner == 0`), so a
  user-level `umount`/`unmount(2)` fails with EPERM, and the old Finder `eject`
  AppleScript failed. `sudo umount` works. DiskArbitration *does* track the
  volume, as a network volume with no BSD device (`DAVolumeNetwork = 1`,
  `DAVolumeKind = jottacloud`, mount flags lack `MNT_LOCAL`), which is why
  `diskutil` cannot find it. `DADiskUnmount` from an unsandboxed user process
  unmounted it without a password. `FileManager.unmountVolume` from the
  sandboxed app failed with Foundation error 769 after logging that its
  `com.apple.unmountassistant.process.start` notification was blocked by the
  sandbox. `DADiskUnmount` from the sandboxed app itself is refused with
  `0xf8da0009` (`kDAReturnNotPermitted`); there is no entitlement for it.
  The app therefore stays sandboxed and delegates to an embedded, unsandboxed
  XPC service, `JottaFSUnmountService` (`no.alrek.jottafs.unmount`, sources in
  `UnmountService/`, shared protocol in `Shared/`). The service takes no path
  argument: it looks up the `jottacloud` mount from `jottafs://mount` itself and
  calls `DADiskUnmount`, and it only accepts connections from
  `no.alrek.jottafs` signed by its own team. Unsandboxed XPC services are fine
  for Developer ID distribution but not the Mac App Store. The app then checks
  the mount table. DiskArbitration authorizes the unmount via authd's
  `system.volume.network.unmount` right (`is-root`, `is-admin`, `on-console`,
  or `authenticate-admin-30`). In its default new security session the service
  failed with "session owner -3 invalid" and then -60007 (interaction not
  allowed), so its `Info.plist` sets `XPCService.JoinExistingSession = true`.
  Verified 2026-11-24: mount and unmount from the app both work end to end.
- Finder visibility: Finder hides the volume everywhere, even inside
  `/Volumes`, although Foundation reports it browsable and not hidden and
  Finder's `CFVolumeObserver` sees the DiskArbitration disk. DiskArbitration
  classifies it as a network volume; `ShowMountedServersOnDesktop` is already
  `1`, so that preference is not the cause. The volume declared
  `doesNotSupportVolumeSizes = true`, so `df` showed 0 blocks and Foundation
  reported nil capacities. It now reports sizes from the account's
  `<capacity>`/`<usage>` (`JottacloudStorage.volumeSizes`, never zero).
  Verified that `df` then shows a size (3.2 TiB), but Finder still hid it.
- Next finding: `getattrlist(2)` failed with EINVAL for `ATTR_CMN_CRTIME`,
  `CHGTIME`, `ACCTIME`, `BKUPTIME` on files, and also `MODTIME` on the root and
  virtual device/mountpoint folders, because only `modifyTime` was set and only
  when the listing had one. `attributes(for:)` now sets all six times, falling
  back to the mount time. Verified: the volume now appears on the Desktop and
  under Go → Computer; it is still missing from the sidebar (check Finder →
  Settings → Sidebar → Connected servers, since it is a non-local volume).
- Volume icon: macOS only honours `.VolumeIcon.icns` at the root together with
  `kHasCustomIcon` (0x0400) in the root's `com.apple.FinderInfo`. The icon was
  served as `@JottaVolume.icns` without FinderInfo. It is now
  `.VolumeIcon.icns`, and the volume implements `FSVolume.XattrHandler` in
  "limited" mode, exposing only the root's FinderInfo. Verified: the custom
  icon shows. The icon file is now omitted from directory enumeration but
  still resolved by `lookupItem`; verified that Finder still shows the icon and
  `ls -a` no longer lists it.
- Sidebar: Finder logs "Unexpected volume format: jottacloud" and then probes
  NetFS, i.e. treats the non-local volume as a server volume; with no server or
  remount URL it gets no Locations entry. FSKit's only mount option is
  read-only, so the volume cannot ask to be local. Open, deferred (lower
  priority): dragging the volume into Favorites works meanwhile. Untried idea:
  mount from an `FSPathURLResource` (not near the credentials directory) and
  see whether the volume becomes local. Supporting evidence: Xcode's CoreDevice
  DeviceFS FSKit volume is mounted from a `file://` path and is flagged
  `local` (it is also `nobrowse`).
- Format shows as "Unknown (jottacloud)". Open, deferred. Classic lookup is
  `/Library/Filesystems/<f_fstypename>.fs` → `FSPersonalities` entry whose
  `FSSubType` matches `f_fssubtype` → `FSName` (as macFUSE does). Adding
  `FSSubType = 0` to the extension's own `FSPersonalities` (plus
  `fileSystemSubType = 0`) was tested 2026-11-24: `f_fssubtype` is 0, but
  Foundation and Finder still report "Unknown (jottacloud)", so FSKit
  extension personalities are not consulted for the format name. Both settings
  are kept, since they are harmless and match a future bundle. Remaining
  option: a `jottacloud.fs` bundle in `/Library/Filesystems` with an
  `FSPersonalities` entry (`FSName`, `FSSubType = 0`), which needs an admin
  install.
  Still EINVAL
  (probably fine, unsupported by design): `ATTR_CMN_EXTENDED_SECURITY`/`UUID`/
  `GRPUUID`, `ATTR_DIR_ENTRYCOUNT`, `ATTR_VOL_OBJCOUNT`/`FILECOUNT`/`DIRCOUNT`/
  `MAXOBJCOUNT`/`QUOTA_SIZE`/`RESERVED_SIZE`.
- `RemoteAPI.swift` still has the privacy-limited diagnostic log line in
  `readRange` (HTTP status and response headers only, subsystem
  `no.alrek.jottafs.extension`, category `JFSRead`).

## Fixed 2026-11-24

### Mount error "RPC prog. not avail"

`fskitd` returned `EPROGUNAVAIL` (errno 74) because the host app mounts
`jottafs://mount`, while the extension declared only the old `jottacloudfs`
scheme in `FSSupportedSchemes`. The system log showed "Extension doesn't support
given resource scheme". `FSKitExtension/Info.plist` now declares `jottafs`.

### Zero/garbage file reads

`index.html`/`styles.css` read as all zeros. The extension log showed a single
request answered with `status=416 content-type=text/xml`: the kernel asked for
more bytes than the file holds and `readRange` sent a range ending past EOF.
Jottacloud answers that with 416 rather than a truncated 206; the client
treated 416 as EOF and returned 0 bytes, so the kernel zero-filled the known
file size. `readRange` now takes the listed `fileSize`, clamps the range to it,
and skips the request entirely at/after EOF (`JottacloudClient.byteRange`,
covered in `jottafs-checks`). The earlier `18 18 18 ff` prefix was most likely
the same short read exposing uninitialised buffer contents.

Verified on a fresh mount:
- `bergenhardstyle2025/src/index.html` is byte-identical to the user's copy
  (`~/Downloads/_index.html`); `styles.css`, the PNG icon and the JPEG decode
  correctly; a mid-file `dd` read returns the right text.
- `hard-alliance/public/cover-generator/artwork.png` (11.5 MB, 3000×3000) read
  in full has valid CRCs on every chunk and decompresses to the exact expected
  size; 64-byte seek reads at offsets 123, 1048570 (across the 1 MiB request
  boundary) and 2000003 match the full read.

## Debugging notes

- Inspect logs with `/usr/bin/log`; the user's shell profile defines a `log`
  function that shadows it. Example:
  `/usr/bin/log stream --style compact --info --predicate 'process == "JottaFSKitExtension"'`.
- After rebuilding, the mounted volume keeps the old extension process. Unmount
  (with no shell inside the volume), make sure no `JottaFSKitExtension`
  process remains, `pluginkit -a <appex>` the new build, then mount from the
  app. Re-registering a rebuilt extension can leave it disabled; the mount then
  fails with "Operation not permitted" and `fskitd` logs "Attempt to start
  disabled extension". `pluginkit -e use` and the `+` in `pluginkit -m` do NOT
  control this; FSKit has its own enablement. Re-enable JottaFS in System
  Settings → General → Login Items & Extensions → File System Extensions
  (turn it off and on if it already shows as on). If JottaFS is missing from
  that list after a rebuild, quit System Settings completely (⌘Q) and reopen
  it; a long-running System Settings shows a stale list. A shell cannot mount; `FSClient.mountSingleVolume` needs the host app's
  `com.apple.developer.fskit.mount` entitlement.

## Direct API probe

`Scripts/jottafs-read-probe.swift` targets one device, mountpoint, and file,
samples non-zero offsets, and reconstructs the file with 256-byte range reads.
It never prints credentials. The plain command-line process cannot read the
app-group credentials file; do not bypass that with `sudo`, permission changes,
or copied credentials. Now that reads work through the mount, the probe is
optional.

## Signing and installation

- `project.pbxproj` uses `DEVELOPMENT_TEAM = PLY3DSPA3F` for all targets, and
  the working DerivedData build is signed with that team's Apple Development
  certificate. Earlier notes said to switch to the Apriil team (`VH5235J98K`),
  which still has no Xcode account or profiles; decide which team to keep
  before distributing.
- Bundle IDs: `no.alrek.jottafs`, `no.alrek.jottafs.extension`,
  `no.alrek.jottafs.core`. App group: `group.no.alrek.jottafs`. Credentials
  from the old `group.com.jottacloudfs.mac` group are not migrated.
- The app runs from Xcode's DerivedData. The old `com.jottacloudfs.mac`
  extension is still registered from `~/Applications/JottacloudFS.app`
  (disabled in System Settings, same `jottacloud` short name). A backup exists
  at `~/Applications/JottacloudFS.previous-20261124`. Removing the old app
  from `~/Applications` would remove the stale registration.

## Verification run 2026-11-24

- `swift build --target JottaFSKitExtension` — passed.
- `swift run jottafs-checks` — passed (includes the new range-clamp check).
- `xcodebuild -project JottaFS.xcodeproj -scheme JottaFS -configuration Debug
  -sdk macosx build` (signed) — passed; mounted and read as above.

## Remaining work, in order

1. Finder visibility. The generic URL-backed FSKit resource is not recognized
   by `diskutil`; comparison with block-device-based FSKit projects is
   suggestive, not proof of the cause.
2. Verify the volume icon still shows with `.VolumeIcon.icns` unlisted.
3. Decide whether to keep or remove the `JFSRead` diagnostic log line.
4. Settle the signing team and a single installed app path; remove the stale
   `JottacloudFS.app` registration.
5. Only after read-only mounting is reliable, design and review write behavior
   (upload, overwrite, metadata, atomicity, conflicts, and failure recovery)
   before enabling any mutations.
