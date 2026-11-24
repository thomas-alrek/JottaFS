# Project guidance

This is a native macOS Swift file system extension for working with
Jottacloud files in Finder through Apple FSKit. The user signs in in the app
(browser OAuth or a personal login token), picks one Jottacloud location
(a device's mountpoint, such as `Jotta/Archive`), and the app mounts that
location as a read-write volume.

## Engineering principles

- Keep Jottacloud authentication/API logic separate from FSKit callbacks and
  SwiftUI app setup.
- Treat Jottacloud's API as undocumented unless confirmed by current,
  authoritative documentation. See [the retained API research](docs/jottacloud-api-internals.md).
- Keep OAuth secrets out of source, logs, command-line arguments, and test
  fixtures. The app stores credentials as a private property list under the
  shared app-group Application Support directory; document that boundary and
  serialize refresh-token rotation.
- File mutations follow the reviewed designs in
  [docs/write-support-design.md](docs/write-support-design.md) and
  [docs/trash-design.md](docs/trash-design.md). The owner lifted the
  `JottaFS-Test` write scope on 2026-11-24: the mounted location is fully
  writable for the user. The account still holds the owner's personal data,
  so the development rule stands: in your own testing never modify, move,
  delete (soft or permanent), restore or otherwise touch files the project
  did not create; create test files under `Jotta/Archive/JottaFS-Test` with
  unique names; never trigger Empty Trash yourself; and never use
  whole-account operations such as `files/v1/purge_trash`.
- Make network I/O asynchronous and bounded. Use ranged downloads, short
  bounded directory caches, and avoid buffering whole files.
- FSKit callbacks can run concurrently. Protect shared item, directory, and
  credential state with actors or narrowly scoped synchronization.
- Preserve filesystem name bytes where possible; reject invalid or ambiguous
  names rather than silently normalizing them.
- Follow [the FSKit internals notes](docs/fskit-internals.md) and document
  platform requirements, extension installation, and known limits.
- Run `swift build --target JottaFSKitExtension` and
  `swift run jottafs-checks` for local checks. The Swift package
  compilation does not validate app-extension packaging or mounting; use the
  `JottaFS.xcodeproj` with Xcode to build and validate the signed app and
  FSKit extension.

## API notes

- Standard Jottacloud login tokens are single-use, base64url-encoded JSON.
- OAuth refresh tokens rotate; concurrent refreshes must be serialized.
- The extension discovers devices and mountpoints and exposes them as folders
  in the mounted account view.
- XML listing entries without a completed current revision are not exposed.
- Only the official `id.jottacloud.com` identity host is supported.
- Keep research and unresolved API assumptions in
  [docs/jottacloud-api-internals.md](docs/jottacloud-api-internals.md).
