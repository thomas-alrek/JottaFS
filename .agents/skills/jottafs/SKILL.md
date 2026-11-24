# JottaFS development

Use this guide when modifying this repository's Jottacloud client or native
macOS FSKit filesystem.

## Architecture

- `Sources/JottaFSCore/` contains the asynchronous Jottacloud API client,
  OAuth flow, XML listing parser, JFS URL construction, and bounded range
  downloads.
- `Sources/JottaFSKitExtension/` maps the remote API to a read-only
  `FSUnaryFileSystem` and `FSVolume`.
- `HostApp/` provides SwiftUI login, remote-volume selection, and FSClient
  mounting. `Sources/JottaFSCore/Storage.swift` stores credentials in a
  shared app-group Application Support directory as a binary property list.
- `Tests/JottaFSCoreChecks/` is the current executable smoke-check
  harness; XCTest is not available in the active Command Line Tools setup.

## Constraints

- Keep all filesystem mutations disabled. Do not return success for unsupported
  writes or metadata changes.
- Keep credentials out of arguments, logs, source control, and test fixtures.
  Keep the shared credentials directory private, serialize refresh-token
  rotation, and persist the rotated token before treating refresh as successful.
- Keep remote reads ranged and bounded; do not download complete files into
  memory.
- Jottacloud API behavior is partly inferred from rclone. Preserve uncertainty
  and document new observations in `docs/jottacloud-api-internals.md`.
- The Xcode project uses the Apriil team and requires matching account access
  and provisioning profiles to sign the host app and `.appex`. Do not claim
  mounting works until signing, extension enablement, and an actual mount/read
  test succeed.

## Checks

Run:

```sh
swift build --target JottaFSKitExtension
swift run jottafs-checks
```

For packaging and runtime validation, use a full Xcode installation, build and
sign the `JottaFS` scheme, enable the extension in System Settings, then
verify mounting, directory enumeration, ranged file reads, and unmounting.

See `docs/fskit-internals.md` and `docs/jottacloud-api-internals.md` for platform
and protocol details.
