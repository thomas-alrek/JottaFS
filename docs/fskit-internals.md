# FSKit and macOS implementation notes

How JottaFS is built on Apple FSKit and the macOS services around it, and what
was learned doing it. For the Jottacloud side see
[the API notes](jottacloud-api-internals.md); for writes and the Trash see
[the write design](write-support-design.md) and
[the Trash design](trash-design.md). FSKit is Apple's user-space file system
API; it needs no macFUSE kernel extension and no reduced Startup Security.

## Components

| Component | Bundle ID | Role |
|---|---|---|
| `JottaFS.app` (`HostApp/`) | `no.alrek.jottafs` | Sign-in, location list, mount and unmount, Settings. Sandboxed. |
| `JottaFSKitExtension` (`Sources/JottaFSKitExtension/`, `FSKitExtension/`) | `no.alrek.jottafs.extension` | The FSKit file system. One process per mounted location. Sandboxed. |
| `JottaFSCore` (`Sources/JottaFSCore/`) | `no.alrek.jottafs.core` | Framework: Jottacloud client, storage (credentials, settings, mount anchors), shared types. |
| `JottaFSUnmountService` (`UnmountService/`) | `no.alrek.jottafs.unmount` | Unsandboxed XPC service: unmounts through DiskArbitration and installs updates. |
| `JottaFSProgressAgent` (`ProgressAgent/`) | `no.alrek.jottafs.progress` | Sandboxed launch agent that publishes upload progress for Finder. |
| `JottaFSFinderSync` (`FinderExtension/`) | `no.alrek.jottafs.findersync` | Finder Sync extension: Copy Jottacloud Link / Stop Sharing. |
| Login agent (`HostApp/no.alrek.jottafs.login.plist`) | `no.alrek.jottafs.login` | Starts the app at login with `--mount-at-login`. |

All targets use team `PLY3DSPA3F` and the app group `group.no.alrek.jottafs`.
Releases are signed with Developer ID ([releasing](releasing.md)); the
unsandboxed XPC service and the temporary sandbox exceptions are fine for
Developer ID, not for the Mac App Store.

## Extension model

FSKit is available from macOS 15.4. JottaFS uses the result-based
`FSVolume.Handler` API introduced in macOS 27, so its minimum is macOS 27
(Apple silicon only).

The extension is an `FSUnaryFileSystem`: one resource becomes one volume.
Its `Info.plist` declares the `com.apple.fskit.fsmodule` extension point,
`FSShortName` `jottacloud` and `FSSupportsPathURLs`; its entitlements include
`com.apple.developer.fskit.fsmodule`. The user enables it once in **System
Settings → General → Login Items & Extensions → File System Extensions**; the
app reads the state with `FSClient.shared.installedExtensions` and polls it
every 2 s while it is off (FSKit sends no notification).

## Mounting

`mount -t` expects a legacy `/Library/Filesystems/<name>.fs` bundle; JottaFS
does not ship one. The app calls
`FSClient.mountSingleVolume(resource:bundleID:options:)`, which needs the
app's `com.apple.developer.fskit.mount` entitlement and mounts under
`/Volumes`.

- **Mount anchors.** The resource is a location's *mount anchor*, the empty
  directory `<app group>/JottaCloudMount/<anchor name>`, passed as an
  `FSPathURLResource`. The anchor name is 32 hex characters of the SHA-256 of
  the lower-cased `device/mountpoint`; the anchor holds only `Location.plist`
  with the location's device and mountpoint. One anchor per location lets
  several locations be mounted at once, each with its own FSKit container
  identifier and its own staging and Trash folders. Before 1.0.1 the volume
  was mounted from `JottaCloudMount` itself with the location in the
  credentials; such a *legacy* mount (anchor name `""`) is still recognised
  and can be unmounted.
- **Local, not server.** A path resource makes the mount `MNT_LOCAL`. A
  generic URL resource (`jottafs://mount`, used early on) mounted as a
  non-local volume that Finder treated as a server volume and left out of the
  sidebar.
- **Mismatch.** If the resource kind or URL scheme does not match what the
  extension declares, `fskitd` rejects the mount with `EPROGUNAVAIL` ("RPC
  prog. not avail") before the extension starts.
- **Mount point.** Code that needs a volume's path reads it from the mount
  table (`JottaFSStorage.mountedVolumes()`, `mountPoint(anchorName:)`;
  `getmntinfo` with `MNT_NOWAIT`, which does not call into the volume).
- **Names.** The volume is named after the location or the name set in
  Advanced (`Settings.plist`, `VolumeNames`). If a mounted volume already has
  the name, the extension uses "Name (2)", "Name (3)"… (not saved).

## Unmounting

`fskitd` mounts as root, so `unmount(2)` from the user fails with `EPERM`;
DiskArbitration refuses sandboxed callers (`kDAReturnNotPermitted`) and
`FileManager.unmountVolume` fails in the sandbox. The app asks
`JottaFSUnmountService` (protocol in `Shared/`) to call `DADiskUnmount`. The
service takes an anchor name, never a path, finds that anchor's
`jottacloud` mount itself, and accepts only `no.alrek.jottafs` signed by its
own team. It sets `XPCService.JoinExistingSession` so authd can grant the
volume-unmount right in the user's login session. Unmounting waits for
pending and running uploads.

## Volume

- The root of each volume is its Jottacloud location (`MountTarget` in
  `FSItems.swift`): a location on the built-in `Jotta` device (Archive, Sync,
  Shared, Photos…) or one backed-up folder of a computer backup.
- **Finder needs every time attribute** (modify, change, access, birth, added,
  backup) on the root: `getattrlist(2)` fails with `EINVAL` for any time FSKit
  cannot supply, and Finder then hides the volume. Items use the mount time
  where Jottacloud has no date. Other `getattrlist` attributes still return
  `EINVAL` without visible harm (`ATTR_CMN_EXTENDED_SECURITY`/`UUID`/`GRPUUID`,
  `ATTR_DIR_ENTRYCOUNT`, `ATTR_VOL_OBJCOUNT`/`FILECOUNT`/`DIRCOUNT`/
  `MAXOBJCOUNT`/`QUOTA_SIZE`/`RESERVED_SIZE`).
- **Size.** The volume must report a non-zero size (Finder omits volumes with
  `f_blocks == 0`); for an unlimited quota it reports a nominal 1 TiB free,
  because the kernel refuses writes on a volume with no free space. It reports
  a maximum file size of 64 bits (no limit of its own).
- **Icon.** The root resolves `.VolumeIcon.icns` by name but never lists it,
  and a limited `FSVolume.XattrHandler` exposes only the root's
  `com.apple.FinderInfo` with `kHasCustomIcon`. Other extended attributes
  return `ENOTSUP`.
  Observed 2026-11-24 (macOS 27.3): Finder's **sidebar** shows the app's icon
  (`JottaFS.icns`, the cloud), not this volume icon (`JottaVolume.icns`, the
  drive with the "J"), which other places use (window title, Get Info,
  Desktop). It seems the sidebar takes the icon of the app that provides the
  FSKit file system; this is not documented. Kept as it is; worth
  researching further (for example whether the extension's own icon, or an
  icon in its `Info.plist`, would be used instead).
- **Case.** Jottacloud names are case-insensitive, so the volume is
  case-insensitive and case-preserving.
- **Concurrency.** Callbacks run concurrently. Item state is behind a lock per
  item; directory, trash, read-ahead and staging state are actors or narrowly
  locked. Directory cookies and verifiers stay stable across repeated
  enumerations.
- **Directory cache.** Listings are fresh for 15 s and served for up to 5
  minutes while refreshing in the background (Finder and Quick Look ask for
  the same folders many times per second); up to 512 folders of up to 20,000
  entries. Own changes update the cache at once (an overlay kept for 60 s).
- **Reads.** Ranged downloads with read-ahead and an on-disk block cache; see
  [the API notes](jottacloud-api-internals.md#file-reads).
- **Remote changes and the name cache.** FSKit has no public API to tell the
  kernel or Finder that a folder changed. Finder does not poll local volumes,
  so it shows changes made elsewhere only when it reads the folder again.
  The kernel also caches failed lookups: a name looked up before it existed
  keeps failing ("No such file or directory") although it is listed, until
  the volume is mounted again. Changing the folder's time through the volume
  might make Finder reread it; this was considered and not built.

## Rule: never touch the volume from inside its own extension

The extension (and the progress agent) must never call an API that accesses
a path on a JottaFS volume. `URL.appendingPathComponent` without an explicit
`isDirectory` calls `lstat`; inside `flush` during a volume `synchronize`
that lookup re-entered the volume and deadlocked the extension (a Finder
folder copy hung at "0 bytes"; only `kill -9` of the extension recovered).
Volume paths are built as strings with `isDirectory: false`.

## Credentials

The app exchanges a browser sign-in or a personal login token for OAuth
credentials and never stores the login token. It writes a binary
`credentials.plist` (mode 0600) to `Library/Application Support/JottaFS`
(mode 0700) in the app group container. The extension and the Finder
extension read it; every writer changes only its own fields under an `flock`,
and each process reads the newest saved tokens before refreshing, so no one
reuses a refresh token another process already rotated. No login token,
access token or refresh token goes into a command-line argument, a mount
resource or a log. Shared settings (volume names, cache size) are in
`Settings.plist` next to the credentials.

## Upload progress in Finder

Finder shows an `NSProgress` (`kind = .file`, `fileOperationKind =
.uploading`, `fileURL` on the volume) as a bar on the file's icon. Progress
published by the sandboxed FSKit extension appears but never advances (only
publish and unpublish reach Finder); identical updates from another process
do. So the extension sends begin/update/end over XPC to
`JottaFSProgressAgent` (`ProgressService.swift`; the extension needs a
`mach-lookup` temporary exception), which publishes them. `SMAppService`
refuses unsandboxed agents for a sandboxed app, so the agent is sandboxed
with a `mach-register` exception and started on demand by launchd. It accepts
only the extension signed by its own team and publishes only for paths on a
mounted volume. Without the agent the extension publishes locally (a bar that
completes at the end).

Finder's copy dialog counts the bytes written, not the upload: Jottacloud
needs the complete MD5 before an upload starts. close(2) waits for the upload,
so the dialog pauses near the end and finishes only when the file is on
Jottacloud (a background upload after close was tried and rejected as
misleading).

## Finder extension (share links)

`JottaFSFinderSync` watches the mount points of the JottaFS volumes
(`directoryURLs`, updated on mount and unmount) and adds **Copy Jottacloud
Link** and, for items known to be shared, **Stop Sharing Jottacloud Link**.
No menu appears outside JottaFS volumes, on a volume's root, in the Trash or
for the volume icon. Share states come from the listings of the folders
Finder shows, the extension's own actions, and one bounded lookup (0.4 s)
when the menu opens. Finder draws template images from a Finder Sync
extension black in dark mode, so the menu symbols get a fixed palette colour
for the current appearance. The user turns the extension on in **System
Settings → Login Items & Extensions → Finder**
(`FIFinderSyncController.showExtensionManagementInterface()`).

## Mount at login

The `no.alrek.jottafs.login` launch agent (`RunAtLoad`, registered with
`SMAppService.agent` while a location is set to mount at login) starts the
app with `--mount-at-login`. That argument is the only signal for a login
launch: the app then has no window and no Dock icon (`LSUIElement`; every
other launch becomes a regular app at once), waits for the network, mounts
with retries for up to 3 minutes, and quits; it opens its window only for a
mount that still fails. A login launch does nothing when the app is already
open (launchd also runs the agent when it is registered).

Findings: an app registered with `SMAppService.mainApp` (up to 1.0.4) was
started at login without a recognisable "launched as login item" event, and
macOS's "Reopen windows when logging back in" relaunched the app as a normal
launch (now prevented with `NSApp.disableRelaunchOnLogin()`). The app moves
an old `mainApp` registration to the agent.

## Deferred: the format name

Get Info shows the format as "Unknown (jottacloud)". Foundation and Finder
look up `/Library/Filesystems/<f_fstypename>.fs` → the `FSPersonalities`
entry whose `FSSubType` matches `f_fssubtype` → `FSName` (as macFUSE does).
An `FSSubType` in the FSKit extension's own personality is not consulted.
The remaining option is a `jottacloud.fs` bundle with `FSName = Jottacloud`
and `FSSubType = 0`, which needs an admin install.

## Volume renaming (not supported)

Renaming a mounted volume in Finder is not supported (decided 2026-11-24);
use Advanced in the app. Findings for a later attempt (macOS 27.3):

- Finder renames through DiskArbitration (`DADiskRename`): it sets the label
  (`setattrlist(ATTR_VOL_NAME)`, which reaches
  `FSVolume.RenameHandler.setVolumeName`) and then moves the mount point to
  `/Volumes/<new name>`. Its record of a volume without a BSD device does not
  follow the move: the volume leaves Finder's sidebar about a second later,
  and unmounting through DiskArbitration fails until a reboot.
- Mounting outside `/Volumes` (`mount -F -t jottacloud <anchor> <dir>`,
  which needs `FSActivateOptionSyntax` and mounts as the user) avoids the
  move, but Finder then does not show the volume in its sidebar.
- Untested idea: back the volume with a small attached disk image so it has
  a BSD device.

## Development workflow

- Checks: `swift build --target JottaFSKitExtension` and
  `swift run jottafs-checks`. These do not build or sign the app; use
  `JottaFS.xcodeproj` (or `make release` for a signed, notarized build).
- A shell cannot mount: mounting needs the app's
  `com.apple.developer.fskit.mount` entitlement.
- After changing the extension: unmount, check no `JottaFSKitExtension`
  process remains, install the new app, then mount again. A rebuilt extension
  can come up disabled (`fskitd`: "Attempt to start disabled extension");
  quit System Settings (⌘Q), reopen File System Extensions and turn JottaFS
  off and on. Each extension rebuild registers a new module, and the pane's
  list comes from the per-user `fskit_agent` (SIP-protected; no CLI), which
  only shows it after it restarts; sometimes only a reboot helps.
- **ExtensionKit error 2** on mount (`com.apple.extensionKit.errorDomain 2`)
  means several copies of the app are registered (old builds, `build/`,
  DerivedData). Delete the extra copies (`make release` removes
  `build/release` for this reason), then turn the extension off and on.
- Logs: use `/usr/bin/log`; in zsh, `log` is a shell built-in that shadows
  it. JottaFS logs under the subsystems `no.alrek.jottafs` (app; category
  `Login` for launches and mount at login), `no.alrek.jottafs.extension` and
  `no.alrek.jottafs.findersync`. Info messages are not kept; use `--info`
  only for live streams.

## Apple references

- [FSKit overview](https://developer.apple.com/documentation/fskit)
- [Building a passthrough file system](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system)
- [FSUnaryFileSystem](https://developer.apple.com/documentation/fskit/fsunaryfilesystem)
- [FSVolume.Handler](https://developer.apple.com/documentation/fskit/fsvolume/handler)
- [FSVolume.ReadWriteHandler](https://developer.apple.com/documentation/fskit/fsvolume/readwritehandler)
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [FIFinderSync](https://developer.apple.com/documentation/findersync/fifindersync)
