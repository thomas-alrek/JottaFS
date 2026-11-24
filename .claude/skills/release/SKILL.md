---
name: release
description: Build, notarize and publish a JottaFS release on GitHub, and update the Homebrew casks (Casks/jottafs.rb and Casks/jottafs@<version>.rb) for it. Use when asked to build a release, a notarized DMG, a new version, or to tag/publish/release JottaFS.
---

# Release JottaFS

The full reference is `docs/releasing.md`. Only tag, push or publish when the
owner asks for it; a local build for testing stops after step 3.

## 1. Prepare

- Commit the changes that go into the release (`/commit`).
- `VERSION` holds the last built version; `make release` builds the next
  patch version (`make release-minor` / `make release-major` when asked).
  To rebuild a version that was never published, delete
  `dist/JottaFS-<version>.dmg` and its changelog and restore `VERSION`
  with `git checkout -- VERSION` first.
- Write `docs/release-notes/<version>.md` (plain language, ASD-STE100
  style, same sections as earlier notes: New, Fixed/Faster, Known limits,
  Requirements) and commit it before building; the build copies it into
  `dist/JottaFS-<version>-CHANGELOG.md`.

## 2. Build

Run `make release` in the background (it takes several minutes because of
notarization) and log to the scratchpad. It archives, exports with
Developer ID, checks every component's provisioning profile has the app
groups it is signed for, notarizes and staples the app and the DMG, and
checks the app with Gatekeeper. Do not edit sources while it archives.

## 3. Check

- The log ends with `EXIT 0`, `status: Accepted` and `accepted`.
- `dist/JottaFS-<version>.dmg` exists and the changelog matches the notes.
- Remove `build/release` afterwards (`rm -rf build/release`): extra copies
  of the app make macOS register the extension more than once
  (ExtensionKit error 2 when mounting).

## 4. Publish (only when asked)

Run `scripts/publish-release.sh --yes`. It:

1. runs `scripts/update-cask.sh <version> <sha256>`, which updates
   `Casks/jottafs.rb` and adds `Casks/jottafs@<version>.rb`;
2. commits `VERSION` and `Casks/` as "Release <version>";
3. tags `v<version>`, pushes the branch and the tag;
4. creates the GitHub release with the DMG and the changelog.

**Every published release must update the casks.** If a release is ever
published another way, run `scripts/update-cask.sh <version> <sha256>`
with the DMG's SHA-256, commit `Casks/` and push.

## 5. Verify

```sh
gh release view v<version> --json assets,isDraft,isPrerelease
gh api repos/thomas-alrek/JottaFS/releases/latest --jq .tag_name
shasum -a 256 dist/JottaFS-<version>.dmg   # equals the asset digest and the cask's sha256
HOMEBREW_DEVELOPER=1 HOMEBREW_NO_AUTO_UPDATE=1 brew style Casks/*.rb
```

Use `HOMEBREW_DEVELOPER=1` for Homebrew developer commands so developer
mode is not switched on permanently; check with `brew developer` that it is
still off.
