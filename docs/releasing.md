# Releasing JottaFS

A release is a signed and notarized `dist/JottaFS-<version>.dmg` with the
usual drag-to-Applications window, a Git tag `v<version>` and a GitHub
release with the changelog and the DMG.

## One-time setup

1. **Developer ID certificate.** In Xcode, open **Settings → Accounts**,
   select the team (`PLY3DSPA3F`), click **Manage Certificates**, and add a
   **Developer ID Application** certificate. Only the Account Holder or an
   Admin can create one. The build tries to create it automatically, but
   that also needs one of those roles.
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
   `Tools/make-dmg-background.swift` and the JottaFS volume icon.
6. Signs, notarizes and staples the DMG, and checks it with Gatekeeper.
7. Writes `dist/JottaFS-<version>-CHANGELOG.md` from the commits since the
   last tag.
8. Writes the new version to `VERSION`.

To test the build before the notarization setup is complete, use
`SKIP_NOTARIZE=1 make release`. Do not publish such a build: Gatekeeper
blocks it on other Macs.

The version number in the project (`MARKETING_VERSION`) stays 1.0.0 for local
builds; the release build sets the real version.

## Test

1. Open the DMG. Check the window, the background and the icons.
2. Drag JottaFS to Applications, open it, sign in and mount a location.
3. Check **JottaFS → About JottaFS** for the version and the copyright.

## Publish

```sh
make publish
```

`scripts/publish-release.sh` shows the release and asks for confirmation.
Then it commits `VERSION`, tags the commit `v<version>`, pushes the branch and
the tag, and creates the GitHub release with the changelog and the DMG.
