# Trash integration design (draft for review)

Status: reviewed 2026-11-24; implementation in progress. It builds on
[the write-support design](write-support-design.md) and must be reviewed
before implementation (AGENTS.md).

## Goal

Make Finder's Trash behave as expected on the JottaCloud volume:

| Finder action | Jottacloud effect |
|---|---|
| Move to Trash | soft delete (the item goes to the Jottacloud trash) |
| Put Back | restore to the original path |
| Empty Trash / Delete Immediately (inside the Trash) | permanent delete of those items only |

The design covers the whole account. While testing, operations on live
files are still confined to `JottaFSWriteScope` (`Jotta/Archive/JottaFS-Test`);
the Trash itself shows and acts on the whole Jottacloud trash (see Decisions).
Lifting the scope for live files is a separate decision.

## Confirmed API behavior (live probes, 2026-11-24, test items only)

All calls are gRPC-Web on
`https://grpc.jotta.cloud/no.jotta.openapi.file.v2.FileService/<Method>`
with the OAuth access token. Request paths are lower-case
(`/archive/JottaFS-Test/...`); responses use `/Archive/...`.

- **Listing the trash:** `GetPath { path: "/trash", limit, include_children:
  true, include_deleted: true, sort, cursor }`, as the web app does. Children
  are the trashed top-level items with their **original path** (for example
  `/Archive/JottaFS-Test/Developer`), `type` (1 file, 2 folder), size and
  `deleted_at_millis`. It pages with a cursor (100 per page tested; the
  account's trash has more than 2,000 entries). Sort values: `NAME_ASC 1`,
  `NAME_DESC 2`, `DATE_ASC 3`, `DATE_DESC 4`, `SIZE_ASC 5`, `SIZE_DESC 6`.
  `ListFolder("/trash")` is rejected with `INVALID_ARGUMENT`.
- **Trashed items also stay in place:** `GetPath` and the JFS XML listing of
  the parent folder show them with `deleted_at_millis` / `deleted="…"`; the
  normal listing already hides them.
- **Restore:** `Restore { path, supports_background_jobs: false }` on a
  trashed folder brought it back at its original path, not deleted.
- **Permanent delete:** `DeletePermanently { path, supports_background_jobs:
  false }` on one trashed item removed it completely, including from the
  JFS listing. Never use `files/v1/purge_trash` (whole account).
- **Soft delete:** the existing JFS `?dl=true` / `?dlDir=true` (a gRPC
  `Delete` method also exists; not needed).

## Design

### Virtual `.Trashes`

The volume root (the device list) gets a hidden virtual folder
`/.Trashes`, mode `d-wx-wx-wt` like a real volume, containing
`/.Trashes/<uid>` (mode 0700, owned by the mounting user) for the user who
mounted the volume. Neither is stored on Jottacloud. Finder uses
`.Trashes/<uid>` for Move to Trash on local, writable volumes; whether it
accepts our virtual folder is experiment E1.

`.Trashes/<uid>` lists the Jottacloud trash entries (filtered by the scope
while testing). Trashed folders can be opened and are read-only; their
contents come from `GetPath(original path, include_deleted)`.

### Names in the Trash

Finder renames an item into the Trash, picking a free name ("Report 2") when
needed, and records Put Back information in `.Trashes/<uid>/.DS_Store`.
Names in the Trash must therefore be stable:

- A small persistent map in the extension's container stores
  `trash name → (original path, deleted_at_millis, type)`.
- Items trashed through JottaFS keep the name Finder gave them.
- Items trashed elsewhere (web, other devices) get their own name, or
  `name 2`, `name 3`… ordered by deletion time, and keep it once assigned.
- Entries whose remote item has disappeared (emptied elsewhere, restored
  elsewhere) are dropped at the next listing.
- `.DS_Store` (and `._*`) inside `.Trashes/<uid>` are kept locally in the
  container, never uploaded.

### Operations

| FSKit callback | Action |
|---|---|
| rename item → `.Trashes/<uid>/<name>` | wait for pending upload, soft delete (`dl`/`dlDir`), read back `deleted_at_millis`, record the name |
| rename `.Trashes/<uid>/<name>` → original path | `Restore` |
| rename from Trash to a different location | `Restore`, then the existing move |
| remove a top-level Trash entry | `DeletePermanently(original path)` |
| remove inside a trashed folder | `DeletePermanently(child path)` (E4) |
| remove (`rm`, `unlink`, `rmdir`) outside the Trash | soft delete, then `DeletePermanently` of that trashed item |
| create / write / rename inside the Trash (other than `.DS_Store`) | `EPERM` |

Permanent deletion only ever names one trashed item at a time, and only
after confirming it is trashed.

### Caching

The trash listing is paged with `DATE_DESC` and cached like directories
(fresh 15 s, stale up to 300 s while revalidating, at most 20,000 entries).
Our own trash, restore and delete operations update the cache immediately.

## Open experiments (before or during implementation)

- **E1** Finder Move to Trash on the volume uses `.Trashes/<uid>` (rename),
  rather than offering "Delete Immediately".
- **E2** Restore when a live item with the same name now exists at the
  original path (error, rename, or overwrite?).
- **E3** Restore when the original parent folder is itself trashed or gone.
- **E4** `DeletePermanently` on a child path inside a trashed folder.
- **E5** Large trashed folders: when `supports_background_jobs` is needed
  and how a job is reported.
- **E6** Whether the trash children of a trashed folder are listed in
  `/trash` (only top-level items observed so far).

## Decisions (owner, 2026-11-24)

1. **The Mac Trash shows the whole Jottacloud trash**, including items
   trashed on the web or other devices. Items in the trash are disposable:
   Put Back and Empty Trash act on any trash entry, also outside
   `JottaFSWriteScope`. The scope still limits everything that touches live
   files (create, write, rename, move to the Trash, `rm`).
2. **`rm` outside the Trash deletes permanently**, as on a local disk: a soft
   delete followed by `DeletePermanently` of that same trashed item.

Before any `DeletePermanently`, the extension confirms with
`GetPath(path, include_deleted)` that the item at that path is trashed
(`deleted_at_millis` non-zero) and, for Trash entries, that it is the same
deletion that was listed. A live item at the same path is never deleted.
