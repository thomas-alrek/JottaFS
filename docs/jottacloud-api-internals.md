# Jottacloud API internals

This document preserves the protocol research and implementation decisions
from the initial Rust prototype. Jottacloud does not publish a complete API
reference; these details are observed behavior and can change.

## Authentication

The standard Jottacloud CLI flow begins with a single-use personal login token
created in the account's Security settings. The token is base64url-encoded JSON
with fields including:

- `username`
- `well_known_link`
- `auth_token`

The `well_known_link` points to OpenID Connect discovery. The discovery
response provides `token_endpoint`. Both URLs must be HTTPS on the official
`id.jottacloud.com` host; do not send credentials to a host taken from an
unvalidated token.

Exchange the decoded `auth_token` using OAuth's password grant with client ID
`jottacli`, the token's username, and scope `openid offline_access`. The
response provides an access token, refresh token, and expiry. The account
internal username used in JFS paths is returned by
`GET https://api.jottacloud.com/account/v1/customer`.

Refresh tokens rotate: each refresh returns a new refresh token and invalidates
the prior one. Serialize refresh operations. Concurrent requests that receive
401 for a now-stale access token should reuse the already-refreshed access
token instead of attempting a second refresh with the stale refresh token.
Never log tokens or place them in process arguments. The personal login token
is single-use; if a mount fails after successful authentication, generate a
new one for the next attempt.

## Browser login (not implemented; researched 2026-11-24)

The official macOS app (`jottad` 26.11.12 in `/Applications/Jottacloud.app`)
logs in through the browser with a standard OAuth authorization-code flow.
This was read from strings, symbols and disassembly of the shipped binary
(the decompilers could not load it); nothing was executed and no login was
attempted.

1. Discovery from
   `https://id.jottacloud.com/auth/realms/jottacloud/.well-known/openid-configuration`.
2. A callback server on `127.0.0.1:0` (system-chosen port) serving
   `/callback`. The `redirect_uri` sent is
   `http://localhost:<port>/callback` (`127.0.0.1` replaced by `localhost`).
3. The browser opens the discovered authorization endpoint with
   `response_type=code`, `client_id`, `redirect_uri`, `scope`, a random
   32-character `state`, and PKCE with `code_challenge_method=plain` (the
   challenge is the 64-character verifier itself). `kc_idp_hint=alternative`
   is added only for the app's "alternative login" button.
4. The callback's `code` is exchanged at the token endpoint with
   `grant_type=authorization_code`, `code`, `redirect_uri`, `client_id` and
   `code_verifier`. No client secret is sent (the secret-based
   `desktop-test` client exists only in test code paths, read from an
   environment variable).
5. Refresh and logout use `client_id` and the refresh token, as JottaFS's
   current refresh does. The binary contains "maximum allowed refresh token
   reuse exceeded", consistent with rotating refresh tokens.

The client ID is `desktop-mac` in the desktop build and `jottacli` in builds
without the desktop flag, so `jottacli` (the ID JottaFS already uses)
appears to be configured for this flow. JottaFS should not impersonate
`desktop-mac`. The app's separate `AuthService/RegisterSession` gRPC call
belongs to its transfer layer and is not needed for the OAuth flow.

Plan for JottaFS: run the flow from the host app (not the extension) with
`jottacli`, scope `openid offline_access`, PKCE `S256` (falling back to
`plain` only if refused), and verify `state` on the callback (the official
app does not appear to). Implemented 2026-11-24: Jottacloud accepts S256 for
`jottacli` and a `http://localhost:<port>/callback` redirect; JottaFS uses S256
only and checks `state` in the callback server and again in the client. A sandboxed listener needs
`com.apple.security.network.server`.

Unconfirmed: the exact `scope` the app requests (probably from discovery),
whether Keycloak accepts any loopback port for `jottacli`, and whether S256
is supported. One real login attempt settles all three.

## Devices and mountpoints (researched 2026-11-24, not used)

Static analysis only (rclone source, the web app's protobuf descriptors,
strings in `jottad`); nothing was sent to Jottacloud.

- The account root holds only devices, and a device holds only mountpoints;
  there are no plain folders at either level.
- JFS (rclone): create a device with `POST /jfs/<user>/<device>?type=WORKSTATION`
  and a mountpoint with `POST /jfs/<user>/<device>/<mountpoint>` (no body).
  rclone refuses to create mountpoints on the built-in `Jotta` device.
- gRPC `no.jotta.openapi.device.v2.DeviceService`: `Create{installation_id,
  display_name, type}`, `Delete{id, supports_background_jobs}`,
  `Modify{id, installation_id, display_name, type}`, `Get`, `List`, `Match`,
  `Claim`. `DeviceType` includes `WORKSTATION 1`, `MACBOOK 3`, `JOTTA 6`,
  `CLI 12`. The server has a `TOO_MANY_DEVICES` error.
- Service paths of backups are `/backup/<deviceId>/<mountpoint>/...`. The
  desktop app creates mountpoints implicitly through uploads, removes a
  backup with `FileService.Delete` on the mountpoint and renames it with
  `FileService.Move`.
- Risks: the desktop app reports "remote-only mountpoints" on its own
  device during server-requested device checks, so mountpoints added to the
  owner's existing backup devices could be seen as orphaned backups; a new
  device appears in the desktop app's setup list, where linking it would
  change its `installation_id`; `DeviceService.Delete` removes a whole
  device and must only ever use the exact `id` of a device JottaFS created.
- Unknown until a live test (which needs a scope decision): accepted device
  types, whether `FileService.CreateFolder` on `/backup/<id>/<name>` creates
  a mountpoint, and whether deleting a device trashes or removes it.

## JFS paths and directory listings

The observed JFS root is:

```text
https://jfs.jottacloud.com/jfs/{internal-username}/{device}/{mountpoint}/{path}
```

The default device and mountpoint are `Jotta` and `Archive`. Encode each path
component separately; preserve literal plus signs as `%2B`.

Directory requests return XML containing `folders/folder` and `files/file`
elements. Folder names and modification times are attributes/elements; files
contain a `currentRevision` with `state`, `size`, and `modified`. Ignore deleted
entries and files whose current revision is not `COMPLETED`. Jottacloud
timestamps may use a legacy dashed `-T` separator and should be normalized
before RFC 3339 parsing.

## Account storage

The JFS account document (`GET /jfs/<username>`) is assumed to carry
`<capacity>` (bytes, `-1` for unlimited) and `<usage>` (bytes) directly under
its root element, as in rclone's Jottacloud backend. This is unconfirmed
against current documentation; the client treats missing or non-numeric values
as unknown and still reports a non-zero volume size.

## Upload: no streaming variant (checked 2026-11-24)

Static analysis of the official desktop daemon (`jottad` 26.11.12, Go 1.22,
module `git.jotta.us/jotta/desktop/client`) found no upload path that avoids
the whole-file MD5 up front:

- It uses `/files/v2/allocate` (JSON) and the gRPC
  `no.jotta.openapi.file.v2.FileService/Allocate`. `AllocateRequest` fields:
  `path`, `md5`, `size`, `created_at_millis`, `modified_at_millis`,
  `conflict_handler`, optional `valid_for_millis`. `AllocateResponse`: `name`,
  `path`, `state`, `upload_id`, `upload_url`, `bytes`, `resume_position`,
  plus typed errors (file system, retry-after, invalid path).
- Its uploader is a pipeline `(*Uploader).checksum` → `allocate` → `upload`
  (`md5.ChecksumFile`, a configurable checksum rate, "Size changed before
  upload"), and the only ranged sending is resume (`bytes=%d-%d`).

The web app (`jotta-libs` bundle) does the same: it hashes the whole file
with a WebAssembly MD5 (showing hashing progress), then calls
`FileService.Allocate` with `md5` and `size`.

Live experiments (2026-11-24, inside `JottaFS-Test`, `files/v1/allocate`):

- Allocating with an empty MD5 fails with 400 "Upload without md5 no longer
  supported. Use header JMd5."
- Sending only part of the body as a complete request (with a `Range`
  header) fails with 421 `CorruptUploadOpenApiException`; nothing is kept.
- An interrupted upload (full `Content-Length` declared, connection
  cancelled) is kept in 32 MiB blocks: after 48 MiB of 64 MiB, re-allocating
  with the same MD5 returned HTTP 207 with `resume_pos` 33554432; after
  4 MiB of 8 MiB it returned 0.
- The kept blocks are tied to the MD5: the same interrupted upload under a
  placeholder MD5, re-allocated with the real MD5, returned `resume_pos` 0.

So the official client, like rclone and JottaFS, hashes the complete file
before allocating, and no upload can start before the complete MD5 is known, and identical content is deduplicated at allocation
(`state` `COMPLETED`). Upload progress can therefore only start after a file
is fully written; Finder's copy dialog (which counts bytes written) cannot
follow the upload. These are observations from strings and type metadata in
the shipped binary, not from decompiled control flow or network traffic.

## File reads

Download a file with `?mode=bin` and a `Range: bytes=start-end` header. The
expected response is HTTP 206. Request identity encoding so content coding
cannot change the byte offsets, and verify that `Content-Range` starts at the
requested offset and fits within the requested length. If the server answers
HTTP 200 despite the range request, JottaFS reads the start of the body only
for offset 0 and otherwise fails the read rather than downloading and
discarding everything before the offset. Observed 2026-11-24:
Jottacloud answers 416 (`text/xml`) when the range *end* extends past the end of
the file, even if the start is valid, instead of returning a truncated 206.
Clamp the range end to the listed file size and do not send a request at or
after EOF; then a 416 means there is no data at that offset. Cap one FUSE/FSKit read request (the prototype
used 1 MiB) and return short reads at end of file.

Each range request waits about 70–100 ms for its first byte, and one
download runs at only about 4–5 MB/s (measured 2026-11-24, independent of the
range size). JottaFS therefore reads ahead once 2 MiB of a file have been read
in order (`ReadAhead.swift`): 8 MiB blocks at fixed positions, with up to four
downloading at the same time ahead of the reader. Random reads, and readers
that only look at the start of a file (Finder thumbnails), still use one
request each. Responses are collected in chunks and cancelled at the
requested length.

### Download speed and `ContentLocatorService` (measured 2026-11-24)

The desktop daemon (`jottad`) does not download through `jfs`. Its embedded
descriptor `no/jotta/openapi/content/v2/content.v2.proto` defines
`no.jotta.openapi.content.v2.ContentLocatorService` (on `grpc.jotta.cloud`):

```proto
rpc DownloadLocation(DownloadLocationRequest) returns (DownloadLocationResponse);
rpc DownloadLocations(DownloadLocationsRequest) returns (DownloadLocationsResponse);
rpc PrepareDownload(PrepareDownloadRequest) returns (DownloadLocationResponse);
message DownloadLocationRequest { oneof ref { ContentRef plain = 1; string encoded_ref = 2; } }
message DownloadLocationResponse {
  oneof result { Located located = 1; NotFound not_found = 2; NotSupported not_supported = 3;
                 AccessDenied access_denied = 4; AccountLocked account_locked = 5; }
  message Located { string url = 1; optional int64 size = 2; optional string md5 = 3; optional string owner = 4; }
}
// no.jotta.openapi.ContentRef: file_or_folder = 1 (FileOrFolderRef { path = 1 }),
// file_revision = 12 (FileRevisionRef { username = 1; checksum = 2; optional path = 3 }), …
```

`DownloadLocation` with `file_or_folder.path` in service form
(`/archive/<path>`) returns `located` with a URL on a storage host
(`001-up-s.jotta.cloud`, HTTP/1.1), the size and the MD5. That URL needs the
normal `Authorization: Bearer` header (401 without) and supports ranges (206).
It is **not faster** than `jfs` (64 MiB random test file, one Mac, one
network):

| Path | Throughput |
|---|---|
| `jfs` ranged read, one 16 MiB request | 6.9 MB/s |
| storage URL, one 32 MiB range | 4.8 MB/s |
| storage URL, 4 / 8 parallel 8 MiB ranges | 5.6 / 4.7 MB/s total |
| storage URL, whole file without range | 4.3 MB/s |
| upload, one 64 MiB file | 11.9 MB/s |
| upload, three 32 MiB files at once | 14.3 MB/s total |

Downloads are limited to about 5–7 MB/s in total per account (or client),
whatever the host, range size or number of connections; uploads on the same
connection are twice as fast. Parallel requests do not raise the download
limit, so JottaFS's read-ahead helps only by hiding request latency. Faster
reads have to come from not downloading: JottaFS keeps downloaded 8 MiB blocks
in a disk cache keyed by the listing's MD5 and the block index
(`BlockCache.swift`, in the app group's `Library/Caches/BlockCache`; 1024 MB
by default, set and cleared in the app's Settings, emptied after a restart), and downloads files of at most 4 MiB whole on the first
read.

### Public share links (checked 2026-11-24)

`GET` on a file's or folder's JFS path with `?mode=enableShare` (bearer
token) returns HTTP 200 and the item's XML (`<file …>` or `<folder …>`) with
two extra elements:

```xml
<publicURI>13f86255648645d197b10a8fddcd9d13</publicURI>
<publicSharePath>/s/32013f86255648645d197b10a8fddcd9d13</publicSharePath>
```

A plain `GET` of the item (no `mode`) also contains `publicSharePath` when
the item is shared, including items shared on jottacloud.com (confirmed with
the Finder extension, 2026-11-24). The link is
`https://www.jottacloud.com` + `publicSharePath`. Enabling an
item that is already shared returns the same link. `?mode=disableShare`
returns the XML without these elements and removes the link. Checked on a
test file and a test folder in `JottaFS-Test`; both links were removed
afterwards. The web app answers every `/s/…` address with the same HTTP 200
page, so the HTTP status of a share link does not show whether it works.

## Existing implementation decisions

- One reusable HTTP client; bounded request timeouts.
- OAuth discovery and token requests do not follow redirects.
- Directory metadata is cached briefly and with entry/count bounds. FSKit and
  the kernel also cache metadata; keep the driver's own cache conservative.
- Remote mutations are confined to `Jotta/Archive/JottaFS-Test` (see
  [the write-support design](write-support-design.md)). The write endpoints
  used are rclone's: `files/v1/allocate` + `upload_url` for uploads,
  `?mkDir=true`, `?dl=true`/`?dlDir=true` (trash), and `?mv=`/`?mvDir=` with
  a full `/<user>/<device>/<mountpoint>/...` destination. They are
  unverified against an account until the live write tests have run.
- Unit tests should use synthetic tokens and XML fixtures. A live account and
  actual mount are required to validate undocumented server behavior.

## References and limits

- [rclone Jottacloud documentation](https://rclone.org/jottacloud/)
- [rclone Jottacloud source](https://github.com/rclone/rclone/tree/master/backend/jottacloud)

The rclone documentation explicitly notes that Jottacloud's API behavior is
not backed by a complete public API specification. Treat URL shapes,
authentication behavior, XML fields, and range handling as compatibility
assumptions until verified against an account.
