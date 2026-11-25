# Jottacloud API internals

The Jottacloud API research behind JottaFS, and the decisions that follow
from it. Jottacloud does not publish a complete API reference; these details
are observed behaviour (live probes on test items, rclone's backend, and
static reading of the official apps) and can change.

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

## Browser login (researched and implemented 2026-11-24)

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

JottaFS runs the flow from the host app (not the extension) with `jottacli`,
scope `openid offline_access` and PKCE `S256`; Jottacloud accepts S256 for
`jottacli` and a `http://localhost:<port>/callback` redirect on any loopback
port (confirmed by real sign-ins). JottaFS checks `state` in the callback
server and again in the client (the official app does not appear to). The
sign-in page opens in an `ASWebAuthenticationSession`; the loopback server
answers the callback with a redirect to `jottafs://signed-in`, which ends the
session and closes the browser tab (a page cannot close its own tab, and
Safari keeps it open when the app cancels the session). A sandboxed listener
needs `com.apple.security.network.server`.

## Devices and mountpoints (researched 2026-11-24)

JottaFS reads the account's devices and mountpoints (the location list) and
`DeviceService.List` (the service path of each backup device, checked live).
It never creates, changes or deletes devices or mountpoints. The rest of this
section is static analysis only (rclone source, the web app's protobuf
descriptors, strings in `jottad`).

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
- Not tested (JottaFS does not create devices or mountpoints): accepted
  device types, whether `FileService.CreateFolder` on `/backup/<id>/<name>`
  creates a mountpoint, and whether deleting a device trashes or removes it.

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
after EOF; then a 416 means there is no data at that offset. One read request
is at most 1 MiB, except read-ahead blocks (8 MiB), and reads are short at
end of file.

Each range request waits about 70–100 ms for its first byte, and one
download stream is limited in speed (see the measurements below). JottaFS
therefore reads ahead once 2 MiB of a file have been read in order
(`ReadAhead.swift`): 8 MiB blocks at fixed positions, downloading in
parallel ahead of the reader, 2 at first and one more for each further 8 MiB
read, up to 8 (the data session allows 16 connections per host). Random reads, and readers
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

On 2026-11-24 downloads stayed at about 5–7 MB/s in total whatever the
host, range size or number of connections (that test was limited to 6
connections per host, `URLSession`'s default). A new test on 2026-11-25
(same Mac and network, the same 64 MiB file, two rounds, up to 32
connections) gave a different picture:

| Path | 1 stream | 2 | 4 | 8 | 16 parallel |
|---|---|---|---|---|---|
| `jfs` ranges (whole file split) | 13.6–15.0 MB/s | 18.2–19.8 | 23.2–24.5 | 27.6 | 29.8–30.7 MB/s |
| storage URL | 12.4–13.3 MB/s | | 24.6–24.7 | | 27.1–28.8 MB/s |

So the speed of one stream varies with the time and the network (an rclone
forum thread from 2022 reports the same, including a provider's network as
the cause), and parallel streams do help, with less gain above 8. The size
of each range hardly matters. The storage URL is not faster than `jfs`.
Not downloading at all is still the fastest: JottaFS keeps downloaded 8 MiB blocks
in a disk cache keyed by the listing's MD5 and the block index
(`BlockCache.swift`, in the app group's `Library/Caches/BlockCache`, one
folder per mounted location; 1024 MB in total by default, set and cleared in
the app's Settings; a location's folder is deleted when it is unmounted, and
the whole cache after a restart), and downloads files of at most 4 MiB whole on the first
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

## Implementation decisions

- One reusable HTTP client; bounded request timeouts.
- OAuth discovery and token requests do not follow redirects. Only the
  official `id.jottacloud.com` identity host is accepted.
- Refresh tokens rotate: the app, the file system extension and the Finder
  extension serialize credential writes with an `flock` and read the newest
  saved tokens before refreshing.
- Directory listings are cached briefly with entry and folder bounds (see
  [the FSKit notes](fskit-internals.md#volume)); FSKit and the kernel cache
  metadata too.
- The write endpoints are rclone's: `files/v1/allocate` + `upload_url`,
  `?mkDir=true`, `?dl=true`/`?dlDir=true`, and `?mv=`/`?mvDir=` with a full
  `/<user>/<device>/<mountpoint>/...` destination; the Trash uses the gRPC
  `FileService` ([write design](write-support-design.md),
  [Trash design](trash-design.md)). All were verified live on test items.
- Checks use synthetic tokens and XML fixtures. Undocumented server behaviour
  needs a live account and a mount; live tests only touch new, uniquely named
  items under `Jotta/Archive/JottaFS-Test` (AGENTS.md).

## References and limits

- [rclone Jottacloud documentation](https://rclone.org/jottacloud/)
- [rclone Jottacloud source](https://github.com/rclone/rclone/tree/master/backend/jottacloud)

The rclone documentation explicitly notes that Jottacloud's API behavior is
not backed by a complete public API specification. Treat URL shapes,
authentication behavior, XML fields, and range handling as compatibility
assumptions until verified against an account.
