# Project guidance

This is a native macOS Swift file system extension for working with
Jottacloud files in Finder through Apple FSKit. The user signs in in the app
(browser OAuth or a personal login token), picks Jottacloud locations
(a device's mountpoint, such as `Jotta/Archive`), and the app mounts each
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
- User-facing texts are localized with String Catalogs
  (`Localizable.xcstrings` in `HostApp`, `FinderExtension`, `JottaFSService`
  and `Sources/JottaFSCore`): English is the development language and
  fallback, and every new text needs a Norwegian (`nb`) translation. Use
  `String(localized:)` for texts that are not SwiftUI literals (JottaFSCore:
  `bundle: .jottaFSCore`). Norwegian uses "Aktiver / Deaktiver" for mount and
  unmount, and Jottacloud's own terms ("personlig login-token", "backup").
- Run `make check` for local checks: the Xcode project check, the
  extension build, `jottafs-checks` and the regression tests (`swift test`).
  Every fixed bug gets a regression test. The Swift package compilation
  does not validate app-extension packaging or mounting; use the
  `JottaFS.xcodeproj` with Xcode to build and validate the signed app and
  FSKit extension, and `make probe VOLUME=/Volumes/<volume>` (live write
  probe in `JottaFS-Test`) with that build installed.
- A failing regression test or probe means a fixed bug is back: stop, tell
  the owner, fix it, test, rebuild, install, probe and verify; publish only
  when it is confirmed fixed (docs/releasing.md, "Tests").

## Releases

- Follow [docs/releasing.md](docs/releasing.md). The `release` skill
  (`.claude/skills/release`) does a whole release in one command: commit,
  release notes, then `scripts/release.sh` (`make ship`), which builds,
  notarizes, updates the casks, tags, pushes and publishes. For a local
  test build only, use `make release`.
- Every notarized release published on GitHub must update the Homebrew
  casks in the same release commit: `Casks/jottafs.rb` gets the new version
  and the DMG's SHA-256, and `Casks/jottafs@<version>.rb` is added so the
  version stays installable. `scripts/publish-release.sh` does this through
  `scripts/update-cask.sh`; never publish a release by other means without
  running `scripts/update-cask.sh <version> <sha256>` and committing
  `Casks/`. Check the casks with
  `HOMEBREW_DEVELOPER=1 brew style Casks/*.rb` (the variable keeps
  Homebrew's developer mode from being switched on permanently).
- Write `docs/release-notes/<version>.md` before building; the build copies
  it into the changelog of the GitHub release.
- Do not tag, push or publish a release until the owner asks for it.

## API notes

- Standard Jottacloud login tokens are single-use, base64url-encoded JSON.
- OAuth refresh tokens rotate; concurrent refreshes must be serialized.
- Each mounted volume is one Jottacloud location (a device's mountpoint, or
  one backed-up folder of a computer backup); the app lists the locations
  from the account's devices and mountpoints. JottaFS never creates or
  deletes devices or mountpoints.
- XML listing entries without a completed current revision are not exposed.
- Only the official `id.jottacloud.com` identity host is supported.
- Keep research and unresolved API assumptions in
  [docs/jottacloud-api-internals.md](docs/jottacloud-api-internals.md).
