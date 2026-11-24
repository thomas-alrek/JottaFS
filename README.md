# JottaFS

A native Swift filesystem project for browsing Jottacloud on macOS. It exposes
all account devices and mountpoints under one mounted root. The volume is
read-only except for one write-scope folder, `Jotta/Archive/JottaFS-Test`
(see [the write-support design](docs/write-support-design.md)).

## Status

The Swift API client, SwiftUI setup and mount app, and FSKit volume source are
present. The Swift package builds and its API smoke checks pass. A signed
Xcode build is currently blocked because the Apriil developer account is not
configured in Xcode and no matching provisioning profiles are installed. A
previous single-location mount worked; the new all-locations tree still needs
runtime validation.

FSKit avoids the macFUSE kernel extension and Recovery security changes, but
macOS requires the signed, installed, and enabled filesystem extension.

## Requirements and scope

- macOS 27 or later (the current handler APIs used here were introduced in
  macOS 27).
- Swift 6.1+ and the macOS 27 SDK for local builds; full Xcode is required for
  packaging, signing, registering, and testing the FSKit extension.
- Browsing, metadata, and ranged downloads everywhere.
- Create, write, rename, and delete (to the Jottacloud trash) only inside
  `Jotta/Archive/JottaFS-Test`; files are staged locally and uploaded on
  close.
- OAuth login-token exchange and serialized rotating refresh-token persistence.
- One mount contains every discovered device and mountpoint, organized as
  `/<device>/<mountpoint>/...`.
- No writes, uploads, delete, rename, symbolic links, or white-label services.

Jottacloud does not publish a complete API reference. The implementation uses
observations documented by [rclone](https://rclone.org/jottacloud/) and its
[Jottacloud backend](https://github.com/rclone/rclone/tree/master/backend).
See [the preserved API research](docs/jottacloud-api-internals.md) and
[FSKit implementation notes](docs/fskit-internals.md).

## Build and local checks

```sh
swift build --target JottaFSKitExtension
swift run jottafs-checks
```

The app manages login and mounting. Open `JottaFS.xcodeproj`, select the
`JottaFS` scheme, then build and run the app. Credentials are stored
automatically as a binary `credentials.plist` in the app group's
`Library/Application Support/JottaFS` directory. The directory and file
are private to the app and its FSKit extension. If saved credentials exist, the
app loads them automatically at startup. Otherwise, enter a Jottacloud personal
login token and choose **Connect**. The token is exchanged for OAuth credentials
and is not saved. Credentials in the previous app group are not migrated; sign
in again in JottaFS. The previous credentials remain untouched.

Run only one copy of JottaFS at a time, from a consistent path. FSKit
registers the extension against its containing app; running copies from both
`~/Applications` and Xcode's DerivedData can make `launchd` reject the
extension with ExtensionKit error 2. If that happens, quit both copies,
relaunch only the intended copy, and enable its extension in System Settings.

Click **Open Extension Settings** and make sure JottaFS is enabled. Select
**Mount Jottacloud**. FSKit
mounts the account under `/Volumes`, with each device and mountpoint represented
as a folder, and the app displays the resulting path. The root resolves a
read-only `.VolumeIcon.icns` by name (it is not listed, even by `ls -a`), and
the root's `com.apple.FinderInfo` sets the custom-icon flag so Finder uses it. The app detects an
existing mount on launch and when reactivated; it offers **Unmount Jottacloud**
instead of **Mount Jottacloud** while mounted. Use **Show in Finder** to reveal
the mounted volume in Finder; this uses Finder automation, so allow JottaFS to
control Finder when macOS prompts or in **System Settings → Privacy & Security
→ Automation**. Unmounting is non-forced and goes through the embedded
`JottaFSUnmountService` (DiskArbitration); close open files or Finder windows
on the volume if macOS reports it is busy.

The volume is mounted as a local volume, so Finder lists it in the sidebar
under **Locations** (with **Finder → Settings → Sidebar → Locations** enabled
for disks).

The host app requires the `com.apple.developer.fskit.mount` entitlement. Both
targets require the `group.no.alrek.jottafs` app group for credentials access
and the network-client entitlement. The extension also requires
`com.apple.developer.fskit.fsmodule`. Matching development profiles must grant
the app group to both targets before the app can be signed and enabled. Enable
the extension in System Settings if prompted.
The host app, extension, and core framework bundle IDs are
`no.alrek.jottafs`, `no.alrek.jottafs.extension`, and
`no.alrek.jottafs.core`, respectively.

The app and extension share credentials through the app group. The FSKit mount
resource is an empty, non-secret `JottaCloudMount` directory in the app-group
container, passed as an `FSPathURLResource`; it is separate from the
credentials directory and holds no data.

Do not use `mount -t jottacloud`: that command expects a legacy
`/Library/Filesystems/jottacloud.fs` helper, which this project does not
provide. The supported flow uses `FSClient.mountSingleVolume`. The all-location
tree and account reads need runtime verification. Share any error shown by the
app rather than changing Startup Security settings.

## Project guidance

- [Agent instructions](AGENTS.md)
- [Jottacloud API internals](docs/jottacloud-api-internals.md)
- [FSKit internals](docs/fskit-internals.md)
- [Project development skill](.agents/skills/jottafs/SKILL.md)
