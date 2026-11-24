# FSKit implementation notes

These notes record the Apple API research that informs this driver. FSKit is
Apple's user-space file-system API and does not require the macFUSE kernel
backend or reduced Startup Security.

## Extension model

FSKit is available starting in macOS 15.4. This implementation uses the newer
`FSVolume.Handler` result-based API, introduced in macOS 27, so its minimum
target is macOS 27.

The current FSKit implementation supports `FSUnaryFileSystem`: one resource
loaded into one volume. The volume root exposes all discovered account devices
and mountpoints as `/<device>/<mountpoint>/` directories.

An FSKit implementation is packaged as a macOS app extension:

1. The extension's `Info.plist` declares the `com.apple.fskit.fsmodule`
   extension point and an `FSShortName` used by `mount -t`.
2. Its entitlements include `com.apple.developer.fskit.fsmodule`.
3. An `@main` type conforms to `UnaryFileSystemExtension` and returns a
   `FSUnaryFileSystem` subclass.
4. The file-system subclass implements `FSUnaryFileSystemOperations` to load
   and unload a resource as an `FSVolume`.
5. The volume subclass implements `FSVolume.Handler` and a read handler. It
   represents the root and children as `FSItem` subclasses.

Enable the installed extension in **System Settings → General → Login Items &
Extensions → File System Extensions**. This FSKit flow does not require
Recovery-mode kernel-extension approval.

macOS `mount -t` expects a legacy `/Library/Filesystems/<name>.fs` bundle with
a `mount_<name>` helper; this project does not ship one. The host app instead
uses `FSClient.mountSingleVolume(resource:bundleID:options:)`, which mounts
under `/Volumes` and requires the host app's
`com.apple.developer.fskit.mount` entitlement. The host app passes an empty
`<app group>/JottaCloudMount` directory as an `FSPathURLResource`, and the
extension declares `FSSupportsPathURLs` and accepts only that directory. A path
resource makes the mount local (`MNT_LOCAL`); a generic URL resource is mounted
as a non-local volume that Finder treats as a server volume and leaves out of
the sidebar. If the resource kind or URL scheme does not match what the
extension declares, `fskitd` rejects the mount with `EPROGUNAVAIL` ("RPC prog.
not avail") before the extension is launched. The extension reads credentials
from the shared app-group Application Support directory, which is deliberately
not the mount resource.

Finder also requires every time attribute (modify, change, access, birth,
added, backup) to be valid on the volume root: `getattrlist(2)` fails with
EINVAL for any time FSKit cannot supply, and Finder then hides the volume
entirely. The volume must also report a non-zero size. A custom icon needs
`.VolumeIcon.icns` at the root plus `kHasCustomIcon` in the root's
`com.apple.FinderInfo`, served through a limited `FSVolume.XattrHandler`.

## Volume callbacks and mapping

- `activateVolume` creates the root `FSItem`; `FSActivateResult` returns it.
- The mounted root lists devices; each device directory lists its mountpoints;
  each mountpoint directory serves the remote Jottacloud root. Descendant
  lookup and ranged reads retain their device/mountpoint route.
- `lookupItem(named:in:context:)` resolves a child in a parent directory and
  returns an `FSLookupItemResult` with the item, canonical name, and attributes.
- `enumerateDirectory` pages entries through `FSDirectoryEntryPacker`.
  `FSDirectoryCookie` values are opaque, and the filesystem supplies a
  nonzero verifier to indicate a directory version.
- `getAttributes` returns an `FSGetAttributesResult`. Populate a single
  `FSItem.Attributes` snapshot consistently: FSKit sequences attribute sets
  to avoid stale data superseding fresh metadata.
- `FSVolume.ReadWriteHandler.read` receives an `FSMutableFileDataBuffer` and
  returns an `FSReadFileResult` containing bytes read and refreshed attributes.
- Jottacloud's listing API doesn't always provide timestamps. Report only
  known modification times; leave unavailable dates invalid rather than
  converting missing values to the Unix epoch.
- The volume is mounted read-write, but every mutation outside
  `JottaFSWriteScope` fails with `EPERM` before any network request, and
  only in-scope items report write permission bits. Links are not supported
  (`ENOTSUP`). See [the write-support design](write-support-design.md).
- FSKit passes URL-backed resources to `loadResource`. The Jottacloud resource
  lives in the shared app-group container, which the extension can access
  through its application-group entitlement. If another resource is
  security-scoped, start access before reading and stop access when unloading.

The extension's callbacks can be concurrent. Item identity and cache state
must be stable across lookup, enumeration, attribute, and read operations.
Preserve directory snapshots/cookies across repeated enumeration calls.

## Credential/resource boundary

FSKit launches the extension separately from the host app that prepares or
mounts the volume. Do not pass a login token in command arguments or put one in
the mount resource. The SwiftUI host app exchanges a personal login token
for OAuth credentials and does not persist the login token. On mount, the
extension discovers the account's devices and mountpoints using the shared
OAuth client. Both targets have the `group.no.alrek.jottafs`
application-group entitlement. The host app
creates `Library/Application Support/JottaFS` within that shared
container, sets its mode to 0700, and writes a binary `credentials.plist` with
mode 0600. The FSKit mount resource is the separate, empty `JottaCloudMount`
directory; the extension reads the plist and atomically persists rotating refresh tokens in
the shared container. Credentials from the previous app group are not migrated;
the user signs in again and old credentials remain untouched. This is a local
prototype boundary, not a Keychain-backed credential store. Do not share or
commit the directory.

`JottaFS.xcodeproj` defines a SwiftUI host app, the FSKit `.appex`, and a
shared API framework. The host app links the framework and uses
`FSClient.mountSingleVolume`; its entitlements include
`com.apple.developer.fskit.mount`. The extension plist declares the FSKit
extension point and short name, and its entitlements include the FSKit module
network-client, and shared app-group capabilities. Xcode 27.2 successfully
builds and signs the app and extension. Both targets require the shared
app-group capability; the host app also needs the network-client entitlement
because it authenticates the account, while the extension needs it for
filesystem requests. The Apriil account must be configured in Xcode and both
targets need matching provisioning profiles before a signed build is possible.
Runtime extension enablement, all-location discovery, directory enumeration,
and file reads still require validation.

## Apple references

- [FSKit overview](https://developer.apple.com/documentation/fskit)
- [Building a passthrough file system](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system)
- [FSUnaryFileSystem](https://developer.apple.com/documentation/fskit/fsunaryfilesystem)
- [FSUnaryFileSystemOperations](https://developer.apple.com/documentation/fskit/fsunaryfilesystemoperations)
- [FSVolume.Handler](https://developer.apple.com/documentation/fskit/fsvolume/handler)
- [FSVolume.ReadWriteHandler](https://developer.apple.com/documentation/fskit/fsvolume/readwritehandler)
