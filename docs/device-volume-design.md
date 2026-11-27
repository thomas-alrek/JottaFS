# A whole device as one volume

The user can mount a whole device as one disk: its locations are the
folders in the disk's root, and everything inside a location works as on a
location's own disk. The API behaviour this relies on was verified live on
2026-11-27 (see [the API notes](jottacloud-api-internals.md#devices-and-mountpoints-researched-2026-11-24)).

## Mount anchors and settings

A whole device is a location with an empty mountpoint:
`JottacloudRemoteVolume.wholeDevice(name)`, id `<device>/`. Jottacloud has
no mountpoint with an empty name, so the existing mount anchors
(`Location.plist` with `Mountpoint` = `""`), custom names, mount at login and
serving-extension records work unchanged. The default disk name is the
device's name ("Jottacloud" for Jottacloud's own device).

A whole-device volume has no file URL or service path of its own:
`makeJFSURL` and `MountTarget.servicePath` refuse an empty mountpoint, so a
path can never be read as a location's name. Every item names its own
location (`.mountpoint(volume)` for a location folder, `.remote(volume,
path)` inside one).

## The root

| In Finder (root of the disk) | In Jottacloud |
|---|---|
| New Folder | Creates a location (`POST /jfs/<user>/<device>/<name>`) |
| Rename a folder | Renames the location (`FileService.Move`) |
| Move to Trash | Moves the location with its files to the trash (`FileService.Delete`) |
| Put Back | Restores the location (`FileService.Restore`) |
| `rmdir` of an empty folder | Moves the location to the trash, then deletes it there |
| A new file | Refused (`EPERM`): a file needs a location |
| A folder moved into another location, or a location into a folder | Refused (`EPERM`) |

Finder's own files (`.DS_Store`, `._*`) can be created in the root; like
everywhere else they stay on this Mac.

Jottacloud's own device (`Jotta`) has fixed locations (Archive, Sync,
Shared, Photos…): nothing in its root can be created, renamed or moved to
the trash; everything inside the locations can. Its folders have the names
the app saved in the user's language ("Arkiv" for "Archive", like their
disk names); a translated name that another location already has is not
used.

A backup device needs its service path (`DeviceService.List`) for the root
operations; without it the root is fixed too.

## Inside the locations

Everything works as on a location's own disk. Moving an item between two
locations of the device is a move on the server (JFS `mv`/`mvDir` with the
other location in the destination path); before, between two disks, it was
a copy and a delete. Put Back into another location restores the item, then
moves it.

## Local state

- Finder's own files are stored by their path in the volume
  (`<location>/<folder>/<name>`), not their path in a location. For a
  location's own disk the two are the same, so existing data is unchanged.
- Staging, the download cache and the Trash's names are per volume
  (`MountTarget.storageKey`), as before.
- The Trash shows the entries trashed from any location of the device: for
  a backup device everything under `/backup/<id>/` (also its trashed
  locations themselves), for Jottacloud's own device everything under the
  service paths of its locations (`/archive/`, `/photos/`…).

## The app

- The device's "…" menu has **Mount as One Disk**; while it is mounted,
  **Show in Finder** and **Unmount…**. The mounted device gets a row at the
  top of its section, so it can be selected, unmounted, renamed and mounted
  at login like a location.
- A device and one of its locations are never both mounted: mounting the
  device unmounts its mounted locations first, and while it is mounted its
  locations cannot be mounted on their own (their Mount button opens the
  location's folder on the device's disk instead).
- At login, devices are mounted first; a location whose device is mounted
  is skipped.
- Deleting a backup device unmounts its disk too.

## Known limits

- jottacloud.com cannot restore a trashed location ("Gjenoppretting
  utilgjengelig"); Put Back in Finder can.
- Locations created or removed elsewhere appear when Finder reads the
  root again, like other changes.
