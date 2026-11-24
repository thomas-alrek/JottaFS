# Write support design

**Update 2026-11-24:** the owner lifted the write scope below after testing.
The whole mounted location is writable; `JottaFSWriteScope` was removed.
`rm` now deletes permanently ([trash design](trash-design.md)). The rest of
this document is kept as the original reviewed design.

Status: reviewed by the project owner on 2026-11-24, who accepted the
recommended answer to every decision below (write scope `JottaFS-Test` only,
upload on close, deletes to trash, case-insensitive
volume). Implemented 2026-11-24 (`WriteSupport.swift`, `StagingArea.swift`,
`JottaFSVolume+Write.swift`); not yet verified on a live mount. For an
unlimited quota the volume reports a nominal 1 TiB free, because the kernel
refuses writes with ENOSPC on a volume reporting no free space.

## Goals and non-goals

Goal: let ordinary macOS tools (`cp`, `mv`, `rm`, `mkdir`, shell redirects,
TextEdit, Finder copy/rename/delete) create, modify, rename and delete files
and folders on the JottaCloud volume, with correct data on Jottacloud.

Non-goals for the first version: symbolic and hard links, permissions and
ownership, extended attributes beyond the existing root FinderInfo, creating
or removing devices or mountpoints, emptying the Jottacloud trash, and
offline operation.

## Safety: the write scope

The account holds the user's personal data. Being careful is not enough, so
the extension enforces a write scope in code:

- Every mutating callback (create file or folder, write, truncate, set
  attributes, rename, remove) first checks that every item it touches lies
  strictly inside the write scope. Anything else fails with `EPERM`, before
  any network request.
- The write scope is one folder, `Jotta/Archive/JottaFS-Test`. It did not
  exist before write support, so everything inside it is created through our
  testing. The only change allowed directly in `Jotta/Archive` is creating
  that folder (`mkdir`); the folder itself can never be renamed or removed
  through the volume.
- Permission bits are a second barrier: only the scope folder, its contents
  and `Jotta/Archive` itself (so the folder can be created) report write
  bits, so the kernel rejects writes elsewhere before they reach the
  extension.
- Renames must have both source and destination inside the scope, so nothing
  can be moved in or out.
- The scope is a single constant in `JottaFSCore`, with unit tests for the
  path checks (including `..`, case variants such as `jottafs-test`, Unicode
  look-alikes, and paths that merely share the prefix like
  `JottaFS-Test-old`). Widening it later is a separate, explicit decision.
- Deletes move items to the Jottacloud trash (`dl=true` / `dlDir=true`),
  never permanent deletes (`rm=`/`rmDir=`), so even a bug inside the scope is
  recoverable for 30 days.

Outside the scope the volume behaves exactly as today (read-only).

## Jottacloud API (from rclone's backend; undocumented)

| Operation | Request |
|---|---|
| Upload (new or overwrite) | `POST https://api.jottacloud.com/files/v1/allocate` with JSON `{bytes, md5, path: "/jfs/<device>/<mountpoint>/<path>", created, modified}` (RFC 3339, no fractions). If `state` ≠ `COMPLETED`, `POST` the bytes from `resume_pos` to `upload_url` (`Content-Type: application/octet-stream`). Then `GET` the file and require `currentRevision/state == COMPLETED` with matching size and MD5. |
| Create folder | `POST /jfs/<user>/<device>/<mountpoint>/<path>?mkDir=true` |
| Delete file / folder | `POST …/<path>?dl=true` / `POST …/<path>/?dlDir=true` (trash) |
| Rename/move file | `POST …/<src>?mv=/<user>/<device>/<mountpoint>/<dst>` |
| Rename/move folder | `POST …/<src>/?mvDir=/<user>/<device>/<mountpoint>/<dst>` |

Unknowns to verify live, inside the scope: zero-byte uploads, `mv=` onto an
existing destination, behaviour when a deleted path is reused (rclone notes
inconsistencies until the trash is emptied), and how quickly listings reflect
changes. Overwriting creates a new version on Jottacloud; old versions stay
visible on the website.

Jottacloud needs the MD5 and size before upload, so a file cannot be streamed
up as it is written.

## Write model: local staging, upload on close

- **Staging.** A file opened for writing gets a staging file in the
  extension's container (`Caches/Staging/<item id>`). A new file starts empty.
  An existing file (necessarily inside the scope) is downloaded in full into
  staging first, unless it is being truncated to zero. `write` and `truncate`
  change only the staging file; reads of a dirty file come from staging.
- **Upload.** When the last open handle closes (FSKit `OpenCloseHandler`),
  a dirty file is uploaded and close(2) returns only when the upload has
  finished (decided 2026-11-24): Finder's copy and its "done" sound then mean
  the file is on Jottacloud, and a failed upload is returned from close so
  Finder reports the copy as failed. Finder's copy dialog cannot follow the
  upload itself, because Jottacloud needs the whole file's MD5 before any
  upload starts (see the API notes); a background upload after close was
  tried and rejected as misleading. Deleting a file waits for its running
  upload; renames flush first; unmounting waits for pending and running
  uploads. On `synchronize`, dirty files are also uploaded: compute MD5 over the staging
  file, allocate, stream the staging file to `upload_url`, verify. The staging
  file is removed after a verified upload.
- **Failure.** If the upload fails, the staging file is kept and the item
  stays dirty; reads still return the new data, the next close or sync
  retries, and the failure is logged. A failing sync does not fail: macOS
  syncs before unmounting, and a permanently failing upload must not make
  the volume impossible to unmount (data still staged at unmount is lost). `close` cannot report errors to most
  apps, so a failed upload is not visible to the app that wrote the file. This
  is the main semantic limit of the design.
- **Limits.** Staging has no size limit of its own: a write that the local
  disk cannot hold fails with `ENOSPC`. The local copy is deleted after a
  successful upload once the file is closed for writing and unchanged
  (`StagingArea.discardIfUploaded`), so copying many files onto the volume
  needs local space for about one file at a time; a write that finds its
  copy just deleted stages the file again. Uploads are not resumed across
  extension restarts in the first version. (Until 1.0.3 staging was capped at
  2 GiB per file, and uploaded copies stayed until the item was reclaimed.)
- **Timestamps.** `created` and `modified` are sent with each upload;
  modification times set on a clean file are applied on its next upload only.

## Names and case

- Jottacloud is case-insensitive, but the volume currently declares itself
  case-sensitive. With writes enabled that would allow `a.txt` and `A.txt`
  side by side locally while they collide remotely. The volume will declare
  case-insensitive, case-preserving behaviour and look names up
  case-insensitively.
- Names Jottacloud cannot store (`" * : < > ? | %`, control characters, more
  than 255 characters, `.` and `..`) are rejected with `EINVAL` rather than
  silently re-encoded, per `AGENTS.md`.
- macOS metadata files: `.DS_Store` and AppleDouble `._*` files are
  allowed and uploaded like other files (inside the scope). Refusing them,
  as first decided, made Finder abort folder copies with error -8062, and
  the owner chose to allow them (2026-11-24).

## Caches and identity

- After each mutation, update the affected directory snapshots in
  `DirectoryCache` directly (insert, remove, rename entries) instead of
  waiting for the 5-second lifetime, so new items appear immediately even if
  Jottacloud's listing lags.
- `ItemStore` is keyed by path; renaming a folder must remap the paths of its
  cached descendants.
- The mount becomes read-write: `requestedMountOptions` drops `.readOnly`, and
  the volume reports real available space.

## Tests

Unit (`jottafs-checks`): scope checks, name validation, allocate request
encoding, upload/verify response parsing, staging read/write/truncate, and
cache updates after create/rename/delete.

Live, only inside `Jotta/Archive/JottaFS-Test`, with a read-only listing of
`Jotta/Archive` taken before and after to show nothing else changed:
`mkdir`; create, write, read back and append to a small file; zero-byte file;
overwrite; truncate; a file larger than 10 MB with byte-for-byte read-back;
rename a file and a folder; delete (and confirm it is in the Jottacloud
trash); TextEdit save (atomic replace); Finder copy-in, rename and delete;
and attempts to write outside the scope, which must fail with no request
sent.

## Decisions needed

1. Write scope: `Jotta/Archive/JottaFS-Test` as the only writable folder?
2. Upload on close (write-back) with the failure behaviour above?
3. Deletes always to the Jottacloud trash?
4. Refuse `.DS_Store` / `._*` files, as proposed? (Later reversed: allowed.)
5. Switch the volume to case-insensitive?
