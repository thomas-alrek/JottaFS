---
name: release
description: Release JottaFS in one command - commit pending work, write the release notes for the next version, build and notarize the DMG, update the Homebrew casks, commit, tag, push and create the GitHub release. Use when asked to release, ship or publish a new JottaFS version (args - optional "minor" or "major"; default is the next patch version). For a local test build only, use make release instead.
---

# Release JottaFS

Invoking this skill is the owner's request to publish: it ends with a tag, a
push and a public GitHub release. If the request was only for a local test
build, stop and run `make release` (or `SKIP_NOTARIZE=1 make release`)
instead. Reference: `docs/releasing.md`.

Arguments: none for the next patch version, `minor` or `major` to bump that
instead. Below, `<bump>` is `--patch`, `--minor` or `--major`.

## 1. Commit pending work

If `git status` shows changes, commit them first, following the `commit`
skill (logical commits, Conventional Commits, the attribution trailer).
Check the diff for secrets (tokens, passwords, keys) before committing.
Never commit `dist/`, `build/` or credentials.

## 2. Write the release notes

1. `NEXT=$(scripts/release.sh <bump> --version)` gives the version.
2. Read what changed: `git log --oneline v<last version>..HEAD` and the
   diffs as needed.
3. Write `docs/release-notes/$NEXT.md` for JottaFS users (not developers):
   plain language in ASD-STE100 style, like the earlier notes in that
   folder. Sections as needed: `## JottaFS <version>`, `### New`,
   `### Faster`, `### Fixed`, `### Known limits` (copy the current ones from
   the README's Limits section and the previous notes, updated),
   `### Requirements` (Apple silicon, macOS 27 or later, a Jottacloud
   account). Leave out internal changes users cannot notice.
4. Commit it: `docs: add the <version> release notes`.

## 3. Build, notarize and publish

Run `scripts/release.sh <bump>` in the background (Bash
`run_in_background`), logging to the scratchpad. It takes several minutes
(notarization). Do not edit sources while it runs. It:

1. checks the tree is clean, the notes are committed and the tag is free;
2. builds, exports with Developer ID, checks provisioning profiles for app
   groups, notarizes and staples the app and the DMG, and checks the app
   with Gatekeeper (`scripts/build-release.sh`);
3. removes `build/release`;
4. updates the Homebrew casks (`Casks/jottafs.rb` and the pinned
   `Casks/jottafs@<version>.rb` through `scripts/update-cask.sh`), commits
   them with `VERSION` as "Release <version>", tags `v<version>`, pushes the
   branch and the tag, and creates the GitHub release with the DMG and the
   notes (`scripts/publish-release.sh --yes`);
5. checks that the asset's checksum, the casks and the latest release
   match, and runs `brew style` on the casks.

## 4. Report

When it finishes, read the end of the log. On success, tell the owner the
release URL, the commits pushed (`git log --oneline` since the previous
release) and anything the script warned about. On failure, report the
failing step and the error; nothing is tagged or pushed if the build fails.
If it failed after tagging, do not delete tags or releases without asking.

## Rules

- Before building, eject every mounted JottaFS DMG (`ls /Volumes`): a test
  DMG of the same version has the same volume name, and Finder would write
  the installer layout to it instead of the release DMG. The build stops if
  one is mounted. Prefer test builds with `make release` from a reset
  `VERSION` only when needed, and eject them when done.

- Every published release updates the casks (AGENTS.md, "Releases"); the
  script does this. If a release is ever published another way, run
  `scripts/update-cask.sh <version> <sha256>`, commit `Casks/` and push.
- Use `HOMEBREW_DEVELOPER=1` only per command for Homebrew developer
  commands, so developer mode is not switched on permanently.
- If notarization or signing fails because of Apple account setup (for
  example a new bundle identifier that is not in the app group), stop and
  tell the owner what to change in the developer portal.
