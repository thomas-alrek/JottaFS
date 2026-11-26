# Releasing JottaFS

A release is a signed and notarized `dist/JottaFS-<version>.dmg` with the
usual drag-to-Applications window, a Git tag `v<version>` and a GitHub
release with the changelog and the DMG.

## One-time setup

1. **Developer ID signing.** Sign in to Xcode (**Settings → Apple Accounts**)
   with an Apple ID that is an Admin of Apriil Digital AS (`PLY3DSPA3F`)
   with **Access to Cloud Managed Developer ID Certificate** (set by the
   Account Holder in App Store Connect → Users and Access). The export then
   signs with the cloud-managed certificate; nothing is installed locally,
   and the DMG stays unsigned (the app in it is signed, and the DMG is
   notarized and stapled). A local **Developer ID Application** certificate
   also works; then the DMG is signed too.
2. **Notarization credentials.** Create an app-specific password at
   [account.apple.com](https://account.apple.com) (Sign-In and Security →
   App-Specific Passwords). Then store the credentials in the keychain:

   ```sh
   xcrun notarytool store-credentials JottaFS-notary \
       --apple-id <your Apple ID> --team-id PLY3DSPA3F
   ```

3. **GitHub CLI.** Sign in with `gh auth login` (needed to publish only).
4. **Finder access.** The first build asks for permission for Terminal to
   control Finder. Allow it: Finder lays out the installer window.

## Build

```sh
make release          # 1.0.0 the first time, then 1.0.1, 1.0.2, …
make release-minor    # 1.0.7 → 1.1.0
make release-major    # 1.4.2 → 2.0.0
```

`scripts/build-release.sh` does these steps and stops at the first problem:

1. Calculates the version from `VERSION` (the last version built). The build
   number is the number of commits.
2. Archives the Release configuration. The deployment target is macOS 27,
   which runs only on Apple silicon (macOS 26 was the last macOS for Intel
   Macs), so the build is `arm64` only. If the deployment target is lowered
   below 27, the script builds a universal (`arm64` + `x86_64`) binary.
3. Exports the app with Developer ID signing and the hardened runtime, and
   checks the signature.
4. Notarizes and staples the app.
5. Makes the DMG: the app, a link to Applications, the background from
   `Tools/make-dmg-background.swift` and the JottaFS volume icon. Finder
   writes the window layout (background, icon positions) into the DMG's
   `.DS_Store`. Finder finds the disk by its name, "JottaFS <version>", so
   no other disk with that name may be mounted, such as a test DMG of the
   same version: the build stops if one is, and fails if the layout is
   missing. (JottaFS 1.1.0 was first published without its layout because a
   1.1.0 test DMG was mounted; the DMG was replaced the same day.)
6. Signs, notarizes and staples the DMG, and checks it with Gatekeeper.
7. Writes `dist/JottaFS-<version>-CHANGELOG.md`: a copy of
   `docs/release-notes/<version>.md` when that file exists (write one for
   releases that deserve hand-written notes), otherwise the commits since
   the last tag.
8. Writes the new version to `VERSION`.

To test the build before the notarization setup is complete, use
`SKIP_NOTARIZE=1 make release`. Do not publish such a build: Gatekeeper
blocks it on other Macs.

The version number in the project (`MARKETING_VERSION`) stays 1.0.0 for local
builds; the release build sets the real version.

## Tests

Two kinds of tests must pass before a release is published.
`scripts/release.sh` (`make ship`) checks both and stops otherwise.

- **Checks and regression tests**, `make check`: checks that every source
  file is in the Xcode project (`scripts/check-xcode-sources.sh`; SwiftPM
  finds new files by itself, Xcode does not), builds the extension and
  runs `jottafs-checks` (JottaFSCore) and `swift test`
  (`Tests/JottaFSKitExtensionTests`, the extension's write path). Each bug
  that was fixed gets a regression test that fails if the bug comes back.
  The release script runs `make check` first.
- **Live probe**, `make probe VOLUME=/Volumes/<volume>`: runs
  `scripts/probe-volume.sh` against a mounted location with the build to be
  released installed. It works only in a new, uniquely named folder under
  `JottaFS-Test` and deletes it at the end. It copies files the way Finder
  does while the folder is listed, and checks sizes and contents right
  away, after 20 s and after 75 s (1.1.2: files showed 0 bytes). It also
  tries a Safari-style download, a move from the Mac's disk and a quarantine
  attribute. When everything passes, it writes `build/probe/<version>.passed`
  with a hash of the source files (`scripts/source-hash.sh`; committed or
  not). The release script needs that file for the version it releases,
  with the same source hash, so the release is built from the probed
  sources.

If a regression test or the probe fails, a fixed bug is back. Do not
publish. Tell the owner, fix the bug, run `make check` again, make a new
build, install it, probe it, and only then release.

Flow for a release: commit the fix, then `SKIP_NOTARIZE=1 make release`
(or `make release` for a build to hand out for testing). Install the DMG,
mount the location and run `make probe`. Reset `VERSION` to the previous
version and delete the test DMG from `dist/`. Write the release notes and
run `make ship`.

Not covered by the probe: uploads over a poor connection. Test those by
hand with a throttled network (Network Link Conditioner, "Very Bad
Network"), or by turning off Wi-Fi during a large copy. The copy must fail
within about a minute, and Finder must stay responsive.

## Manual test

1. Open the DMG. Check the window, the background and the icons.
2. Drag JottaFS to Applications, open it, sign in and mount a location.
3. Check **JottaFS → About JottaFS** for the version and the copyright.
4. Check that every text has a Norwegian translation: Xcode shows the
   progress of each String Catalog (`Localizable.xcstrings`) in the project
   navigator. To see the app in Norwegian, set JottaFS to Norsk bokmål in
   **System Settings → General → Language & Region → Applications**.

## How installed apps update

The app checks `https://api.github.com/repos/thomas-alrek/JottaFS/releases/latest`
at launch and once a day (`HostApp/Updater.swift`; never in Debug builds).
When the release tag (`v<version>`) is newer than the running version and the
release has a `JottaFS-*.dmg` asset, the app offers the update. Network
errors, timeouts (10 s) and other answers are only logged.

**Update** downloads the DMG into the app's container. The unsandboxed
helper service (`JottaFSService/UpdateInstaller.swift`) then:

1. accepts only a regular `.dmg` in the app's container;
2. checks the `JottaFS.app` inside the DMG: Developer ID, the same team as
   the helper, bundle identifier `no.alrek.jottafs`, and a version newer
   than the installed one (a signed DMG must also be signed by the team;
   cloud-signed releases have an unsigned DMG);
3. copies the app next to the installed one, removes the download
   quarantine, checks it again, and swaps it in atomically
   (`FileManager.replaceItemAt`). The location is the app that contains the
   helper, never a path from the request.

The app then opens the new version and quits. A mounted volume stays
mounted; the new extension is used from the next mount.

So that installed apps can update, every release must be published with
`make publish` (the tag and the DMG asset are what the app looks for).

## Release in one step

```sh
make ship          # next patch version; make ship-minor / make ship-major
```

`scripts/release.sh` needs a clean working tree and the committed release
notes for the next version (`scripts/release.sh --version` prints it). It
runs `scripts/build-release.sh`, removes `build/release`, runs
`scripts/publish-release.sh --yes` (below) and then checks the published
asset's checksum, the casks and that the release is the latest one. Nothing
is tagged or pushed if the build fails.

## Publish

```sh
make publish
```

`scripts/publish-release.sh` shows the release and asks for confirmation.
Then it runs `scripts/update-cask.sh`, which sets the version and the DMG's
SHA-256 in the Homebrew cask (`Casks/jottafs.rb`) and adds a pinned cask
for the version (`Casks/jottafs@<version>.rb`, installed with
`brew install --cask jottafs@<version>`). It commits the casks with
`VERSION`, tags the commit
`v<version>`, pushes the branch and the tag, and creates the GitHub release
with the changelog and the DMG.

The repository is its own Homebrew tap (`brew tap thomas-alrek/jottafs
https://github.com/thomas-alrek/JottaFS`), so the cask on `main` is what
`brew install --cask jottafs` and `brew upgrade` use. Check the cask with
`HOMEBREW_DEVELOPER=1 brew style Casks/jottafs.rb` (the variable keeps
Homebrew's developer mode from being switched on permanently).
