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
  - **Early refusal.** The volume implements `FSVolume.PreallocateHandler`:
    when a writer announces the size first (`F_PREALLOCATE`, as copy tools
    do), the extension reserves that space for the staged copy on the Mac's
    disk (`F_PREALLOCATE` with `F_ALLOCATEALL | F_ALLOCATEPERSIST`, so the
    reservation outlives the descriptor; `JottaFSStagingFile.reserve`). If the
    disk cannot hold it, the call fails with `ENOSPC` before any data is
    written, instead of after gigabytes. Checked 2026-11-25 with 50 MB copies
    into `JottaFS-Test`: Finder and `cp` preallocate the whole size before
    writing; `ditto` does not (its copies get only the cache fallback). A
    direct `F_PREALLOCATE` of 1 TB was refused with `ENOSPC` at once.
  - **Cache first.** Before refusing a reservation, and when a staged write
    runs out of space, the download cache gives space back
    (`BlockCache.release`: the least recently used blocks of any location),
    and the operation is tried once more.
- **Timestamps.** `created` and `modified` are sent with each upload; a
  modification time set on an unchanged file is applied at its next upload.
- **Progress.** Upload progress is shown on the file's icon in Finder through
  `JottaFSProgressAgent` ([FSKit notes](fskit-internals.md#upload-progress-in-finder)).

## Finder's own files (`.DS_Store`, `._*`)

Finder writes a `.DS_Store` (view settings) into folders it shows, and macOS
stores a file's extended attributes (tags, comments, quarantine) in a
`._name` AppleDouble file next to it, because the volume supports extended
attributes only on its root. Uploading them cluttered Jottacloud, so since
1.1.2 they stay on this Mac (approved by the owner on 2026-11-25; per Mac only,
and existing copies on Jottacloud may stay there):

- **Where.** `LocalFinderFiles` keeps them in the extension's Application
  Support folder, in a tree that mirrors the location's folders:
  `LocalFiles/<location key>/<folder path>/<name>`. It lasts across unmounts
  and restarts. Items with these names get the role `.localFile(path:)`.
- **Operations.** They behave like any other file: create, write, read,
  truncate, rename, delete. Nothing is uploaded. Listings show the folder's
  local files and hide copies of these names that are on Jottacloud.
- **Pairing.** The kernel renames and deletes a file's `._` file with the file,
  through the volume. Renaming or deleting a folder through JottaFS moves or
  deletes its mirrored folder. A local file moved to the Trash joins the
  Trash's local files (`.trashLocal`), and Put Back brings it back.
- **Saved under another name.** A regular file renamed to one of these names
  (an app that writes a temporary file first) is moved into the local store
  and deleted on Jottacloud (not uploaded if it was not uploaded yet).
- **Clean-up.** When a folder is listed, a `._name` file whose item is gone
  is removed once it is older than an hour (a file still being created keeps
  its `._` file), and a mirrored folder whose folder is gone once it is
  older than 7 days (Put Back of a folder keeps its files' tags and view
  settings for a week).
- **Limits.** Tags, comments and view settings are per Mac: other devices do
  not see them. Changes made on jottacloud.com are only noticed by the
  clean-up.
- **Checked** 2026-11-25 on a mounted disk (new folders in `JottaFS-Test`):
  a `.DS_Store` written from Terminal and the `._file.txt` the kernel wrote
  for an extended attribute were stored locally and read back, and neither
  was uploaded. Finder writes a `.DS_Store` only for settings it keeps per
  folder (such as "Always open in list view"), not for every view change,
  on APFS as well.

## Why the local copy stays (measured 2026-11-25)

A 300 MB copy with `cp` onto a mounted disk took 20.9 s: about 1 s writing
into the local copy through FSKit (about 330 MB/s, MD5 computed on the way),
0.07 s to allocate and 19.8 s to upload (one stream, about 16 MB/s). A Finder
copy took 19.6 s with the same split. The upload is about 95 % of the time.

Alternatives that were checked and rejected:

- **Upload from the original file.** FSKit gives the extension only the bytes
  and the caller's uid/gid (`FSContext`): no source path, no process, no copy
  or clone operation. An unsandboxed process can find the source of a `ditto`
  (or `cp`) copy through libproc (the writer has the source open read-only),
  but Finder copies run in `DesktopServicesHelper` as root, whose files a user
  process cannot see. Even with the source, the upload can only start once
  the whole MD5 is known, so at most the 5 % of writing would be saved.
- **Send the MD5 or size after the body.** Jottacloud needs both before the
  body and checks the body against them
  ([API notes](jottacloud-api-internals.md#upload-no-streaming-variant-checked-2026-11-24)).
- **Upload one file in parallel parts.** The server only takes bytes in order
  from the resume position (same notes).
- **Upload several files at once.** It would need close(2) to return before
  the upload, so Finder's "done" would no longer mean the file is on
  Jottacloud. Discussed on 2026-11-25 and left as it is for now.

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
