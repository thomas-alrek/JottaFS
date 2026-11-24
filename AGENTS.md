# Project guidance

This is a native macOS Swift file system extension for browsing Jottacloud with
Apple FSKit. It mounts one account view, with each discovered device and
mountpoint exposed under `/<device>/<mountpoint>/`. It is read-only except
for one write-scope folder (see below).

## Engineering principles

- Keep Jottacloud authentication/API logic separate from FSKit callbacks and
  SwiftUI app setup.
- Treat Jottacloud's API as undocumented unless confirmed by current,
  authoritative documentation. See [the retained API research](docs/jottacloud-api-internals.md).
- Keep OAuth secrets out of source, logs, command-line arguments, and test
  fixtures. The app stores credentials as a private property list under the
  shared app-group Application Support directory; document that boundary and
  serialize refresh-token rotation.
- File mutations follow the reviewed design in
  [docs/write-support-design.md](docs/write-support-design.md) and are
  confined to `JottaFSWriteScope` (`Jotta/Archive/JottaFS-Test`). The account
  holds the owner's personal data, and the rule is about that data during
  development: never modify, move, delete (soft or permanent) or otherwise
  touch files the project did not create, and never widen the scope without
  an explicit, separate decision. Permanent deletion is a normal feature
  (for example emptying the Trash) as long as it only affects items created
  through the scope; never use whole-account operations such as
  `files/v1/purge_trash`, which would also remove the owner's own trashed
  files.
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
