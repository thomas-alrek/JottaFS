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
| `JottaFSService` (`JottaFSService/`) | `no.alrek.jottafs.service` | Unsandboxed XPC service for what the sandboxed app cannot do: unmounting through DiskArbitration and installing updates. Optional (see below). |
| `JottaFSProgressAgent` (`ProgressAgent/`) | `no.alrek.jottafs.progress` | Sandboxed launch agent that publishes upload progress for Finder. |
| `JottaFSFinderSync` (`FinderExtension/`) | `no.alrek.jottafs.findersync` | Finder Sync extension: Copy Jottacloud Link / Stop Sharing. |
| Login agent (`HostApp/no.alrek.jottafs.login.plist`) | `no.alrek.jottafs.login` | Starts the app at login with `--mount-at-login`. |
| Refresh agent (`HostApp/no.alrek.jottafs.refresh.plist`) | `no.alrek.jottafs.refresh` | Starts the app hidden every 12 hours with `--refresh-session` to keep the sign-in alive. |

All targets use team `PLY3DSPA3F` and the app group `group.no.alrek.jottafs`.
Releases are signed with Developer ID ([releasing](releasing.md)); the
unsandboxed XPC service and the temporary sandbox exceptions are fine for
Developer ID, not for the Mac App Store.

## Extension model

FSKit is available from macOS 15.4, but JottaFS needs macOS 27 (and so
Apple silicon only). Checked 2026-11-24 by building for macOS 26.0:

- **Mounting.** `FSClient.mountSingleVolume(resource:bundleID:options:)`,
  which the app uses to mount a location, exists only from macOS 27 (FSKit
  "V3"). On macOS 26 a path-backed FSKit volume can only be mounted with
  `mount -F -t jottacloud …`, which mounts outside `/Volumes`, where Finder
  does not show it in the sidebar (see "Volume renaming" below). There is no
  clean way for the app to mount on 26.
- **The callback API.** Every callback of the extension uses the
  result-based `FSVolume.Handler` API of macOS 27 (`FSContext`,
  `FSLookupItemResult`, `FSReadFileResult`, `FSWriteFileResult` and the other
  `…Result` types); building for 26.0 fails with about 90 errors, all in the
  extension. macOS 26 has only the older completion-handler callbacks, so
  supporting it would mean a second implementation of the whole callback
  layer.
- **Smaller items.** `FSClient.openFileSystemExtensionsSettings()` needs 27,
  and `FSVolume.MountOptions` needs 26.4.

FSKit versions: V1 is macOS 15.4, V2 is 26.0, V2.4 is 26.4 and V3 is 27.0
(`FSKitDefines.h`). Revisit if Apple makes the mount API available on an
earlier system; the app's own code (SwiftUI, AppKit, ServiceManagement,
Finder Sync) was not checked for 26 because the build stopped at the
extension.

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
  Advanced (`Settings.plist`, `VolumeNames`). For the built-in `Jotta`
  locations (Archive, Sync, Shared, Photos) the extension uses the translated
  names that the app saves in `Settings.plist` (`BuiltInLocationNames`, such
  as "Arkiv" in Norwegian), so the disk has the name the app's list shows.
  If a mounted volume already has the name, the extension uses "Name (2)",
  "Name (3)"… (not saved).

## Unmounting

`fskitd` mounts as root, so `unmount(2)` from the user fails with `EPERM`;
DiskArbitration refuses sandboxed callers (`kDAReturnNotPermitted`) and
`FileManager.unmountVolume` fails in the sandbox. The app asks
`JottaFSService` (protocol in `Shared/`) to call `DADiskUnmount`. The
service takes an anchor name, never a path, finds that anchor's
`jottacloud` mount itself, and accepts only `no.alrek.jottafs` signed by its
own team. It sets `XPCService.JoinExistingSession` so authd can grant the
volume-unmount right in the user's login session. Unmounting waits for
pending and running uploads.

### Fully sandboxed build

`JottaFSService` is the only unsandboxed part, and it is included by default
(releases are distributed outside the Mac App Store, with Developer ID).
Building with
`JOTTAFS_SANDBOXED=YES` (`make sandboxed`) leaves it out of the app (a
build phase deletes `JottaFSService.xpc` before signing), and the app adapts
at runtime (`JottaFSService.isAvailable`): it does not check for updates, a
mounted location shows a disabled Mount button (the user ejects in Finder),
and Sign Out asks the user to eject the disks first. The upload-progress
agent and the extension still use temporary `mach-lookup`/`mach-register`
sandbox exceptions, so such a build is sandboxed throughout but not yet
App Store-clean; without the agent, a file's progress bar would only complete
at the end of its upload. Delete the build afterwards: extra copies of the app
make mounts fail with ExtensionKit error 2.

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
- **Markers.** The root also holds two read-only, hidden, virtual items that
  are never uploaded, and their names are reserved (a remote item with the
  same name is hidden):
  - `.com.apple.timemachine.donotpresent` (empty file): Time Machine does not
    ask whether to use the disk for backups when it is mounted (what the
    marker is for). It does **not** remove the disk from the list in Time
    Machine's settings: on macOS 27 the settings still list every mounted
    JottaFS disk (checked 2026-11-25 with the marker present; no code in
    the shared cache refers to the marker's name). Choosing one fails: a local
    backup disk needs a device (DiskManagement error -69471, "A BSD disk name
    could not be obtained"), and confirming the erase Time Machine then
    offers fails too, without changing the files. Network backups need an
    SMB share with Time Machine support. The only known way to hide a
    volume from that list is the `nobrowse` mount option, which also hides
    it from Finder.
  - `.fseventsd/no_log`: `fseventsd` keeps no event log on the disk. Without
    it, `fseventsd` created `.fseventsd` and its log files at every mount and
    JottaFS uploaded them (seen 2026-11-25). Live change notifications do not
    depend on the log.
  Spotlight already reports indexing as disabled for JottaFS disks (`mdutil
  -s`), so there is no `.metadata_never_index`.
- **Sidebar icon.** Finder's sidebar does not use the volume icon. For an
  FSKit volume it shows the SF Symbol named in the **app's** `Info.plist` at
  `CFBundleIcons` → `CFBundlePrimaryIcon` → `CFBundleSymbolName`, the
  mechanism Apple documents for File Provider extensions ("Setting the Finder
  sidebar icon"). Without that key it shows the app's own icon (on macOS 27.3
  drawn as the `.icns` inside a frame with a grey edge). The key changes only
  the sidebar: the Dock, the Applications folder and the volume's own icon
  stay the same. Tested 2026-11-25 on macOS 27.3 with only the installed
  copy of the app registered, after relaunching Finder:
  - the nested key with a test symbol in the app's `Info.plist`: the sidebar
    showed that symbol;
  - the nested key naming a custom symbol in the app's asset catalog:
    the sidebar showed it, after Finder was relaunched (Finder keeps the previous icon until then);
  - the same key in the FSKit extension's `Info.plist`: ignored;
  - a top-level `CFBundleSymbolName` (app or extension): ignored;
  - a bundle icon for the extension (`CFBundleIconFile`): ignored.

  JottaFS uses the system symbol `internaldrive`, the plain drive that
  Macintosh HD has in the sidebar. JottaFS 1.0.7 used a custom
  symbol from the app's asset catalog (that outline with the Jottacloud logo
  on its top face); it was replaced with the plain drive in 1.1.0. A custom
  symbol works the same way: put a `.symbolset` in the app's asset catalog
  and name it in the key. AppKit draws system symbols as images, so a custom
  symbol's outline cannot be taken from a PDF rendering; the SF Symbols app's
  `SFSymbolsFallback.otf` has the outlines as font glyphs (such as
  `drive.color`).

  The volume itself reports `JottaVolume.icns` (`NSWorkspace.icon(forFile:)`,
  `NSURLEffectiveIconKey`), and DiskArbitration has no media icon for it
  (only `DAVolumeKind` `jottacloud`). Testing tip: a stale copy of the app
  (Xcode's DerivedData, a mounted DMG) can serve the mount instead of the
  installed one and spoil such tests; check the running extension's path
  (`pgrep -lf JottaFSKitExtension`) and that only one copy is registered
  (`pluginkit -mAvvv -i no.alrek.jottafs.extension`).
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

- **Permissions.** Jottacloud keeps no Unix permissions. Files in the
  location report 0755, like FAT and exFAT disks, so apps, scripts and
  tools on the disk run (`JottaFSVolume.permissions`); before 1.2.1 they
  reported 0644, and launchd refused to start an app on the disk
  (`access(…/Contents/MacOS/<name>, X_OK)`: EACCES). Modes set with
  chmod are accepted and not kept. Finder's own files kept on this Mac
  (`.DS_Store`, `._*`) stay 0644.
- **Rename flags.** FSKit fails `renamex_np(2)` with flags (`RENAME_EXCL`,
  `RENAME_SWAP`) with `ENOTSUP` before the extension sees it, and the volume
  reports no exclusive or swap renaming. Apple's own FSKit msdos module
  does the same, so apps cope (Safari's downloads do).
- **Creation dates.** Apps can depend on a creation date they set being
  read back: Safari's download helper marks `name.download` bundles that
  way and calls a bundle with another date invalid ("Refusing to move files
  out of an invalid download bundle", seen in its log as "Refusing to
  update the fraction completed an invalid download bundle"). JottaFS keeps
  set creation dates in memory (`CreationDates`;
  [write design](write-support-design.md)).
- **Volume owner.** `fskitd` mounts the volume, so `statfs` reports root
  as its owner (`f_owner` 0, no "mounted by" in `mount`); Apple's FAT disks
  mounted by DiskArbitration report the user. Safari's check of the
  download location is about the folder's owner, which JottaFS reports as
  the user, so this does not matter for downloads.

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
resource or a log. Shared settings (volume names, translated built-in names,
cache size) are in `Settings.plist` next to the credentials, and a
`SessionEnded` marker appears there when the sign-in has ended (see "Ended
sign-ins and the refresh agent").

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

## Ended sign-ins and the refresh agent

Jottacloud's refresh token is an offline token without a fixed lifetime, but
it ends when it is unused for longer than the server's idle limit or when the
user removes the session on jottacloud.com
([API notes](jottacloud-api-internals.md#authentication)).

- **Detection.** A refresh that the identity server refuses (400/401), also
  after retrying with the newest saved tokens, throws
  `JottacloudError.sessionEnded`. The client's `sessionEnded` callback
  (`JottaFSStorage.markSessionEnded()`) writes a `SessionEnded` marker next to
  the credentials and posts the Darwin notification
  `no.alrek.jottafs.session-ended`. The app, the FSKit extension and the
  Finder extension all pass that callback, so whichever finds it first tells
  the app. The extension returns `EACCES` for the failed operation.
- **App.** On the notification, at launch and when it becomes active, the app
  checks the marker: it unmounts every location, deletes the credentials
  (which removes the marker), signs out and shows "Your Jottacloud sign-in has
  ended" with its window in front. The locations for mount at login are kept.
  A new sign-in also clears the marker.
- **Refresh agent.** `no.alrek.jottafs.refresh` (`StartInterval` 12 hours,
  registered with `SMAppService.agent` while signed in, removed at sign-out)
  starts the app with `--refresh-session`: hidden like a login launch, it
  calls `JottacloudClient.refreshSession()` (a forced refresh) and quits. If
  the sign-in has ended it signs out and shows the window. The progress agent
  cannot do this: it has no network access and does not link JottaFSCore.
  Test by hand: `launchctl kickstart -k gui/$(id -u)/no.alrek.jottafs.refresh`.
- **Session name and sign-out.** After every sign-in and at each launch the
  app calls `AuthService.RegisterSession`, so jottacloud.com lists the session
  as the Mac's computer name and "JottaFS". Sign-out calls the OpenID Connect
  logout with the refresh token before it deletes the credentials, so the
  session leaves that list.

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

## Private FSKit interfaces (checked 2026-11-25)

Looking for a way to upload a copied file without a full local copy, all
FSKit classes and protocols in the macOS 27 shared cache were listed through
the Objective-C runtime (115 classes, 49 protocols), with the SDK's
`FSKit.tbd` and the strings of `fskitd`, `fskit_agent` and `fskit_helper`.
Nothing exposes the source of a copy, an MD5, or a way to make the writer
send the data again:

- `FSContext` has a private `_auditToken` (`FSAuditToken`: `pid`, `ruid`,
  `euid`, `audit_token`; exported in the `.tbd`, not in the headers), so the
  writer's process could be known. It would only help for copy tools in the
  user session (an unsandboxed helper could find the source file the tool has
  open); Finder copies run in `DesktopServicesHelper` as root, whose open
  files a user process cannot see. Not used: private, and no help for Finder.
- A private `FSVolumeCloneHandler` (`createCloneOfItem:named:inDirectory:…`)
  clones within one volume only; a copy from APFS onto JottaFS is a
  cross-volume copy that falls back to reading and writing.
- Kernel-offloaded I/O and extents are for block-device resources; the data
  would still be stored locally.
- Copy tools set the size and extended attributes before the data, but none
  carries a source path or a checksum. The size is used for the early
  free-space check ([write design](write-support-design.md)).

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

- Checks: `make check` (Xcode project check, extension build,
  `jottafs-checks`, `swift test`). These do not build or sign the app; use
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
