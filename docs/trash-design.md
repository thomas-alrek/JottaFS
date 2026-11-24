# Trash design

How Finder's Trash works on a JottaFS volume. Reviewed and decided by the
project owner on 2026-11-24 and tested live with test items. Builds on
[the write design](write-support-design.md). Code: `Trash.swift` (names,
local metadata, the trash store) and `JottaFSVolume+Trash.swift`
(operations) in the extension; the gRPC calls in `RemoteAPI.swift`.

## Behaviour

| Finder action | Jottacloud effect |
|---|---|
| Move to Trash | soft delete: the item goes to the Jottacloud trash |
| Put Back | restore to the original path |
| Empty Trash / Delete Immediately (inside the Trash) | permanent delete of those items only |
| `rm`, `unlink`, `rmdir` outside the Trash | permanent delete, as on a local disk |
| A rename over an existing file | permanent delete of the replaced file |

Decisions (owner, 2026-11-24):

1. **The Mac Trash shows the Jottacloud trash of the mounted location**,
   including items trashed on the web or other devices. Items in the trash
   are disposable: Put Back and Empty Trash act on any of them.
2. **`rm` deletes permanently**, like on a local disk: a soft delete followed
   by a permanent delete of that same trashed item. A rename over an existing
   file does the same (apps that save by renaming a new file over the old one
   would otherwise fill the Trash).

In development and testing, never trigger Empty Trash and never use
whole-account operations such as `files/v1/purge_trash` (AGENTS.md).

## Jottacloud API (live probes, 2026-11-24, test items only)

All calls are gRPC-Web on
`https://grpc.jotta.cloud/no.jotta.openapi.file.v2.FileService/<Method>`
with the OAuth access token. Request paths are service paths with a
lower-case first component (`/archive/JottaFS-Test/...`); responses use
`/Archive/...`. Backed-up folders use the device's service path from
`DeviceService.List` (`/backup/<device id>/<folder>/...`).

- **Listing the trash:** `GetPath { path: "/trash", limit, include_children:
  true, include_deleted: true, sort, cursor }`, as the web app does. Children
  are the trashed top-level items with their original path, `type` (1 file,
  2 folder), size and `deleted_at_millis`, paged with a cursor. Sort values:
  `NAME_ASC 1`, `NAME_DESC 2`, `DATE_ASC 3`, `DATE_DESC 4`, `SIZE_ASC 5`,
  `SIZE_DESC 6`. `ListFolder("/trash")` is rejected with `INVALID_ARGUMENT`.
- **Trashed items also stay in place:** `GetPath` and the JFS XML listing of
  the parent folder show them with `deleted_at_millis` / `deleted="…"`; the
  normal listing hides them.
- **Restore:** `Restore { path, supports_background_jobs: false }` brings an
  item back at its original path.
- **Permanent delete:** `DeletePermanently { path, supports_background_jobs:
  false }` removes one trashed item completely.
- **Soft delete:** JFS `?dl=true` / `?dlDir=true`.

## Virtual `.Trashes`

The volume root has a hidden virtual folder `/.Trashes` (mode `d-wx-wx-wt`,
like a real volume) with `/.Trashes/<uid>` (mode 0700, owned by the user who
mounted the volume). Neither is stored on Jottacloud. Finder uses
`.Trashes/<uid>` for Move to Trash on local, writable volumes. It lists the
Jottacloud trash entries whose original path is in the mounted location
(service path prefix such as `/archive/`).

## Names in the Trash

Finder renames an item into the Trash, picking a free name ("Report 2") when
needed, and keeps Put Back information in `.Trashes/<uid>/.DS_Store`. Names
in the Trash are therefore stable:

- A persistent map per location (`Names.plist` in the extension's container)
  stores `trash name → (original path, deleted_at_millis, type)`.
- Items trashed through JottaFS keep the name Finder gave them; items trashed
  elsewhere get their own name, or `name 2`, `name 3`… by deletion time, and
  keep it.
- Entries whose item disappeared (emptied or restored elsewhere) are dropped.
- `.DS_Store` and `._*` files inside `.Trashes/<uid>` are kept locally, never
  uploaded.

## Operations

| FSKit callback | Action |
|---|---|
| rename item → `.Trashes/<uid>/<name>` | wait for a pending upload, soft delete, read back `deleted_at_millis`, record the name |
| rename `.Trashes/<uid>/<name>` → original path | `Restore` |
| rename from the Trash to a different place | `Restore`, then the normal move |
| remove a top-level Trash entry | `DeletePermanently(original path)` |
| remove outside the Trash | soft delete, then `DeletePermanently` of that trashed item |
| create / write / rename inside the Trash (other than `.DS_Store`) | `EPERM` |

**Safety.** A permanent delete only ever names one trashed item, and only
after `GetPath(path, include_deleted)` confirms that the item at that path is
trashed (`deleted_at_millis` non-zero) and, for Trash entries, that it is the
same deletion that was listed. A permanent delete right after a trash
operation only accepts an entry deleted within 5 seconds of it; Empty Trash
refuses an entry whose deletion time is not known yet. A live item is never
deleted permanently.

## Loading and caching

- The trash loads in the background from mount time (500 entries per request,
  about 3 s each); every file system call is answered from memory. Listing
  the trash inside a lookup (the first version) made Finder hang during Move
  to Trash.
- A full reload runs at most every 30 minutes; while the Trash is in use the
  newest page is checked every 30 seconds. That check also notices entries
  emptied or restored elsewhere: if the whole trash fits on the page the rest
  is dropped at once, otherwise a missing entry in the page's time range
  starts a full reload.
- Own trash, restore and delete operations update the store at once.

## Limits

- Trashed folders are shown empty (listing each would cost a request while
  Finder waits). Deleting one from the Trash deletes all of its contents.
- Files in the Trash cannot be opened (no Quick Look).
- Folders under `.Trashes` are protected by macOS privacy controls: only
  Finder and apps with Full Disk Access can list them.
- For a backed-up folder whose device service path is unknown, the Trash
  stays empty and `rm` leaves items in the Jottacloud trash. That trashed
  backup items have paths `/backup/<id>/<folder>/…` is assumed, not yet seen
  in a listing.
- Whole backup devices are not mounted: a device's root only holds backup
  sets, and Finder could not offer New Folder there.
