# Write support design

How JottaFS changes files on Jottacloud. The design was reviewed by the
project owner on 2026-11-24 and tested live (first inside a single test
folder, `Jotta/Archive/JottaFS-Test`, then on the whole location once the
owner lifted that limit). Deletes and the Trash are in
[the Trash design](trash-design.md). Code: `WriteSupport.swift` (Core),
`StagingArea.swift` and `JottaFSVolume+Write.swift` (extension).

## Scope

Ordinary macOS tools (`cp`, `mv`, `rm`, `mkdir`, shell redirects, TextEdit,
Finder copy, rename and delete) create, change, rename and delete files and
folders in the mounted location, with correct data on Jottacloud.

Not supported: symbolic and hard links (`ENOTSUP`), permissions and
ownership, extended attributes (beyond the root's FinderInfo), creating or
removing devices or mountpoints, and offline changes.

The account holds personal data. In development and testing, only touch
files the project created, under `Jotta/Archive/JottaFS-Test` (AGENTS.md).

## Jottacloud API (from rclone's backend; undocumented)

| Operation | Request |
|---|---|
| Upload (new or overwrite) | `POST https://api.jottacloud.com/files/v1/allocate` with JSON `{bytes, md5, path: "/jfs/<device>/<mountpoint>/<path>", created, modified}` (RFC 3339, no fractions). If `state` ≠ `COMPLETED`, send the bytes from `resume_pos` to `upload_url` (`Content-Type: application/octet-stream`). Then `GET` the file and require `currentRevision/state == COMPLETED` with matching size and MD5. |
| Create folder | `POST /jfs/<user>/<device>/<mountpoint>/<path>?mkDir=true` |
| Move to trash, file / folder | `POST …/<path>?dl=true` / `POST …/<path>/?dlDir=true` |
| Rename/move file | `POST …/<src>?mv=/<user>/<device>/<mountpoint>/<dst>` |
| Rename/move folder | `POST …/<src>/?mvDir=/<user>/<device>/<mountpoint>/<dst>` |

Jottacloud needs the size and MD5 before an upload starts, and has no
streaming upload, so a file cannot be sent while it is written (details in
[the API notes](jottacloud-api-internals.md)). Overwriting creates a new
version; old versions stay visible on the website. Identical content is
deduplicated at allocation (`state` `COMPLETED` at once). An interrupted
upload resumes from the server's `resume_pos` (kept in 32 MiB blocks per
MD5).

## Write model: stage locally, upload on close

- **Staging.** A file opened for writing gets a local copy in the
  extension's Caches container (`Staging/<location key>/`). A new file starts
  empty; an existing file is downloaded into the copy first, unless it is
  truncated to zero. Writes and truncation change only the copy, and reads of
  a changed file come from it. Each location has its own staging folder (one
  extension process per mounted location).
- **MD5 while writing.** The staging area keeps a running MD5 of each copy,
  updated under its lock by every write that continues where the hashed part
  ends. A write or truncation into the hashed part drops it. At upload only
  the rest is hashed, so a file copied in order needs no extra pass.
- **Upload.** When the last writer closes the file, it is uploaded, and
  close(2) returns only when the upload is complete and verified: Finder's
  copy and its "done" sound then mean the file is on Jottacloud, and a failed
  upload is returned from close (Finder reports the copy as failed). The upload
  uses an APFS clone of the copy, so later writes do not change the bytes
  being sent. Deleting a file waits for its running upload; renames flush
  first; `synchronize` uploads changed files; unmounting waits for pending and
  running uploads.
- **After upload.** The local copy is deleted once the upload succeeded and
  the file is closed for writing and unchanged
  (`StagingArea.discardIfUploaded`), so copying many files needs local space
  for about one file at a time. Later reads come from Jottacloud; a write that
  finds its copy just deleted stages the file again. The original that was
  copied onto the volume is never touched (the extension only receives its
  bytes).
- **Failure.** If an upload fails, the copy stays and the item stays dirty:
  reads return the new data, the next close or sync retries, and the failure
  is logged with a safe cause. A failing sync does not fail, because macOS
  syncs before unmounting and a permanently failing upload must not block the
  unmount (data still staged then is lost).
- **Space.** There is no size limit of its own (the volume reports 64-bit file
  sizes). A write the Mac's disk cannot hold fails with `ENOSPC`, so the
  writing app reports that there is not enough space. (Until 1.0.3 staging was
  capped at 2 GiB per file, and uploaded copies stayed until the item was
  reclaimed.)
- **Timestamps.** `created` and `modified` are sent with each upload; a
  modification time set on an unchanged file is applied at its next upload.
- **Progress.** Upload progress is shown on the file's icon in Finder through
  `JottaFSProgressAgent` ([FSKit notes](fskit-internals.md#upload-progress-in-finder)).

## Names and case

- Jottacloud is case-insensitive, so the volume is case-insensitive and
  case-preserving and looks names up case-insensitively.
- Names Jottacloud cannot store (`" * : < > ? | %`, control characters, more
  than 255 characters, `.` and `..`) are rejected with `EINVAL`, not silently
  re-encoded (AGENTS.md).
- `.DS_Store` and AppleDouble `._*` files are uploaded like other files.
  Refusing them made Finder abort folder copies with error -8062.

## Caches and identity

- Every change updates the affected directory listings in `DirectoryCache`
  at once (an overlay kept for 60 s), so new items appear even when
  Jottacloud's listing lags.
- `ItemStore` is keyed by path; renaming a folder remaps the paths of its
  known descendants.
- A changed file's read-ahead and cached blocks are dropped; the disk block
  cache is keyed by the MD5 of a file's revision, so it never serves stale
  data.

## Tests

`jottafs-checks` covers name validation, allocate request encoding,
upload/verify response parsing, staging read/write/truncate, the running MD5
and the cache updates. Live tests use new, uniquely named files under
`Jotta/Archive/JottaFS-Test` only: create, write, read back and append;
zero-byte and large files with byte-for-byte read-back; overwrite;
truncate; rename and move of files and folders; delete; TextEdit save
(atomic replace); Finder copy-in, rename and delete.
